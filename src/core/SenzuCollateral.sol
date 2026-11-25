// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ISenzuCollateral} from "../interfaces/ISenzuCollateral.sol";
import {SenzuCore} from "./SenzuCore.sol";
import {IERC6909} from "@openzeppelin/contracts/interfaces/IERC6909.sol";
import {ERC6909} from "@openzeppelin/contracts/token/ERC6909/ERC6909.sol";

import {HealthLogic} from "../libraries/HealthLogic.sol";
import {LiquidationLogic} from "../libraries/LiquidationLogic.sol";
import {LockLogic} from "../libraries/LockLogic.sol";
import {ACTION_OPEN, HealthResult} from "../libraries/Types.sol";

import {ISenzuAdapter} from "../interfaces/ISenzuAdapter.sol";
import {ISenzuBorrowable} from "../interfaces/ISenzuBorrowable.sol";
import {ISenzuFactory} from "../interfaces/ISenzuFactory.sol";
import {ISenzuLockCallback} from "../interfaces/ISenzuLockCallback.sol";
import {ISenzuRiskConfig} from "../interfaces/ISenzuRiskConfig.sol";

/**
 *  @title  SenzuCollateral
 *  @author Senzu
 *  @notice The borrowers' side of one Senzu deployment. Every DEX position opened through it is an ERC-6909 id whose
 *          non-transferable units borrow from the paired SenzuBorrowable. Health is enforced after risk-increasing
 *          actions, on redeem, at the end of `lock()`, and in liquidations, by what the adapter says the units hold
 *          at the oracle's price and the four stress corners. Invariant: totalSupply(id) == adapter.units(id).
 */
contract SenzuCollateral is ISenzuCollateral, SenzuCore {
    /*  ================================================
                             STATE
        ================================================  */

    /// @dev Ids are 1, 2, 3, …: the last one opened
    uint256 internal _positionCount;

    /// @dev Who called `lock()`, zero outside a lock: only it liquidates and settles inside
    address internal transient _locker;

    /*  ================================================
                          CONSTRUCTOR
        ================================================  */

    constructor() SenzuCore("Senzu Collateral") {}

    /*  ================================================
                            ERC-6909
        ================================================  */

    /// @notice Always reverts: units don't transfer
    function transfer(address, uint256, uint256) public pure override(ERC6909, IERC6909) returns (bool) {
        revert SenzuCollateral__NonTransferable();
    }

    /// @notice Always reverts: units don't transfer
    function transferFrom(address, address, uint256, uint256) public pure override(ERC6909, IERC6909) returns (bool) {
        revert SenzuCollateral__NonTransferable();
    }

    /// @notice Always reverts: units have no allowances. Operators (`setOperator`) still act for an account
    function approve(address, uint256, uint256) public pure override(ERC6909, IERC6909) returns (bool) {
        revert SenzuCollateral__NonTransferable();
    }

    /*  ================================================
                           MODIFIERS
        ================================================  */

    modifier onlyAuthorized(address account) {
        _requireAuthorized(account);
        _;
    }

    modifier onlyLocker() {
        _requireLocker();
        _;
    }

    /*  ================================================
                            DEPOSITS
        ================================================  */

    /// @inheritdoc ISenzuCollateral
    function open(address to, address refundTo, bytes calldata data)
        external
        override
        nonReentrant
        whenNotPaused(ACTION_OPEN)
        returns (uint256 id, uint256 units, address token0, address token1, uint256 used0, uint256 used1)
    {
        id = ++_positionCount;
        (units, token0, token1, used0, used1) = ISenzuAdapter(adapter).deposit(id, to, refundTo, data);
        if (units == 0) revert SenzuCollateral__ZeroAmount();
        bytes32 pairKey = ISenzuRiskConfig(riskConfig).requireListed(adapter, token0, token1);

        _mint(to, id, units);

        emit Open(to, id, units, used0, used1, pairKey);
    }

    /// @inheritdoc ISenzuCollateral
    function increaseLiquidity(address account, uint256 id, address refundTo, bytes calldata data)
        external
        override
        nonReentrant
        onlyAuthorized(account)
        returns (uint256 unitsAdded, uint256 used0, uint256 used1)
    {
        // Holders only: units exist only for opened ids, and a non-holder's fee snapshot can be stale
        uint256 balance = balanceOf(account, id);
        if (balance == 0) revert SenzuCollateral__NotAHolder(account, id);

        (unitsAdded, used0, used1) = ISenzuAdapter(adapter).increaseLiquidity(id, account, balance, refundTo, data);
        if (unitsAdded == 0) return (0, 0, 0);

        _mint(account, id, unitsAdded);

        emit IncreaseLiquidity(account, id, unitsAdded, used0, used1);
    }

    /// @inheritdoc ISenzuCollateral
    function redeem(address account, uint256 id, uint256 units, address to, bytes calldata data)
        external
        override
        nonReentrant
        onlyAuthorized(account)
        returns (uint256 amount0, uint256 amount1)
    {
        if (units == 0) revert SenzuCollateral__ZeroAmount();

        uint256 balance = balanceOf(account, id);
        if (units > balance) revert SenzuCollateral__InsufficientUnits();

        _burn(account, id, units);

        (amount0, amount1) = ISenzuAdapter(adapter).decreaseLiquidity(id, units, account, balance, to, data);

        _requireHealthyOrDefer(account, id);

        emit Redeem(account, id, to, units, amount0, amount1);
    }

    /*  ================================================
                              DEBT
        ================================================  */

    /// @inheritdoc ISenzuCollateral
    function borrow(address account, uint256 id, address asset, uint256 assets, address to)
        external
        override
        nonReentrant
        onlyAuthorized(account)
        returns (uint256 shares)
    {
        if (id == 0) revert SenzuCollateral__PositionNotFound(0);
        if (id <= _positionCount) {
            // An opened position: its pair and both its tokens must still be listed
            (address token0, address token1) = ISenzuAdapter(adapter).tokens(id);
            ISenzuRiskConfig(riskConfig).requireListed(adapter, token0, token1);
        } else if (_locker == address(0)) {
            // Only inside a lock may it borrow for an id NOT opened yet
            revert SenzuCollateral__PositionNotFound(id);
        }
        shares = borrowable().borrow(account, id, asset, assets, to);

        _requireHealthyOrDefer(account, id);
    }

    /*  ================================================
                     LOCK AND LIQUIDATIONS
        ================================================  */

    /// @inheritdoc ISenzuCollateral
    function lock(bytes calldata data) external override returns (bytes memory result) {
        if (_locker != address(0)) revert SenzuCollateral__Locked();
        if (_entered) revert SenzuCore__Reentrant();
        _locker = msg.sender;

        result = ISenzuLockCallback(msg.sender).senzuLockAcquired(data);

        _runDeferredChecks();

        _locker = address(0);
    }

    /// @inheritdoc ISenzuCollateral
    function liquidate(address borrower, uint256 id, address asset, uint256 maxRepayAssets, address receiver)
        external
        override
        nonReentrant
        onlyLocker
        returns (uint256 seizedUnits, uint256 repaid, uint256 fee)
    {
        if (LockLogic.isDeferred(borrower, id)) revert SenzuCollateral__CheckPending(borrower, id);
        _requirePosition(id);

        uint256 repayAssets;
        (seizedUnits, repayAssets, fee) = LiquidationLogic.liquidate(
            _modules(), borrower, id, asset, maxRepayAssets, balanceOf(borrower, id), totalSupply(id)
        );

        // Unsettled until `settle` pays it: the seized units can fund it, and lock() ends only once it's paid
        repaid = borrowable().repayFor(borrower, id, asset, repayAssets, fee);
        LockLogic.addUnsettled(asset, repaid + fee);

        _seizeMove(borrower, id, receiver, seizedUnits);

        emit Liquidate(borrower, id, asset, receiver, seizedUnits, repaid, fee);

        // Taking the last unit leaves the rest of the debt with nothing behind it: written off now. A liquidation
        // that stops short leaves the loss waiting
        if (balanceOf(borrower, id) == 0 && borrowable().hasDebt(borrower, id)) {
            borrowable().writeOff(borrower, id);
        }
    }

    /// @inheritdoc ISenzuCollateral
    function settle(address asset, uint256 assets) external override nonReentrant onlyLocker {
        if (assets == 0) return;
        LockLogic.subUnsettled(asset, assets);
        borrowable().collectRepayment(msg.sender, asset, assets);
    }

    /// @inheritdoc ISenzuCollateral
    function resolveBadDebt(address borrower, uint256 id) external override nonReentrant {
        if (_locker != address(0)) revert SenzuCollateral__Locked();
        if (!borrowable().hasDebt(borrower, id)) revert SenzuCollateral__NoDebt();
        uint256 units = balanceOf(borrower, id);
        if (units != 0) {
            if (health(borrower, id).collateralUsdWad != 0) revert SenzuCollateral__CollateralRemaining();
            _seizeMove(borrower, id, ISenzuFactory(factory).protocolReserves(), units);
        }
        borrowable().writeOff(borrower, id);
    }

    /*  ================================================
                             VIEWS
        ================================================  */

    /// @inheritdoc ISenzuCollateral
    function borrowable() public view override returns (ISenzuBorrowable) {
        return ISenzuBorrowable(_counterpart);
    }

    /// @inheritdoc ISenzuCollateral
    function nextPositionId() external view override returns (uint256) {
        return _positionCount + 1;
    }

    /// @inheritdoc ISenzuCollateral
    function health(address account, uint256 id) public view override returns (HealthResult memory) {
        _requirePosition(id);
        return
            HealthLogic.evaluate(HealthLogic.position(_modules(), account, id, balanceOf(account, id), totalSupply(id)));
    }

    /*  ================================================
                            INTERNAL
        ================================================  */

    function _modules() internal view returns (HealthLogic.Modules memory) {
        return HealthLogic.Modules({
            oracle: oracle, riskConfig: riskConfig, borrowable: address(borrowable()), adapter: adapter
        });
    }

    function _requireAuthorized(address account) internal view {
        if (msg.sender != account && !isOperator(account, msg.sender)) revert SenzuCollateral__Unauthorized();
    }

    function _requireLocker() internal view {
        if (msg.sender != _locker) revert SenzuCollateral__NotLocker();
    }

    function _requirePosition(uint256 id) internal view {
        if (id == 0 || id > _positionCount) revert SenzuCollateral__PositionNotFound(id);
    }

    /// @dev No debt passes before the position check: a flash borrow repaid in its lock never opens one
    function _requireHealthy(address account, uint256 id) internal view {
        (address asset0, uint256 amount0, address asset1, uint256 amount1) = borrowable().debts(account, id);
        if (asset0 == address(0)) return;

        _requirePosition(id);
        HealthLogic.requireHealthy(
            _modules(), id, balanceOf(account, id), totalSupply(id), asset0, amount0, asset1, amount1
        );
    }

    /// @dev Inside a lock the check waits for the lock's end
    function _requireHealthyOrDefer(address account, uint256 id) internal {
        if (_locker != address(0)) LockLogic.defer(account, id);
        else _requireHealthy(account, id);
    }

    function _runDeferredChecks() internal {
        if (LockLogic.unsettledCount() != 0) revert SenzuCollateral__Unsettled();
        uint256 n = LockLogic.deferredCount();
        if (n == 0) return;
        for (uint256 i; i < n; ++i) {
            (address account, uint256 id) = LockLogic.takeDeferred(i);
            _requireHealthy(account, id);
        }
        LockLogic.clearDeferred();
    }

    /// @dev The adapter moves the seized units' fee bookmark first, reading only: a poke collects both pool tokens, so
    ///      a paused token or a call from inside the DEX's own lock would block the liquidation
    function _seizeMove(address from, uint256 id, address to, uint256 units) internal {
        ISenzuAdapter(adapter).seize(id, from, to, balanceOf(to, id), units);
        _transfer(from, to, id, units);
    }
}
