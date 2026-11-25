// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SenzuBorrowable} from "../../core/SenzuBorrowable.sol";
import {IBorrowableDeployer, ISenzuDeployer} from "../../interfaces/IDeployers.sol";

/**
 *  @title  BorrowableDeployer
 *  @author Senzu
 *  @notice Deploys SenzuBorrowable contracts
 */
contract BorrowableDeployer is IBorrowableDeployer {
    address internal transient _factory;
    address internal transient _oracle;
    address internal transient _riskConfig;
    address internal transient _collateral;
    address internal transient _adapter;

    /// @inheritdoc ISenzuDeployer
    function parameters()
        external
        view
        override
        returns (address factory, address oracle, address riskConfig, address collateral, address adapter)
    {
        return (_factory, _oracle, _riskConfig, _collateral, _adapter);
    }

    /// @inheritdoc IBorrowableDeployer
    function deploy(address oracle, address riskConfig, address collateral, address adapter)
        external
        override
        returns (address borrowable)
    {
        (_factory, _oracle, _riskConfig, _collateral, _adapter) = (msg.sender, oracle, riskConfig, collateral, adapter);
        borrowable = address(new SenzuBorrowable());
    }
}
