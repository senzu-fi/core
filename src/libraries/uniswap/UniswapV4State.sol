// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/**
 *  @title  UniswapV4State
 *  @author Senzu
 *  @notice The PoolManager state the v4 adapter reads, through its `extsload`, on v4-core StateLibrary's storage
 *          layout. A fee read takes one batched `extsload` where StateLibrary makes five calls
 */
library UniswapV4State {
    /// @dev PoolManager's `mapping(PoolId => Pool.State) pools`
    uint256 private constant POOLS_SLOT = 6;
    uint256 private constant FEE_GROWTH_GLOBAL0_OFFSET = 1;
    uint256 private constant TICKS_OFFSET = 4;
    uint256 private constant POSITIONS_OFFSET = 6;

    function sqrtPriceX96(IPoolManager manager, bytes32 poolId) internal view returns (uint160) {
        return uint160(uint256(manager.extsload(_poolSlot(poolId))));
    }

    /// @notice The fee growth inside the range now and a position's growth at its last change, in one `extsload`
    function positionFees(
        IPoolManager manager,
        bytes32 poolId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) internal view returns (uint256 inside0, uint256 inside1, uint256 last0, uint256 last1) {
        uint256 pool = uint256(_poolSlot(poolId));
        uint256 lower = uint256(_tickSlot(pool, tickLower));
        uint256 upper = uint256(_tickSlot(pool, tickUpper));
        // v4's Position.calculatePositionKey
        bytes32 key = keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
        uint256 position = uint256(keccak256(abi.encode(key, pool + POSITIONS_OFFSET)));
        bytes32[] memory slots = new bytes32[](9);
        slots[0] = bytes32(pool);
        slots[1] = bytes32(pool + FEE_GROWTH_GLOBAL0_OFFSET);
        slots[2] = bytes32(pool + FEE_GROWTH_GLOBAL0_OFFSET + 1);
        slots[3] = bytes32(lower + 1);
        slots[4] = bytes32(lower + 2);
        slots[5] = bytes32(upper + 1);
        slots[6] = bytes32(upper + 2);
        slots[7] = bytes32(position + 1);
        slots[8] = bytes32(position + 2);
        bytes32[] memory v = manager.extsload(slots);

        int24 tick = int24(int256(uint256(v[0]) >> 160));
        (uint256 global0, uint256 global1) = (uint256(v[1]), uint256(v[2]));
        (uint256 lower0, uint256 lower1) = (uint256(v[3]), uint256(v[4]));
        (uint256 upper0, uint256 upper1) = (uint256(v[5]), uint256(v[6]));
        (last0, last1) = (uint256(v[7]), uint256(v[8]));
        // v4's Pool.getFeeGrowthInside, whose arithmetic must wrap
        unchecked {
            if (tick < tickLower) {
                inside0 = lower0 - upper0;
                inside1 = lower1 - upper1;
            } else if (tick >= tickUpper) {
                inside0 = upper0 - lower0;
                inside1 = upper1 - lower1;
            } else {
                inside0 = global0 - lower0 - upper0;
                inside1 = global1 - lower1 - upper1;
            }
        }
    }

    /// @notice A position's liquidity in the PoolManager (v4's `Position.State.liquidity`)
    function positionLiquidity(
        IPoolManager manager,
        bytes32 poolId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) internal view returns (uint256) {
        bytes32 key = keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
        uint256 pool = uint256(_poolSlot(poolId));
        return uint256(manager.extsload(keccak256(abi.encode(key, pool + POSITIONS_OFFSET))));
    }

    function _poolSlot(bytes32 poolId) private pure returns (bytes32) {
        return keccak256(abi.encode(poolId, POOLS_SLOT));
    }

    function _tickSlot(uint256 pool, int24 tick) private pure returns (bytes32) {
        return keccak256(abi.encode(int256(tick), pool + TICKS_OFFSET));
    }
}
