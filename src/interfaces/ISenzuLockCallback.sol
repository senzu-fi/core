// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 *  @title  ISenzuLockCallback
 *  @notice Implemented by routers that call `SenzuCollateral.lock()`. Inside the callback the caller can supply,
 *          borrow, add liquidity, redeem, repay and liquidate in any order, and must `settle` its liquidations before
 *          it returns. Health is checked once, after it returns.
 */
interface ISenzuLockCallback {
    /**
     *  @notice Called by SenzuCollateral on the caller of `lock()`, with the lock held
     *  @param data What the caller passed to `lock()`
     *  @return What `lock()` returns to its caller
     */
    function senzuLockAcquired(bytes calldata data) external returns (bytes memory);
}
