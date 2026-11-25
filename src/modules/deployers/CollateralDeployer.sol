// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SenzuCollateral} from "../../core/SenzuCollateral.sol";
import {ICollateralDeployer, ISenzuDeployer} from "../../interfaces/IDeployers.sol";

/**
 *  @title  CollateralDeployer
 *  @author Senzu
 *  @notice Deploys SenzuCollateral contracts at CREATE2 addresses known before they exist
 */
contract CollateralDeployer is ICollateralDeployer {
    /// @inheritdoc ICollateralDeployer
    bytes32 public immutable override initCodeHash = keccak256(type(SenzuCollateral).creationCode);

    address internal transient _factory;
    address internal transient _oracle;
    address internal transient _riskConfig;
    address internal transient _borrowable;
    address internal transient _adapter;

    /// @inheritdoc ICollateralDeployer
    function collateralAddress(bytes32 salt, address factory) public view override returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(salt, factory), initCodeHash));
        return address(uint160(uint256(hash)));
    }

    /// @inheritdoc ISenzuDeployer
    function parameters()
        external
        view
        override
        returns (address factory, address oracle, address riskConfig, address borrowable, address adapter)
    {
        return (_factory, _oracle, _riskConfig, _borrowable, _adapter);
    }

    /// @inheritdoc ICollateralDeployer
    function deploy(bytes32 salt, address oracle, address riskConfig, address borrowable, address adapter)
        external
        override
        returns (address collateral)
    {
        (_factory, _oracle, _riskConfig, _borrowable, _adapter) = (msg.sender, oracle, riskConfig, borrowable, adapter);
        collateral = address(new SenzuCollateral{salt: _salt(salt, msg.sender)}());
    }

    function _salt(bytes32 salt, address factory) private pure returns (bytes32) {
        return keccak256(abi.encode(salt, factory));
    }
}
