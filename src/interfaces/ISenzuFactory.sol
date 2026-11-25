// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 *  @title  ISenzuFactory
 *  @notice Admin registry for every Senzu deployment, each an isolated (SenzuBorrowable, SenzuCollateral,
 *          adapter) set: lenders of one deployment are never exposed to another's positions. Also records the admin,
 *          guardian, protocol reserves, the shared oracle and the shared risk config. Holds no funds.
 */
interface ISenzuFactory {
    /// @notice One isolated deployment
    struct Deployment {
        bytes32 name;
        address borrowable;
        address collateral;
        address adapter;
    }

    error SenzuFactory__NotAdmin();
    error SenzuFactory__NotPendingAdmin();
    error SenzuFactory__ZeroAddress();
    error SenzuFactory__NameTaken(bytes32 name);
    error SenzuFactory__UnknownName(bytes32 name);
    error SenzuFactory__AdapterMismatch(address adapter, address collateral);
    error SenzuFactory__CollateralAddressMismatch(address expected, address deployed);

    event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);
    event NewAdmin(address oldAdmin, address newAdmin);
    event NewGuardian(address oldGuardian, address newGuardian);
    event NewProtocolReserves(address oldProtocolReserves, address newProtocolReserves);
    event DeploymentCreated(
        uint256 indexed index, bytes32 indexed name, address borrowable, address collateral, address adapter
    );

    function admin() external view returns (address);
    function pendingAdmin() external view returns (address);
    function guardian() external view returns (address);
    function protocolReserves() external view returns (address);

    /// @notice The risk config every deployment reads, created with this factory; each setting in it is per DEX
    function riskConfig() external view returns (address);

    /// @notice USD price oracle shared by every deployment (set once)
    function oracle() external view returns (address);

    /// @notice Deployer contracts used by `deploy`
    function borrowableDeployer() external view returns (address);
    function collateralDeployer() external view returns (address);

    function deploymentsLength() external view returns (uint256);
    function getDeployment(uint256 index) external view returns (Deployment memory);

    /// @notice Deployment by name (reverts if unknown)
    function getDeploymentByName(bytes32 name) external view returns (Deployment memory);

    /// @notice Whether `collateral` belongs to a registered deployment
    function isCollateral(address collateral) external view returns (bool);

    function setPendingAdmin(address newPendingAdmin) external;
    function acceptAdmin() external;
    function setGuardian(address newGuardian) external;
    function setProtocolReserves(address newProtocolReserves) external;

    /// @notice Where the collateral of the set named `name` is (or will be) created: deploy the set's adapter with it
    function collateralAddress(bytes32 name) external view returns (address);

    /**
     *  @notice Admin only. Deploys a new isolated set (borrowable, collateral) with `adapter`, which must have been
     *          deployed with `collateralAddress(name)` as its collateral, adds the DEX to the risk config and
     *          registers the set under `name`. The borrowable, the collateral and the adapter hold each other's
     *          addresses as immutables.
     */
    function deploy(bytes32 name, address adapter) external returns (Deployment memory deployment);
}
