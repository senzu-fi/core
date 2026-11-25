// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISenzuERC6909} from "../interfaces/ISenzuERC6909.sol";
import {ERC6909TokenSupply} from "@openzeppelin/contracts/token/ERC6909/extensions/ERC6909TokenSupply.sol";

/**
 *  @title  SenzuERC6909
 *  @notice OpenZeppelin's ERC-6909 with totalSupply, plus `setOperatorBySig` (operator approval by EIP-712
 *          signature).
 */
abstract contract SenzuERC6909 is ERC6909TokenSupply, ISenzuERC6909 {
    /// @inheritdoc ISenzuERC6909
    mapping(address owner => uint256) public nonces;

    bytes32 internal constant SET_OPERATOR_TYPEHASH =
        keccak256("SetOperator(address owner,address operator,bool approved,uint256 nonce,uint256 deadline)");

    bytes32 internal immutable _hashedName;
    uint256 internal immutable _cachedChainId;
    bytes32 internal immutable _cachedDomainSeparator;

    /// @param name_ The EIP-712 domain name
    constructor(string memory name_) {
        _hashedName = keccak256(bytes(name_));
        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _domainSeparator();
    }

    /// @inheritdoc ISenzuERC6909
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == _cachedChainId ? _cachedDomainSeparator : _domainSeparator();
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                _hashedName,
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    /// @inheritdoc ISenzuERC6909
    function setOperatorBySig(
        address owner,
        address operator,
        bool approved,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert ERC6909__SignatureExpired();

        bytes32 structHash =
            keccak256(abi.encode(SET_OPERATOR_TYPEHASH, owner, operator, approved, nonces[owner]++, deadline));
        // forge-lint: disable-next-line(ecrecover)
        address signer = ecrecover(keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash)), v, r, s);
        if (signer == address(0) || signer != owner) revert ERC6909__InvalidSignature();

        _setOperator(owner, operator, approved);
    }
}
