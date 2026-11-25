// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISenzuAdapter} from "../interfaces/ISenzuAdapter.sol";
import {ISenzuCore} from "../interfaces/ISenzuCore.sol";
import {ISenzuERC6909} from "../interfaces/ISenzuERC6909.sol";
import {ISenzuRiskConfig} from "../interfaces/ISenzuRiskConfig.sol";
import {FeeLogic} from "../libraries/FeeLogic.sol";
import {FeeCheckpoint} from "../libraries/Types.sol";
import {BaseAdapter} from "./BaseAdapter.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

/**
 *  @title  FeeLedger
 *  @author Senzu
 *  @notice Each holder's share of a position's fees: a checkpoint per (account, position), booked at the position's
 *          fee growth per unit before every change of the account's units but a seize. A seize books nothing: the
 *          seized units take their bookmark and their pro-rata share of the source's credited `owed` to the receiver,
 *          so what they earned and wasn't collected goes with them. The adapter supplies the growth and pays. Every
 *          payout sends the protocol its cut (`ISenzuRiskConfig.feeCut`) and the holder the rest.
 */
abstract contract FeeLedger is BaseAdapter {
    using FeeLogic for FeeCheckpoint;
    using SafeCastLib for uint256;

    uint256 internal constant Q128 = 1 << 128;

    /// @notice Fee checkpoint per holder and position
    mapping(address account => mapping(uint256 lpId => FeeCheckpoint)) public checkpoints;

    constructor(address collateral_) BaseAdapter(collateral_) {}

    modifier onlyAuthorized(address account) {
        _requireAuthorized(account);
        _;
    }

    function _requireAuthorized(address account) private view {
        if (msg.sender != account && !ISenzuERC6909(collateral).isOperator(account, msg.sender)) {
            revert SenzuAdapter__Unauthorized();
        }
    }

    /// @notice A position's fee growth per unit as of now
    function feeGrowth(uint256 lpId) external view returns (uint256 growth0X128, uint256 growth1X128) {
        return _previewGrowth(lpId);
    }

    /// @inheritdoc ISenzuAdapter
    function feesOwed(address account, uint256 lpId) external view override returns (uint256 fee0, uint256 fee1) {
        (fee0, fee1) = _feesOwedBeforeCut(account, lpId);
        (uint256 cutWad,) = _feeCut();
        return (fee0 - FeeLogic.cut(fee0, cutWad), fee1 - FeeLogic.cut(fee1, cutWad));
    }

    /// @inheritdoc ISenzuAdapter
    function seize(uint256 lpId, address from, address to, uint256 toBalance, uint256 units)
        external
        override
        onlyCollateral
    {
        if (from != to && units > 0) _moveMarks(lpId, from, to, _balanceOf(from, lpId), toBalance, units);
    }

    /// @inheritdoc ISenzuAdapter
    function collectFees(address account, uint256 lpId, address to)
        external
        override
        onlyAuthorized(account)
        returns (uint256 fee0, uint256 fee1)
    {
        uint256 balance = _balanceOf(account, lpId);
        if (balance > 0) {
            (uint256 growth0, uint256 growth1) = _pokeGrowth(lpId);
            _checkpoint(account, lpId, balance, growth0, growth1);
        } else {
            _pokeEmpty(lpId);
        }
        return _payFeesOwed(account, lpId, to);
    }

    /// @dev Pays what `account`'s checkpoint holds, the protocol's cut taken: a redeem of all its units ends with
    ///      it, paid to the account
    function _payFeesOwed(address account, uint256 lpId, address to) internal returns (uint256 fee0, uint256 fee1) {
        FeeCheckpoint storage cp = checkpoints[account][lpId];
        (uint128 owed0, uint128 owed1) = (cp.owed0, cp.owed1);
        if (owed0 == 0 && owed1 == 0) return (0, 0);
        (cp.owed0, cp.owed1) = (0, 0);
        (uint256 cutWad, address feeTo) = _feeCut();
        uint128 cut0 = FeeLogic.cut(owed0, cutWad).toUint128();
        uint128 cut1 = FeeLogic.cut(owed1, cutWad).toUint128();
        uint256 paidCut0;
        uint256 paidCut1;
        (fee0, fee1, paidCut0, paidCut1) = _sendFeesAndCut(lpId, to, owed0 - cut0, owed1 - cut1, feeTo, cut0, cut1);

        emit CollectFees(account, lpId, to, fee0, fee1, paidCut0, paidCut1);
    }

    function _feesOwedBeforeCut(address account, uint256 lpId) internal view virtual returns (uint256, uint256) {
        FeeCheckpoint memory cp = checkpoints[account][lpId];
        uint256 balance = _balanceOf(account, lpId);
        if (balance == 0) return (cp.owed0, cp.owed1);
        (uint256 growth0, uint256 growth1) = _previewGrowth(lpId);
        return cp.pending(balance, growth0, growth1);
    }

    /// @dev The protocol's share of fees and rewards, and where it goes
    function _feeCut() internal view virtual returns (uint256 cutWad, address to) {
        return ISenzuRiskConfig(ISenzuCore(collateral).riskConfig()).feeCut(address(this));
    }

    /// @dev Pays a holder and the protocol's cut. An adapter that can pay both in one step (v3) overrides it
    function _sendFeesAndCut(
        uint256 lpId,
        address to,
        uint128 amount0,
        uint128 amount1,
        address feeTo,
        uint128 cut0,
        uint128 cut1
    ) internal virtual returns (uint256 paid0, uint256 paid1, uint256 paidCut0, uint256 paidCut1) {
        (paid0, paid1) = _sendFees(lpId, to, amount0, amount1);
        if (cut0 > 0 || cut1 > 0) (paidCut0, paidCut1) = _sendFees(lpId, feeTo, cut0, cut1);
    }

    /// @dev `to` holds `toBalance` units and takes `units` of `from`'s `fromBalance` units with `from`'s bookmark and
    ///      their share of `from`'s credited `owed`, rounded down so `to` is never credited more. The preview is at
    ///      or above every bookmark and at or below every later checkpoint's growth
    function _moveMarks(uint256 lpId, address from, address to, uint256 fromBalance, uint256 toBalance, uint256 units)
        internal
        virtual
    {
        (uint256 growth0, uint256 growth1) = _previewGrowth(lpId);
        FeeCheckpoint storage moved = checkpoints[from][lpId];
        FeeCheckpoint storage cp = checkpoints[to][lpId];
        cp.feeGrowthInside0X128 =
            FeeLogic.mergeMark(cp.feeGrowthInside0X128, moved.feeGrowthInside0X128, toBalance, units, growth0);
        cp.feeGrowthInside1X128 =
            FeeLogic.mergeMark(cp.feeGrowthInside1X128, moved.feeGrowthInside1X128, toBalance, units, growth1);
        if (fromBalance > 0) {
            uint256 share = units < fromBalance ? units : fromBalance;
            uint128 owed0 = moved.owed0;
            if (owed0 > 0) {
                uint128 moved0 = (share == fromBalance ? owed0 : FullMath.mulDiv(owed0, share, fromBalance)).toUint128();
                moved.owed0 = owed0 - moved0;
                cp.owed0 += moved0;
            }
            uint128 owed1 = moved.owed1;
            if (owed1 > 0) {
                uint128 moved1 = (share == fromBalance ? owed1 : FullMath.mulDiv(owed1, share, fromBalance)).toUint128();
                moved.owed1 = owed1 - moved1;
                cp.owed1 += moved1;
            }
        }
    }

    /// @dev A position's fee growth per unit as of now, reading only. Never above what a later `_pokeGrowth` returns
    function _previewGrowth(uint256 lpId) internal view virtual returns (uint256 growth0X128, uint256 growth1X128);

    /// @dev Collects what the DEX owes the position and returns its fee growth per unit
    function _pokeGrowth(uint256 lpId) internal virtual returns (uint256 growth0X128, uint256 growth1X128);

    /// @dev Optional hook when a zero-balance account collects (e.g. fees arriving after a position closed)
    function _pokeEmpty(uint256) internal virtual {}

    function _sendFees(uint256 lpId, address to, uint128 amount0, uint128 amount1)
        internal
        virtual
        returns (uint256 paid0, uint256 paid1);

    /// @dev Books what `account` earned on `balance` units since its last checkpoint. Call before the balance changes,
    ///      except at a seize (`_moveMarks`)
    function _checkpoint(address account, uint256 lpId, uint256 balance, uint256 growth0X128, uint256 growth1X128)
        internal
        virtual
    {
        checkpoints[account][lpId].checkpoint(balance, growth0X128, growth1X128);
    }

    function _balanceOf(address account, uint256 lpId) internal view virtual returns (uint256) {
        return ISenzuERC6909(collateral).balanceOf(account, lpId);
    }
}
