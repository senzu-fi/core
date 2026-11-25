// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FeeLogic} from "../libraries/FeeLogic.sol";
import {HeldFeesAdapter} from "./HeldFeesAdapter.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/**
 *  @title  RewardLedger
 *  @author Senzu
 *  @notice Each holder's share of a position's rewards, as FeeLedger does for fees: a checkpoint per (account,
 *          position), at the position's reward growth per unit at every change of the account's units. Only what
 *          the DEX paid is booked: what it would pay now (`rewardGrowth`) is a view, never credited, so a reward the
 *          DEX cancels was never owed to anyone. Rewards not yet paid at a seize go with the seized units.
 */
abstract contract RewardLedger is HeldFeesAdapter {
    using SafeTransferLib for address;

    struct RewardCheckpoint {
        uint256 growthX128;
        uint256 owed;
    }

    /// @notice `amount` paid to `to`; `cut` to the protocol (`ISenzuRiskConfig.feeCut`)
    event ClaimRewards(address indexed account, uint256 indexed lpId, address to, uint256 amount, uint256 cut);

    /// @notice What rewards are paid in
    address public immutable rewardToken;

    /// @notice Rewards per unit of liquidity paid for each position
    mapping(uint256 lpId => uint256) public rewardGrowthX128;

    /// @notice Rewards received and not yet paid, for every position
    uint256 public rewardsHeld;

    /// @notice Cash rewards that arrived for each position and aren't paid yet: the most its holders are paid, so one
    ///         position is never paid from another's
    mapping(uint256 lpId => uint256) public positionRewards;

    /// @notice Reward checkpoint per holder and position
    // slither-disable-next-line uninitialized-state
    mapping(address account => mapping(uint256 lpId => RewardCheckpoint)) public rewardCheckpoints;

    constructor(address collateral_, address rewardToken_) HeldFeesAdapter(collateral_) {
        rewardToken = rewardToken_;
    }

    /// @notice A position's reward growth per unit as of now: booked, plus what the DEX would pay now
    function rewardGrowth(uint256 lpId) public view returns (uint256) {
        return rewardGrowthX128[lpId] + _unbookedRewardGrowth(lpId);
    }

    /// @notice Rewards `account` would be paid from a position now, after the protocol's cut, if the DEX pays what it
    ///         shows
    function rewardsOwed(address account, uint256 lpId) external view returns (uint256) {
        uint256 owed = _rewardsOwedBeforeCut(account, lpId);
        (uint256 cutWad,) = _feeCut();
        return owed - FeeLogic.cut(owed, cutWad);
    }

    function _rewardsOwedBeforeCut(address account, uint256 lpId) internal view virtual returns (uint256) {
        RewardCheckpoint memory cp = rewardCheckpoints[account][lpId];
        return _owed(cp, _balanceOf(account, lpId), rewardGrowth(lpId));
    }

    /// @dev Reward growth per unit the DEX would pay the position now, not yet booked
    function _unbookedRewardGrowth(uint256 lpId) internal view virtual returns (uint256);

    /// @dev Books what `arrived` for the position (paid, or deferred by the DEX to a later claim) over its
    ///      `liquidity`
    function _bookRewardGrowth(uint256 lpId, uint256 arrived, uint256 liquidity) internal {
        if (liquidity == 0 || arrived == 0) return;
        rewardGrowthX128[lpId] += FullMath.mulDiv(arrived, Q128, liquidity);
        positionRewards[lpId] += arrived;
    }

    /// @dev Rewards count in `held` with the fees: in a pool of the reward token, a deposit must not take them
    function _holdRewards(uint256 amount) internal {
        if (amount == 0) return;
        // Bookkeeping of what arrived, not a parameter: claims emit what leaves
        // forge-lint: disable-next-line(missing-events-arithmetic)
        rewardsHeld += amount;
        held[rewardToken] += amount;
    }

    /// @dev Pays `account` its rewards less the protocol's cut, which goes to the protocol
    function _payRewards(address account, uint256 lpId, address to) internal returns (uint256 amount) {
        RewardCheckpoint storage cp = rewardCheckpoints[account][lpId];
        amount = cp.owed;
        // Paid from what's available for this position; the rest stays owed (a deferred reward arrives with a later
        // claim)
        uint256 available = _availableRewards(lpId);
        if (amount > available) amount = available;
        if (amount == 0) return 0;
        cp.owed -= amount;
        (uint256 cutWad, address feeTo) = _feeCut();
        uint256 cut = FeeLogic.cut(amount, cutWad);
        _sendRewards(lpId, to, amount - cut, feeTo, cut);
        emit ClaimRewards(account, lpId, to, amount - cut, cut);
        return amount - cut;
    }

    /// @dev Cash rewards currently payable for `lpId`. Adapters that hold rewards in per-position accounts override it
    function _availableRewards(uint256 lpId) internal view virtual returns (uint256) {
        return positionRewards[lpId] < rewardsHeld ? positionRewards[lpId] : rewardsHeld;
    }

    /// @dev Sends `amount` of `rewardToken` to `to` and `cut` to `feeTo`
    function _sendRewards(uint256 lpId, address to, uint256 amount, address feeTo, uint256 cut) internal virtual {
        uint256 total = amount + cut;
        positionRewards[lpId] -= total;
        rewardsHeld -= total;
        held[rewardToken] -= total;
        if (cut > 0) rewardToken.safeTransfer(feeTo, cut);
        rewardToken.safeTransfer(to, amount);
    }

    /// @dev Every balance change but a seize checkpoints rewards too, at what was booked: the adapter books first
    function _checkpoint(address account, uint256 lpId, uint256 balance, uint256 growth0X128, uint256 growth1X128)
        internal
        override
    {
        super._checkpoint(account, lpId, balance, growth0X128, growth1X128);
        _checkpointRewards(account, lpId, balance);
    }

    /// @dev The seized units take their reward bookmark and their share of `from`'s credited `owed`, rounded down
    function _moveMarks(uint256 lpId, address from, address to, uint256 fromBalance, uint256 toBalance, uint256 units)
        internal
        override
    {
        super._moveMarks(lpId, from, to, fromBalance, toBalance, units);
        RewardCheckpoint storage moved = rewardCheckpoints[from][lpId];
        RewardCheckpoint storage cp = rewardCheckpoints[to][lpId];
        cp.growthX128 = FeeLogic.mergeMark(cp.growthX128, moved.growthX128, toBalance, units, rewardGrowthX128[lpId]);
        if (fromBalance > 0) {
            uint256 owed = moved.owed;
            if (owed > 0) {
                uint256 share = units < fromBalance ? units : fromBalance;
                uint256 movedOwed = share == fromBalance ? owed : FullMath.mulDiv(owed, share, fromBalance);
                moved.owed = owed - movedOwed;
                cp.owed += movedOwed;
            }
        }
    }

    function _checkpointRewards(address account, uint256 lpId, uint256 balance) internal {
        RewardCheckpoint storage cp = rewardCheckpoints[account][lpId];
        uint256 growthX128 = rewardGrowthX128[lpId];
        cp.owed = _owed(cp, balance, growthX128);
        cp.growthX128 = growthX128;
    }

    /// @dev Credited by the growth since the checkpoint
    function _owed(RewardCheckpoint memory cp, uint256 balance, uint256 growthX128) private pure returns (uint256) {
        return cp.owed + FullMath.mulDiv(balance, growthX128 - cp.growthX128, Q128);
    }
}
