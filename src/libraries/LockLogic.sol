// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ISenzuCollateral} from "../interfaces/ISenzuCollateral.sol";
import {TransientSlot} from "../types/TransientSlot.sol";

/**
 *  @title  LockLogic
 *  @author Senzu
 *  @notice SenzuCollateral's transient `lock()` state, all of it cleared when the lock ends:
 *            - the deferred health checks: a count, then one (account, id) entry per changed position, two slots each,
 *              and a flag per (account, id) so a position is queued once
 *            - the unsettled repayment per asset (a liquidation's, until `settle` pays it), at UNSETTLED + asset
 *              (like Ekubo's debts, no hashing), and how many assets have one
 */
library LockLogic {
    TransientSlot internal constant DEFERRED_COUNT =
        TransientSlot.wrap(keccak256("senzu.collateral.deferredChecks.count"));
    TransientSlot internal constant DEFERRED_ENTRIES =
        TransientSlot.wrap(keccak256("senzu.collateral.deferredChecks.entries"));
    bytes32 internal constant DEFERRED_FLAGS = keccak256("senzu.collateral.deferredChecks.flags");
    TransientSlot internal constant UNSETTLED = TransientSlot.wrap(keccak256("senzu.collateral.unsettled"));
    TransientSlot internal constant UNSETTLED_COUNT = TransientSlot.wrap(keccak256("senzu.collateral.unsettled.count"));

    function _entry(uint256 i) private pure returns (TransientSlot) {
        return DEFERRED_ENTRIES.offset(2 * i);
    }

    function _flag(address account, uint256 id) private pure returns (TransientSlot) {
        return TransientSlot.wrap(keccak256(abi.encode(DEFERRED_FLAGS, account, id)));
    }

    /// @notice Whether (account, id) is queued for a deferred check
    function isDeferred(address account, uint256 id) internal view returns (bool) {
        return _flag(account, id).load() != 0;
    }

    /// @notice Queues (account, id) for a health check when the lock ends, once
    function defer(address account, uint256 id) internal {
        TransientSlot flag = _flag(account, id);
        if (flag.load() != 0) return;
        flag.store(1);
        uint256 n = DEFERRED_COUNT.load();
        TransientSlot entry = _entry(n);
        entry.store(uint160(account));
        entry.offset(1).store(id);
        DEFERRED_COUNT.store(n + 1);
    }

    /// @notice How many checks are queued
    function deferredCount() internal view returns (uint256) {
        return DEFERRED_COUNT.load();
    }

    /// @notice Deferred check `i`, unflagged so the same position can be queued again in a later lock
    function takeDeferred(uint256 i) internal returns (address account, uint256 id) {
        TransientSlot entry = _entry(i);
        // forge-lint: disable-next-line(unsafe-typecast)
        account = address(uint160(entry.load()));
        id = entry.offset(1).load();
        _flag(account, id).store(0);
    }

    /// @notice Empties the queue, after every check has been taken
    function clearDeferred() internal {
        DEFERRED_COUNT.store(0);
    }

    function _unsettled(address asset) private pure returns (TransientSlot) {
        return UNSETTLED.offset(uint160(asset));
    }

    /// @notice Adds `amount` to the lock's unsettled repayment in `asset`: one more asset to settle if it had none
    function addUnsettled(address asset, uint256 amount) internal {
        if (amount == 0) return;
        TransientSlot slot = _unsettled(asset);
        uint256 unsettled = slot.load();
        if (unsettled == 0) UNSETTLED_COUNT.store(UNSETTLED_COUNT.load() + 1);
        slot.store(unsettled + amount);
    }

    /// @notice Takes `amount` off the lock's unsettled repayment in `asset`: one asset fewer to settle if none is left
    function subUnsettled(address asset, uint256 amount) internal {
        if (amount == 0) return;
        TransientSlot slot = _unsettled(asset);
        uint256 unsettled = slot.load();
        if (amount > unsettled) revert ISenzuCollateral.SenzuCollateral__MoreThanUnsettled();
        if (amount == unsettled) UNSETTLED_COUNT.store(UNSETTLED_COUNT.load() - 1);
        slot.store(unsettled - amount);
    }

    /// @notice How many assets have an unsettled repayment: lock() ends only at zero
    function unsettledCount() internal view returns (uint256) {
        return UNSETTLED_COUNT.load();
    }
}
