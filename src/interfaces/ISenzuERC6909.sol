// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC6909TokenSupply} from "@openzeppelin/contracts/interfaces/IERC6909.sol";

/**
 *  @title  ISenzuERC6909
 *  @notice ERC-6909 with totalSupply and `setOperator` by EIP-712 signature (what EIP-2612 `permit` is to ERC-20).
 */
interface ISenzuERC6909 is IERC6909TokenSupply {
    error ERC6909__SignatureExpired();
    error ERC6909__InvalidSignature();

    /// @notice EIP-712 domain separator (name per contract, version "1"), recomputed if the chain forks
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice Signature nonce of `owner`, consumed by each `setOperatorBySig`
    function nonces(address owner) external view returns (uint256);

    /// @notice `setOperator` on `owner`'s behalf with their EIP-712 signature of
    ///         SetOperator(address owner,address operator,bool approved,uint256 nonce,uint256 deadline)
    function setOperatorBySig(
        address owner,
        address operator,
        bool approved,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}
