// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBorrowableDeployer, ICollateralDeployer} from "../interfaces/IDeployers.sol";
import {ISenzuAdapter} from "../interfaces/ISenzuAdapter.sol";
import {ISenzuFactory} from "../interfaces/ISenzuFactory.sol";
import {ISenzuRiskConfig} from "../interfaces/ISenzuRiskConfig.sol";
import {SenzuOracle} from "./SenzuOracle.sol";
import {SenzuRiskConfig} from "./SenzuRiskConfig.sol";

/**
 *  @title  SenzuFactory
 *  @author Senzu
 *  @notice Admin registry for every Senzu deployment. Deploys one isolated set per DEX (a SenzuBorrowable and a
 *          SenzuCollateral around one adapter, wired to each other immutably) and the one SenzuOracle and
 *          SenzuRiskConfig they all share. Holds no funds.
 */
contract SenzuFactory is ISenzuFactory {
    /// @inheritdoc ISenzuFactory
    address public override admin;

    /// @inheritdoc ISenzuFactory
    address public override pendingAdmin;

    /// @inheritdoc ISenzuFactory
    address public override guardian;

    /// @inheritdoc ISenzuFactory
    address public override protocolReserves;

    /// @inheritdoc ISenzuFactory
    address public immutable override oracle;

    /// @inheritdoc ISenzuFactory
    address public immutable override riskConfig;

    /// @inheritdoc ISenzuFactory
    address public immutable override borrowableDeployer;

    /// @inheritdoc ISenzuFactory
    address public immutable override collateralDeployer;

    Deployment[] internal _deployments;

    mapping(bytes32 name => uint256) internal _byName;
    mapping(address collateral => bool) internal _isCollateral;

    constructor(
        address admin_,
        address guardian_,
        address protocolReserves_,
        address borrowableDeployer_,
        address collateralDeployer_
    ) {
        if (
            admin_ == address(0) || protocolReserves_ == address(0) || borrowableDeployer_ == address(0)
                || collateralDeployer_ == address(0)
        ) revert SenzuFactory__ZeroAddress();
        admin = admin_;
        guardian = guardian_;
        protocolReserves = protocolReserves_;
        borrowableDeployer = borrowableDeployer_;
        collateralDeployer = collateralDeployer_;
        oracle = address(new SenzuOracle(address(this)));
        riskConfig = address(new SenzuRiskConfig(address(this)));
        emit NewAdmin(address(0), admin_);
        emit NewGuardian(address(0), guardian_);
        emit NewProtocolReserves(address(0), protocolReserves_);
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert SenzuFactory__NotAdmin();
        _;
    }

    /// @inheritdoc ISenzuFactory
    function deploymentsLength() external view override returns (uint256) {
        return _deployments.length;
    }

    /// @inheritdoc ISenzuFactory
    function getDeployment(uint256 index) external view override returns (Deployment memory) {
        return _deployments[index];
    }

    /// @inheritdoc ISenzuFactory
    function getDeploymentByName(bytes32 name) external view override returns (Deployment memory) {
        uint256 i = _byName[name];
        if (i == 0) revert SenzuFactory__UnknownName(name);
        return _deployments[i - 1];
    }

    /// @inheritdoc ISenzuFactory
    function isCollateral(address collateral) public view override returns (bool) {
        return _isCollateral[collateral];
    }

    /// @inheritdoc ISenzuFactory
    function setPendingAdmin(address newPendingAdmin) external override onlyAdmin {
        emit NewPendingAdmin(pendingAdmin, newPendingAdmin);
        pendingAdmin = newPendingAdmin;
    }

    /// @inheritdoc ISenzuFactory
    function acceptAdmin() external override {
        if (msg.sender != pendingAdmin) revert SenzuFactory__NotPendingAdmin();
        emit NewAdmin(admin, msg.sender);
        emit NewPendingAdmin(msg.sender, address(0));
        admin = msg.sender;
        pendingAdmin = address(0);
    }

    /// @inheritdoc ISenzuFactory
    function setGuardian(address newGuardian) external override onlyAdmin {
        emit NewGuardian(guardian, newGuardian);
        guardian = newGuardian;
    }

    /// @inheritdoc ISenzuFactory
    function setProtocolReserves(address newProtocolReserves) external override onlyAdmin {
        if (newProtocolReserves == address(0)) revert SenzuFactory__ZeroAddress();
        emit NewProtocolReserves(protocolReserves, newProtocolReserves);
        protocolReserves = newProtocolReserves;
    }

    /// @inheritdoc ISenzuFactory
    function collateralAddress(bytes32 name) public view override returns (address) {
        return ICollateralDeployer(collateralDeployer).collateralAddress(name, address(this));
    }

    /// @inheritdoc ISenzuFactory
    function deploy(bytes32 name, address adapter) external override onlyAdmin returns (Deployment memory d) {
        if (_byName[name] != 0) revert SenzuFactory__NameTaken(name);

        address collateral = collateralAddress(name);
        if (adapter.code.length == 0 || ISenzuAdapter(adapter).collateral() != collateral) {
            revert SenzuFactory__AdapterMismatch(adapter, collateral);
        }

        d.name = name;
        d.adapter = adapter;
        d.borrowable = IBorrowableDeployer(borrowableDeployer).deploy(oracle, riskConfig, collateral, adapter);
        d.collateral = ICollateralDeployer(collateralDeployer).deploy(name, oracle, riskConfig, d.borrowable, adapter);
        if (d.collateral != collateral) revert SenzuFactory__CollateralAddressMismatch(collateral, d.collateral);
        ISenzuRiskConfig(riskConfig).addDex(adapter);

        _deployments.push(d);
        _byName[name] = _deployments.length;
        _isCollateral[d.collateral] = true;

        emit DeploymentCreated(_deployments.length - 1, name, d.borrowable, d.collateral, d.adapter);
    }
}
