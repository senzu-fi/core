// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 *  @title  IBorrowableDeployer / ICollateralDeployer
 *  @notice Deployers used by SenzuFactory, which can't carry the borrowable's and collateral's creation code itself
 *          (24 KB limit). Permissionless; each makes its caller the factory of what it deploys. Only SenzuFactory's
 *          registry (isCollateral, getDeployment) says which sets are Senzu's.
 *
 *          The collateral is created with CREATE2 and no constructor arguments (it reads them back from its
 *          deployer), so its address is known before it exists.
 */
/// @notice What both deployers give what they create, read back in its constructor (SenzuCore): the factory (the
///         caller of `deploy`), the oracle, the risk config, the counterpart (the collateral for a borrowable, the
///         borrowable for a collateral) and the set's adapter. Written by each `deploy`.
interface ISenzuDeployer {
    function parameters()
        external
        view
        returns (address factory, address oracle, address riskConfig, address counterpart, address adapter);
}

interface IBorrowableDeployer is ISenzuDeployer {
    /// @notice A borrowable whose factory is the caller, lending only to `collateral`
    function deploy(address oracle, address riskConfig, address collateral, address adapter)
        external
        returns (address borrowable);
}

interface ICollateralDeployer is ISenzuDeployer {
    /// @notice keccak256 of SenzuCollateral's creation code (the same for every set: it takes no arguments)
    function initCodeHash() external view returns (bytes32);

    /// @notice Where `deploy(salt, …)` called by `factory` creates its collateral
    function collateralAddress(bytes32 salt, address factory) external view returns (address);

    /// @notice A collateral whose factory is the caller, at `collateralAddress(salt, msg.sender)`
    function deploy(bytes32 salt, address oracle, address riskConfig, address borrowable, address adapter)
        external
        returns (address collateral);
}
