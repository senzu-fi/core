// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FeeLedger} from "./FeeLedger.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/**
 *  @title  HeldFeesAdapter
 *  @author Senzu
 *  @notice A FeeLedger for exchanges that pay a position's fees to the adapter: it holds them per position, counted
 *          apart from the tokens sent in for a deposit.
 */
abstract contract HeldFeesAdapter is FeeLedger {
    using SafeTransferLib for address;
    using SafeCastLib for uint256;

    struct Fees {
        uint256 growth0X128;
        uint256 growth1X128;
        uint128 held0;
        uint128 held1;
    }

    /// @notice Fee growth per unit of liquidity and fees still held, per position
    // slither-disable-next-line uninitialized-state
    mapping(uint256 lpId => Fees) public fees;

    /// @notice Fee tokens held for all positions, per token
    mapping(address token => uint256) public held;

    constructor(address collateral_) FeeLedger(collateral_) {}

    function _tokens(uint256 lpId) internal view virtual returns (address token0, address token1);

    /// @dev Fees the DEX owes the position and the adapter hasn't collected, and the liquidity they are split over
    ///      (0: nothing pending)
    function _pendingFees(uint256 lpId) internal view virtual returns (uint256 fee0, uint256 fee1, uint256 liquidity);

    /// @dev Collects the pending fees and books them (`_bookFees`)
    function _collectPending(uint256 lpId) internal virtual;

    /// @dev Booked growth plus the pending fees, as a collect would book them
    function _previewGrowth(uint256 lpId) internal view override returns (uint256 growth0, uint256 growth1) {
        (growth0, growth1) = (fees[lpId].growth0X128, fees[lpId].growth1X128);
        (uint256 fee0, uint256 fee1, uint256 liquidity) = _pendingFees(lpId);
        if (liquidity == 0) return (growth0, growth1);
        growth0 += FullMath.mulDiv(fee0, Q128, liquidity);
        growth1 += FullMath.mulDiv(fee1, Q128, liquidity);
    }

    function _pokeGrowth(uint256 lpId) internal override returns (uint256, uint256) {
        _collectPending(lpId);
        return (fees[lpId].growth0X128, fees[lpId].growth1X128);
    }

    /// @dev `_checkpoint` at the growth booked so far: call right after the position's fees were collected
    function _checkpointHeld(address account, uint256 lpId, uint256 balance) internal {
        _checkpoint(account, lpId, balance, fees[lpId].growth0X128, fees[lpId].growth1X128);
    }

    function _sendFees(uint256 lpId, address to, uint128 amount0, uint128 amount1)
        internal
        virtual
        override
        returns (uint256, uint256)
    {
        (address token0, address token1) = _tokens(lpId);
        Fees storage f = fees[lpId];
        f.held0 -= amount0;
        f.held1 -= amount1;
        _sendHeld(token0, to, amount0);
        _sendHeld(token1, to, amount1);
        return (amount0, amount1);
    }

    function _bookFees(uint256 lpId, address token0, address token1, uint256 fee0, uint256 fee1, uint128 liquidity)
        internal
    {
        Fees storage f = fees[lpId];
        f.held0 += fee0.toUint128();
        f.held1 += fee1.toUint128();
        held[token0] += fee0;
        held[token1] += fee1;
        f.growth0X128 += FullMath.mulDiv(fee0, Q128, liquidity);
        f.growth1X128 += FullMath.mulDiv(fee1, Q128, liquidity);
    }

    function _sentIn(address token) internal view returns (uint256) {
        return token.balanceOf(address(this)) - held[token];
    }

    function _sendHeld(address token, address to, uint256 amount) private {
        if (amount == 0) return;
        held[token] -= amount;
        token.safeTransfer(to, amount);
    }
}
