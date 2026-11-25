// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISenzuERC6909} from "./ISenzuERC6909.sol";

/**
 *  @title  ISenzuCore
 *  @notice What SenzuBorrowable and SenzuCollateral share (SenzuCore): the ERC-6909 token, the set's wiring
 *          (factory, oracle, risk config, adapter), the reentrancy guard and the per-DEX pause check.
 */
interface ISenzuCore is ISenzuERC6909 {
    error SenzuCore__NotAdmin();
    error SenzuCore__Reentrant();
    error SenzuCore__Paused(bytes32 action);

    /// @notice The SenzuFactory that deployed this set
    function factory() external view returns (address);

    /// @notice USD price oracle shared by every deployment
    function oracle() external view returns (address);

    /// @notice The one risk config, whose settings for this deployment are keyed by its collateral
    function riskConfig() external view returns (address);

    /// @notice The set's one adapter, which positions open through. Immutable, on both contracts
    function adapter() external view returns (address);
}
