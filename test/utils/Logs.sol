// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISenzuBorrowable} from "../../src/interfaces/ISenzuBorrowable.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Bad debt `borrowable` wrote off in `asset` in recorded logs (vm.recordLogs): the core keeps no running
///         total, an indexer sums the BadDebt events
function badDebtIn(Vm.Log[] memory logs, address borrowable, address asset) pure returns (uint256 total) {
    for (uint256 i; i < logs.length; ++i) {
        Vm.Log memory l = logs[i];
        if (l.emitter != borrowable || l.topics[0] != ISenzuBorrowable.BadDebt.selector) continue;
        if (address(uint160(uint256(l.topics[3]))) != asset) continue;
        total += abi.decode(l.data, (uint256));
    }
}
