// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 *  @title  PoolRegistry
 *  @author Senzu
 *  @notice Numbers each pool the first time a position opens in it, so a position stores a 4-byte index instead of
 *          the pool's key. The adapter keeps the pool's details in its own `_pools[index]`. For adapters whose pool key
 *          doesn't fit in the position's storage slot (v4 and Ekubo pool keys, Aero's pool and gauge)
 */
abstract contract PoolRegistry {
    uint32 private _poolCount;

    mapping(bytes32 poolId => uint32) private _poolIndexOf;

    /// @return index From 1
    /// @return isNew When this call numbered the pool: the adapter stores its details then
    function _registerPool(bytes32 poolId) internal returns (uint32 index, bool isNew) {
        index = _poolIndexOf[poolId];
        if (index != 0) return (index, false);
        index = ++_poolCount;
        _poolIndexOf[poolId] = index;
        return (index, true);
    }
}
