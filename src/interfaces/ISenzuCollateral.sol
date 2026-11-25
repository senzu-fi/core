// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {HealthResult} from "../libraries/Types.sol";
import {ISenzuBorrowable} from "./ISenzuBorrowable.sol";
import {ISenzuCore} from "./ISenzuCore.sol";

/**
 *  @title  ISenzuCollateral
 *  @author Senzu
 *  @notice Borrowers' side of one Senzu deployment: LP positions (ERC-6909, id = position, balance = units),
 *          health checks, liquidations and `lock()`. Borrows from its paired SenzuBorrowable. Units don't transfer:
 *          they're minted by open and add, burned by redeem and moved only by a liquidation's seize
 *          (`transfer`, `transferFrom` and `approve` revert; operators remain).
 */
interface ISenzuCollateral is ISenzuCore {
    /// @custom:error Unauthorized Reverts when `msg.sender` is neither `account` nor an operator of `account`
    error SenzuCollateral__Unauthorized();

    /// @custom:error ZeroAmount Reverts on a zero amount/units input, an `open` minting zero units, or a liquidation
    ///               with zero collateral value or zero repayment
    error SenzuCollateral__ZeroAmount();

    /**
     *  @custom:error PositionNotFound Reverts when `id` is 0 or has not been opened yet (outside a lock, or still
     *                unopened with remaining debt when a lock ends)
     *  @param id The unknown position id
     */
    error SenzuCollateral__PositionNotFound(uint256 id);

    /// @custom:error InsufficientCollateral Reverts when a health check after `borrow` or `redeem`, or at the end of
    ///               `lock()`, fails
    error SenzuCollateral__InsufficientCollateral();

    /// @custom:error NotLiquidatable Reverts when `liquidate` is called on a healthy position
    error SenzuCollateral__NotLiquidatable();

    /// @custom:error CollateralRemaining Reverts when `resolveBadDebt` is called while the borrower's units still have
    ///               non-zero USD value at oracle prices
    error SenzuCollateral__CollateralRemaining();

    /// @custom:error NoDebt Reverts when `resolveBadDebt` is called on a debt-free position, or `liquidate` targets an
    ///               asset the borrower does not owe on that position
    error SenzuCollateral__NoDebt();

    /// @custom:error Locked Reverts when `lock` or `resolveBadDebt` is called while a lock is active
    error SenzuCollateral__Locked();

    /**
     *  @custom:error NotAHolder Reverts when `increaseLiquidity` is called for an account holding zero units of `id`
     *  @param account The account with no units
     *  @param id The position id
     */
    error SenzuCollateral__NotAHolder(address account, uint256 id);

    /// @custom:error InsufficientUnits Reverts when `redeem` requests more units than `account` holds
    error SenzuCollateral__InsufficientUnits();

    /// @custom:error NotLocker Reverts when `liquidate` or `settle` is called by anyone other than the active locker
    error SenzuCollateral__NotLocker();

    /// @custom:error Unsettled Reverts when `lock()` ends with unsettled liquidation repayments remaining
    error SenzuCollateral__Unsettled();

    /// @custom:error MoreThanUnsettled Reverts when `settle` attempts to pay more than is unsettled in `asset`
    error SenzuCollateral__MoreThanUnsettled();

    /**
     *  @custom:error CheckPending Reverts when `liquidate` targets a position queued for a deferred end-of-lock health
     *                check
     *  @param account The position holder
     *  @param id The position id
     */
    error SenzuCollateral__CheckPending(address account, uint256 id);

    /**
     *  @custom:error IlliquidDebtOutsideItsPair Reverts when a health check sees a debt outside the position's pair
     *                whose token is not marked `liquid`
     *  @param asset The illiquid debt asset
     */
    error SenzuCollateral__IlliquidDebtOutsideItsPair(address asset);

    /// @custom:error NonTransferable Reverts on `transfer`, `transferFrom`, and `approve`
    error SenzuCollateral__NonTransferable();

    /**
     *  @notice Emitted when a new DEX collateral position is opened
     *  @param account Recipient of the minted position units
     *  @param id The newly assigned position id
     *  @param units Position units minted to `account`
     *  @param used0 Token0 the mint used (the rest went to `refundTo`)
     *  @param used1 Token1 the mint used
     *  @param pairKey Risk config key for the position's token pair
     */
    event Open(
        address indexed account, uint256 indexed id, uint256 units, uint256 used0, uint256 used1, bytes32 pairKey
    );

    /**
     *  @notice Emitted when liquidity is added to an existing position
     *  @param account Holder receiving the newly minted units
     *  @param id The position id
     *  @param unitsAdded Units minted to `account`
     *  @param used0 Token0 the add used (the rest went to `refundTo`)
     *  @param used1 Token1 the add used
     */
    event IncreaseLiquidity(
        address indexed account, uint256 indexed id, uint256 unitsAdded, uint256 used0, uint256 used1
    );

    /**
     *  @notice Emitted when collateral units are burned for underlying liquidity
     *  @param account Holder whose units were burned
     *  @param id The position id
     *  @param to Recipient of the underlying tokens
     *  @param units Units burned from `account`
     *  @param amount0 Underlying token0 sent to `to` (excluding fees)
     *  @param amount1 Underlying token1 sent to `to` (excluding fees)
     */
    event Redeem(
        address indexed account, uint256 indexed id, address indexed to, uint256 units, uint256 amount0, uint256 amount1
    );

    /**
     *  @notice Emitted when a liquidatable position's debt is repaid and units are seized
     *  @param borrower Account whose position was liquidated
     *  @param id The position id
     *  @param asset Debt asset repaid
     *  @param receiver Recipient of the seized units: the liquidator (a router seizes to its user)
     *  @param seizedUnits Position units moved from `borrower` to `receiver`
     *  @param repaid Debt amount repaid
     *  @param fee Protocol liquidation fee in `asset` (`repaid + fee` is added to the lock's unsettled balance)
     */
    event Liquidate(
        address indexed borrower,
        uint256 indexed id,
        address indexed asset,
        address receiver,
        uint256 seizedUnits,
        uint256 repaid,
        uint256 fee
    );

    /// @notice The paired SenzuBorrowable this collateral borrows from
    /// @return The paired borrowable contract
    function borrowable() external view returns (ISenzuBorrowable);

    /**
     *  @notice The id the next `open` creates
     *  @dev Ids `1` through `nextPositionId() - 1` exist, all held by `adapter()` under the same id. Inside a lock an
     *       account can borrow against it before opening it; the end-of-lock check fails unless it was opened with the
     *       borrower's units (or all debt was repaid)
     *  @return The next sequential position id
     */
    function nextPositionId() external view returns (uint256);

    /**
     *  @notice Full health check of a position at current oracle prices
     *  @dev The position can be liquidated when a stress corner is short: `minSurplusUsdWad < 0`
     *  @param account The position holder
     *  @param id The position id
     *  @return Health metrics across current prices and the four stress corners
     */
    function health(address account, uint256 id) external view returns (HealthResult memory);

    /**
     *  @notice Mints the DEX position `data` encodes with the tokens already sent to `adapter()`, and mints its units
     *          as a new id (`nextPositionId()`) to `to`
     *  @dev What the mint doesn't use goes to `refundTo`. Enforces no minimum amounts. Reverts while `ACTION_OPEN` is
     *       paused or if the pair is not listed in `riskConfig`
     *  @param to Recipient of the newly minted position units
     *  @param refundTo Recipient of any unused tokens sent to the adapter
     *  @param data Adapter-specific `MintData` encoding the DEX position to open
     *  @return id The newly assigned position id
     *  @return units Position units minted to `to`
     *  @return token0 Pool token0 of the opened position
     *  @return token1 Pool token1 of the opened position
     *  @return used0 Amount of `token0` consumed by the mint
     *  @return used1 Amount of `token1` consumed by the mint
     */
    function open(address to, address refundTo, bytes calldata data)
        external
        returns (uint256 id, uint256 units, address token0, address token1, uint256 used0, uint256 used1);

    /**
     *  @notice Adds the tokens already sent to the adapter as liquidity and mints the units to `account`
     *  @dev Callable by `account` or its operator, for existing holders only (`balanceOf(account, id) > 0`). What
     *       doesn't fit the position goes to `refundTo`. Enforces no minimum amounts. Returns zero, with no event,
     *       when nothing would be added
     *  @param account Position holder receiving the added units
     *  @param id The position id
     *  @param refundTo Recipient of any unused tokens
     *  @param data Passed to the adapter unread (`ISenzuAdapter.increaseLiquidity`): empty for every adapter today
     *  @return unitsAdded Units minted to `account`
     *  @return used0 Amount of token0 consumed
     *  @return used1 Amount of token1 consumed
     */
    function increaseLiquidity(address account, uint256 id, address refundTo, bytes calldata data)
        external
        returns (uint256 unitsAdded, uint256 used0, uint256 used1);

    /**
     *  @notice Burns `units` of `account` and sends the underlying tokens to `to`
     *  @dev Callable by `account` or its operator. When the position owes debt, health is checked after the
     *       withdrawal outside a lock or deferred until the lock ends. Redeeming all of `account`'s units also pays
     *       `account` itself (never `to`) every accrued fee and reward owed in the position; a partial redeem pays
     *       none. Enforces no minimum amounts
     *  @param account Holder whose units are burned
     *  @param id The position id
     *  @param units Number of units to burn
     *  @param to Recipient of the withdrawn underlying tokens
     *  @param data Passed to the adapter unread (`ISenzuAdapter.decreaseLiquidity`). Empty data always redeems, and no
     *         data changes what the units pay
     *  @return amount0 The liquidity's token0 sent to `to`, without fees
     *  @return amount1 The liquidity's token1 sent to `to`, without fees
     */
    function redeem(address account, uint256 id, uint256 units, address to, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1);

    /**
     *  @notice Borrows `assets` of `asset` against position `(account, id)` from the paired borrowable and sends them
     *          to `to`
     *  @dev Callable by `account` or its operator. Outside a lock, `id` must exist, its pair must be listed, and
     *       health is checked immediately. Inside a lock, `id` may be unopened (`id >= nextPositionId()`) and the
     *       health check is deferred until the lock ends
     *  @param account Position holder taking on the debt
     *  @param id The position id
     *  @param asset Token to borrow
     *  @param assets Amount of `asset` to borrow and send to `to`
     *  @param to Recipient of the borrowed tokens
     *  @return shares Borrow shares minted in the borrowable (including any opening fee)
     */
    function borrow(address account, uint256 id, address asset, uint256 assets, address to)
        external
        returns (uint256 shares);

    /**
     *  @notice Repays up to `maxRepayAssets` of `(borrower, id)`'s `asset` debt and moves the seized units to
     *          `receiver`
     *  @dev Lock holder only, inside its `lock()`. The repayment stays unsettled until `settle` pays it, so the seized
     *       units can fund it (redeem, swap, settle). Passing `type(uint256).max` repays the whole debt; the penalty
     *       shrinks to what the position bears. Taking the borrower's last unit writes off every remaining debt
     *       (`BadDebt` from the borrowable) in this call
     *  @param borrower Account whose unhealthy position is being liquidated
     *  @param id The position id
     *  @param asset Debt asset being repaid
     *  @param maxRepayAssets Maximum amount of `asset` to repay (`type(uint256).max` for all)
     *  @param receiver Recipient of the seized position units
     *  @return seizedUnits Units moved to `receiver`
     *  @return repaid Debt amount actually repaid
     *  @return fee Protocol liquidation fee in `asset` (`repaid + fee` is added to the lock's unsettled balance;
     *          `settle` the total)
     */
    function liquidate(address borrower, uint256 id, address asset, uint256 maxRepayAssets, address receiver)
        external
        returns (uint256 seizedUnits, uint256 repaid, uint256 fee);

    /**
     *  @notice Pays `assets` of the lock's unsettled liquidation repayment in `asset`
     *  @dev Lock holder only. Tokens are pulled from `msg.sender` by the paired borrowable (approve the borrowable).
     *       Cannot exceed the unsettled balance; `lock()` reverts unless every unsettled repayment reaches zero
     *  @param asset Debt asset being settled
     *  @param assets Amount of `asset` to pay (no-op if zero)
     */
    function settle(address asset, uint256 assets) external;

    /**
     *  @notice Writes off the remaining debts of a position whose collateral is worth zero at oracle prices
     *  @dev Callable by anyone, outside a lock only. Any remaining zero-value units are seized to
     *       `factory.protocolReserves()`. A liquidation that takes the borrower's last unit writes off automatically
     *  @param borrower Account with bad debt
     *  @param id The position id
     */
    function resolveBadDebt(address borrower, uint256 id) external;

    /**
     *  @notice Opens a lock and invokes `ISenzuLockCallback(msg.sender).senzuLockAcquired(data)`
     *  @dev Only `msg.sender` (the lock holder) may call `liquidate` and `settle` inside the lock. When the callback
     *       returns, every unsettled liquidation repayment must be zero, then every position deferred inside the lock
     *       is health checked
     *  @param data Arbitrary bytes forwarded to `senzuLockAcquired`
     *  @return result Bytes returned by `senzuLockAcquired`
     */
    function lock(bytes calldata data) external returns (bytes memory result);
}
