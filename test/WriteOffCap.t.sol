// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {WriteOffHarness, WriteOffHarnessDeployer} from "../script/sdk/WriteOffHarness.sol";
import {Market} from "../src/libraries/Types.sol";
import {Test, Vm} from "forge-std/Test.sol";

/// @notice Audit M-03: a write-off's debt rounds up and can pass the market's debt; lenders lose only that
contract WriteOffCapTest is Test {
    function test_writeOff_takesAtMostTheMarketsDebt() public {
        WriteOffHarness h = new WriteOffHarnessDeployer().deploy();
        Market memory m;
        (m.totalSupplyAssets, m.totalBorrowAssets, m.totalBorrowShares) = (1000, 2, 9e6);
        // 9e6 shares at (2 + 1) / (9e6 + 1e6) owe 2.7, rounded up to 3: one more than the market's debt
        (Market memory next, uint256 left) = h.runWriteOff(m, 9e6);
        assertEq(left, 0);
        assertEq(next.totalBorrowAssets, 0);
        assertEq(next.totalSupplyAssets, 998, "lenders lose the 2 lent, not 3");
    }

    function test_writeOff_theLastSharesLeaveNoDebt() public {
        WriteOffHarness h = new WriteOffHarnessDeployer().deploy();
        Market memory m;
        (m.totalSupplyAssets, m.totalBorrowAssets, m.totalBorrowShares) = (1000, 100, 1e6);
        // 1e6 shares at (100 + 1) / (1e6 + 1e6) owe 51: the virtual shares hold the other 49, which no one owes
        vm.recordLogs();
        (Market memory next, uint256 left) = h.runWriteOff(m, 1e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(abi.decode(logs[logs.length - 1].data, (uint256)), 100, "BadDebt reports what lenders lost");
        assertEq(left, 0);
        assertEq(next.totalBorrowShares, 0);
        assertEq(next.totalBorrowAssets, 0, "no debt left that no one owes");
        assertEq(next.totalSupplyAssets, 900, "lenders lose all that was lent");
    }

    function test_writeOff_sharesLeftLoseOnlyTheirDebt() public {
        WriteOffHarness h = new WriteOffHarnessDeployer().deploy();
        Market memory m;
        (m.totalSupplyAssets, m.totalBorrowAssets, m.totalBorrowShares) = (1000, 100, 2e6);
        // 1e6 of 2e6 shares at (100 + 1) / (2e6 + 1e6) owe 33.67, rounded up to 34
        (Market memory next,) = h.runWriteOff(m, 1e6);
        assertEq(next.totalBorrowAssets, 66);
        assertEq(next.totalSupplyAssets, 966);
    }
}
