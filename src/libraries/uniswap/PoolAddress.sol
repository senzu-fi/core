// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library PoolAddress {
    bytes32 internal constant POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    /// @notice The pool of sorted `token0` < `token1` and `fee`
    function compute(address factory, address token0, address token1, uint24 fee) internal pure returns (address) {
        bytes32 salt = keccak256(abi.encode(token0, token1, fee));
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", factory, salt, POOL_INIT_CODE_HASH)))));
    }
}
