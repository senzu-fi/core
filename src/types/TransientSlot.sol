// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice A transient storage slot (EIP-1153): cleared at the end of every transaction
type TransientSlot is bytes32;

using {load, store, offset} for TransientSlot global;

function load(TransientSlot slot) view returns (uint256 value) {
    assembly ("memory-safe") {
        value := tload(slot)
    }
}

function store(TransientSlot slot, uint256 value) {
    assembly ("memory-safe") {
        tstore(slot, value)
    }
}

/// @notice The slot `n` slots after this one
function offset(TransientSlot slot, uint256 n) pure returns (TransientSlot) {
    unchecked {
        return TransientSlot.wrap(bytes32(uint256(TransientSlot.unwrap(slot)) + n));
    }
}
