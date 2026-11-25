// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @notice One debt of a position: `shares << 8 | marketIndex`, shares below 2^119 (built by `DebtLanes.lane`).
///         Zero is an empty lane
type DebtLane is uint256;

using {marketIndex, shares, isEmpty} for DebtLane global;

function marketIndex(DebtLane lane) pure returns (uint8) {
    // forge-lint: disable-next-line(unsafe-typecast)
    return uint8(DebtLane.unwrap(lane));
}

function shares(DebtLane lane) pure returns (uint256) {
    return DebtLane.unwrap(lane) >> 8;
}

function isEmpty(DebtLane lane) pure returns (bool) {
    return DebtLane.unwrap(lane) == 0;
}
