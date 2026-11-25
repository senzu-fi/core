// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {MarketLogic} from "../src/libraries/MarketLogic.sol";
import {Rounding} from "../src/libraries/Types.sol";
import {Test} from "forge-std/Test.sol";

/// @notice A market whose every supplied asset was written off (assets 0, lender shares still out), then a deposit:
///         where empty-market rounding exploits (Hundred Finance, Sonne) live
contract DepositAfterWriteOffTest is Test {
    function toShares(uint256 a, uint256 ta, uint256 ts) external pure returns (uint256) {
        return MarketLogic.toShares(a, ta, ts, Rounding.Down);
    }

    function toAssets(uint256 s, uint256 ta, uint256 ts) external pure returns (uint256) {
        return MarketLogic.toAssets(s, ta, ts, Rounding.Down);
    }

    /// @dev Outstanding shares up to a uint128 of assets' worth (1e6 shares per wei), deposits up to 1e30: the
    ///      depositor gets its deposit back less at most 1 wei, and the wiped-out shares claim at most 1 wei of it
    function testFuzz_depositAfterFullWriteOff_getsItsDepositBack(uint256 oldShares, uint256 deposit) public view {
        oldShares = bound(oldShares, 1, uint256(type(uint128).max) * 1e6);
        deposit = bound(deposit, 1, 1e30);
        uint256 minted = this.toShares(deposit, 0, oldShares);
        uint256 back = this.toAssets(minted, deposit, oldShares + minted);
        uint256 oldWorth = this.toAssets(oldShares, deposit, oldShares + minted);
        assertLe(back, deposit, "no gain");
        assertGe(back + 1, deposit, "the depositor loses at most 1 wei");
        assertLe(oldWorth, 1, "the wiped-out shares claim at most 1 wei of it");
    }
}
