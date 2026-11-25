// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 *  @title  ISenzuRewardsAdapter
 *  @author Senzu
 *  @notice The calls of an adapter whose positions can stake in a gauge for rewards (AeroCLAdapter, FablesAdapter).
 *          Each takes the account, or its operator on the collateral
 */
interface ISenzuRewardsAdapter {
    /// @notice Stakes a position or unstakes it for good, paying the account what it is owed in it
    function setStake(address account, uint256 lpId, bool on) external;

    /// @notice Pays `account`'s rewards from a position to `to`
    function claimRewards(address account, uint256 lpId, address to) external returns (uint256 amount);
}
