// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISenzuAdapter} from "../interfaces/ISenzuAdapter.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/**
 *  @title  BaseAdapter
 *  @author Senzu
 */
abstract contract BaseAdapter is ISenzuAdapter {
    /// @inheritdoc ISenzuAdapter
    address public immutable override collateral;

    constructor(address collateral_) {
        collateral = collateral_;
    }

    /// @inheritdoc ISenzuAdapter
    function quoteDeposit(bytes calldata) external view virtual override returns (address, address, uint256, uint256) {
        revert SenzuAdapter__NoExactDeposit();
    }

    modifier onlyCollateral() {
        _requireCollateral();
        _;
    }

    function _requireCollateral() private view {
        if (msg.sender != collateral) revert SenzuAdapter__NotCollateral();
    }

    /// @dev Sends `to` both tokens of a pair, skipping a zero amount
    function _sendPair(address token0, address token1, uint256 left0, uint256 left1, address to) internal {
        if (left0 > 0) SafeTransferLib.safeTransfer(token0, to, left0);
        if (left1 > 0) SafeTransferLib.safeTransfer(token1, to, left1);
    }
}
