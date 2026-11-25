// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ISenzuCore} from "../interfaces/ISenzuCore.sol";
import {SenzuERC6909} from "../tokens/SenzuERC6909.sol";

import {ISenzuDeployer} from "../interfaces/IDeployers.sol";
import {ISenzuRiskConfig} from "../interfaces/ISenzuRiskConfig.sol";

/**
 *  @title  SenzuCore
 *  @author Senzu
 *  @notice Base of SenzuBorrowable and SenzuCollateral: the ERC-6909 token and the set's immutable wiring
 */
abstract contract SenzuCore is ISenzuCore, SenzuERC6909 {
    /// @dev Transient reentrancy lock
    bool internal transient _entered;
    /// @dev The other half of the set: `borrowable()` in the collateral, `collateral()` in the borrowable
    address internal immutable _counterpart;

    /// @inheritdoc ISenzuCore
    address public immutable override factory;
    /// @inheritdoc ISenzuCore
    address public immutable override oracle;
    /// @inheritdoc ISenzuCore
    address public immutable override riskConfig;
    /// @inheritdoc ISenzuCore
    address public immutable override adapter;

    constructor(string memory name_) SenzuERC6909(name_) {
        (factory, oracle, riskConfig, _counterpart, adapter) = ISenzuDeployer(msg.sender).parameters();
    }

    modifier nonReentrant() {
        if (_entered) revert SenzuCore__Reentrant();
        _entered = true;
        _;
        _entered = false;
    }

    modifier whenNotPaused(bytes32 action) {
        if (ISenzuRiskConfig(riskConfig).isPaused(adapter, action)) revert SenzuCore__Paused(action);
        _;
    }
}
