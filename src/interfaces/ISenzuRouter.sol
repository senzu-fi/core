// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISenzuBorrowable} from "./ISenzuBorrowable.sol";
import {ISenzuCollateral} from "./ISenzuCollateral.sol";
import {ISenzuLockCallback} from "./ISenzuLockCallback.sol";
import {IPyth} from "./external/pyth/IPyth.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

/**
 *  @title  ISenzuRouter
 *  @author Senzu
 *  @notice The router every user action goes through, one per deployment (SenzuBaseRouter, with each DEX's swaps in
 *          SenzuUniswapV3Router, SenzuUniswapV4Router, SenzuAeroRouter). `execute(actions, params, deadline,
 *          nativeOut)` runs a list of actions for msg.sender in order inside one `collateral.lock()`: `actions` holds
 *          one byte per `Action`, `params[i]` the ABI-encoded arguments of action i. Every touched token is swept back
 *          to msg.sender at the end (WETH as native ETH with `nativeOut`). It holds nothing between calls.
 *
 *          Tokens are pulled with an ERC-20 approval to the router or, failing that, through Permit2: a wallet that
 *          approved Permit2 once per token grants the router an allowance by signature (PERMIT, in the same call).
 *          For actions on their positions (borrow, increase, redeem, fees, rewards, stake), users make it their
 *          ERC-6909 operator on SenzuCollateral (`setOperator`, `setOperatorBySig`, or AUTHORIZE first in the same
 *          call). WITHDRAW also needs it as an operator on
 *          SenzuBorrowable (AUTHORIZE with `lending`). SUPPLY, REPAY and LIQUIDATE need no operator approval.
 *
 *          An amount of `ALL` means everything available: the router's balance for tokens, the user's balance for
 *          units and lender shares. A position id of 0 means the position this call opened, or before an OPEN the one
 *          it will open (`nextPositionId`).
 *
 *          Swaps run on the deployment's DEX along a `route` in that DEX's encoding, or through an aggregator when
 *          the route is one of `aggregators()` followed by that aggregator's quote calldata (taker: the router), with a
 *          minimum output above zero; never for SwapForDebt.
 *          Slippage is checked here, never in the core: every swap's minimum output and the minimums on liquidity
 *          going in and coming out.
 */
interface ISenzuRouter is ISenzuLockCallback {
    /**
     *  @notice The actions, with the ABI-encoded params each expects
     *  @custom:member Pull        (address token, uint256 amount): from the user (ERC-20 approval, else Permit2)
     *  @custom:member Open        (bytes adapterData, address[] tokens, uint256[] minimums): mints a DEX position
     *                             through the deployment's adapter, which gets any of `tokens` the router holds; at
     *                             least `minimums[i]` of `tokens[i]` must go in, the rest comes back
     *  @custom:member Increase    (uint256 id, uint256 amount0, uint256 amount1, uint256 min0, uint256 min1,
     *                             bytes adapterData): adds token0/token1 as liquidity; at least min0/min1 must go in,
     *                             the rest comes back. `adapterData` goes to the adapter unread (empty for every DEX
     *                             so far)
     *  @custom:member Borrow      (uint256 id, address asset, uint256 amount): borrows to the router
     *  @custom:member Swap        (address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin,
     *                             bytes route): swaps amountIn along `route` on the deployment's DEX, or through an
     *                             aggregator when `route` is its address followed by its quote's calldata (taker: the
     *                             router), to the router; at least amountOutMin must come back
     *  @custom:member Repay       (uint256 id, address asset, uint256 amount): repays the user's debt. ALL repays
     *                             as much as the router holds, up to the whole debt, and skips if either is zero
     *  @custom:member Redeem      (uint256 id, uint256 units, uint256 min0, uint256 min1, bytes adapterData):
     *                             removes liquidity to the router; at least min0/min1 must come out. `adapterData`
     *                             goes to the adapter unread (empty always works)
     *  @custom:member CollectFees (uint256 id): the user's LP fees, to the router
     *  @custom:member Compound    (uint256 id, uint256 min0, uint256 min1, bytes adapterData): the user's LP fees
     *                             back into liquidity, at least min0/min1; `adapterData` as Increase's
     *  @custom:member Supply      (address asset, uint256 amount): lends for the user
     *  @custom:member Withdraw    (address asset, uint256 shares): the user's lender shares, to the router
     *  @custom:member Liquidate   (address borrower, uint256 id, address asset, uint256 repayAssets): seizes to the
     *                             user now; the router settles the repayment after the last action, so later
     *                             actions can pay for it. ALL repays the whole debt
     *  @custom:member SwapForDebt (uint256 id, address asset, address tokenIn, uint256 maxIn, bytes route): buys
     *                             exactly what the router is missing to repay the user's whole `asset` debt on
     *                             `id`, read at this point of the call, along `route` (tokenIn first; never an aggregator),
     *                             spending at most `maxIn`. Skips when the router already holds enough
     *  @custom:member OpenExact   (bytes adapterData, uint256 fromUser0, uint256 fromUser1, uint256 maxBorrow0,
     *                             uint256 maxBorrow1): opens `adapterData`'s exact liquidity, paying exactly what it
     *                             takes at the pool price now: from the router's balance first, then the user's
     *                             wallet up to fromUser (ALL: its balance), then a borrow against the new position
     *                             up to maxBorrow. Where the DEX mints by amounts only (Aero) the liquidity is a
     *                             target: the quoted amounts go in and mint what they make
     *  @custom:member Authorize   (bool lending, uint256 deadline, uint8 v, bytes32 r, bytes32 s): makes the router
     *                             the user's operator on the borrowable (`lending`) or the collateral with the
     *                             user's `setOperatorBySig` signature, spending it. A signature that no longer
     *                             works (submitted by someone else first) is skipped while the router is an operator
     *  @custom:member PostPrices  (bytes[] updates): posts signed Pyth updates (Hermes) to Pyth Core, first in a call
     *                             that prices a token listed through a PythFeed. Pyth's fee, if any, is paid from
     *                             the router's WETH
     *  @custom:member Permit      (IAllowanceTransfer.PermitBatch batch, bytes signature): the user's Permit2 allowances to this
     *                             router, by its signature. One someone else submitted first is skipped
     *  @custom:member ClaimRewards (uint256 id): the user's rewards from a position, paid to the user (DEXes with
     *                             rewards only: Aero, Fables)
     *  @custom:member SetStake    (uint256 id, bool on): stakes or unstakes the user's position, paying the user what
     *                             it is owed (Aero, Fables)
     *
     *  Codes 0..127 are shared across routers (`Action`); codes 128..255 are DEX-local, defined on each DEX's router
     *  alone (`_runDex`) so DEX-specific mechanics never touch this interface.
     */
    enum Action {
        Pull, // 0x00 (0)
        Open, // 0x01 (1)
        Increase, // 0x02 (2)
        Borrow, // 0x03 (3)
        Swap, // 0x04 (4)
        Repay, // 0x05 (5)
        Redeem, // 0x06 (6)
        CollectFees, // 0x07 (7)
        Compound, // 0x08 (8)
        Supply, // 0x09 (9)
        Withdraw, // 0x0a (10)
        Liquidate, // 0x0b (11)
        SwapForDebt, // 0x0c (12)
        OpenExact, // 0x0d (13)
        Authorize, // 0x0e (14)
        PostPrices, // 0x0f (15)
        Permit, // 0x10 (16)
        ClaimRewards, // 0x11 (17)
        SetStake, // 0x12 (18)
        IncreaseFromUser // 0x13 (19)
    }

    /**
     *  @notice A swap on its own, for an account's history: from `swap`, or from an `execute` whose actions are only
     *          Pull, Permit, PostPrices and Swap (the Swap tab's). A swap inside any other `execute` (a leverage, a
     *          close) is part of the action that made it and emits nothing
     *  @param account Who swapped: msg.sender (a wallet, a smart account or the automator)
     *  @param tokenIn The token sold; address(0) for ETH that `execute` wrapped
     *  @param tokenOut The token bought; address(0) for WETH that `execute` unwrapped (`nativeOut`)
     *  @param amountIn What was sold, less what an aggregator left unspent
     *  @param amountOut What the swap paid
     */
    event Swap(
        address indexed account, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );

    /// @custom:error Expired Reverts when `execute` runs after its deadline
    error SenzuRouter__Expired();

    /// @custom:error LengthMismatch Reverts when `actions` and `params`, or an open's tokens and minimums, differ in
    ///               length
    error SenzuRouter__LengthMismatch();

    /// @custom:error NotCollateral Reverts when the lock callback comes from anything but the deployment's collateral,
    ///               or when this router's own `execute` isn't running (it acts only for that call's caller)
    error SenzuRouter__NotCollateral();

    /// @custom:error Reentrant Reverts when `execute` or `swap` is called again from inside one of them
    error SenzuRouter__Reentrant();

    /**
     *  @custom:error UnsupportedAction Reverts on an action the router's DEX doesn't have
     *  @param action The action
     */
    error SenzuRouter__UnsupportedAction(uint8 action);

    /// @custom:error NoPosition Reverts when an action names a position id the collateral hasn't opened
    error SenzuRouter__NoPosition();

    /// @custom:error TooManyTokens Reverts when one call touches more than 16 tokens
    error SenzuRouter__TooManyTokens();

    /// @custom:error UnexpectedEth Reverts when native ETH comes from anything but WETH or the DEX's own senders
    error SenzuRouter__UnexpectedEth();

    /**
     *  @custom:error InsufficientOutput Reverts when a swap or redeem pays less than its minimum
     *  @param token The token paid out
     *  @param received What came out
     *  @param minimum What had to come out at least
     */
    error SenzuRouter__InsufficientOutput(address token, uint256 received, uint256 minimum);

    /**
     *  @custom:error DepositBelowMinimum Reverts when an open, increase or compound puts in less than its minimum
     *  @param token The token deposited
     *  @param deposited What went in
     *  @param minimum What had to go in at least
     */
    error SenzuRouter__DepositBelowMinimum(address token, uint256 deposited, uint256 minimum);

    /**
     *  @custom:error ExcessiveInput Reverts when a swap for debt spends, or an exact open borrows, more than its maximum
     *  @param token The token spent or borrowed
     *  @param spent What it would take
     *  @param maximum What it may take at most
     */
    error SenzuRouter__ExcessiveInput(address token, uint256 spent, uint256 maximum);

    /// @custom:error InvalidRoute Reverts when a route isn't from tokenIn to tokenOut on the router's DEX
    error SenzuRouter__InvalidRoute();

    /// @custom:error InvalidAggregatorRoute Reverts when an aggregator route has no minimum output or buys an exact
    ///               amount (swap for debt)
    error SenzuRouter__InvalidAggregatorRoute();

    /// @custom:error NotPool Reverts when a swap callback comes from anything but the pool being swapped in
    error SenzuRouter__NotPool();

    /// @custom:error PartialFill Reverts when a hop fills only part of its amount (a price limit reached)
    error SenzuRouter__PartialFill();

    /// @notice "Everything available" for amounts, units and shares
    /// @return The sentinel, `type(uint256).max`
    function ALL() external view returns (uint256);

    /// @notice The aggregators a swap route may start with, fixed in code: 0x's AllowanceHolder, KyberSwap, 1inch (its
    ///         mainnet and its Robinhood router), Velora and OpenOcean, each both the contract called and the spender
    /// @return list Their addresses
    function aggregators() external pure returns (address[] memory list);

    /// @notice Whether a route starting with `target` swaps through it
    /// @param target An address
    /// @return Whether it is one of `aggregators()`
    function isAggregator(address target) external pure returns (bool);

    /// @notice The deployment's SenzuCollateral, whose `lock()` every `execute` runs in
    /// @return The collateral
    function collateral() external view returns (ISenzuCollateral);

    /// @notice The deployment's SenzuBorrowable, where SUPPLY, WITHDRAW and REPAY go
    /// @return The borrowable
    function borrowable() external view returns (ISenzuBorrowable);

    /// @notice Wrapped native token: native ETH sent to `execute` is wrapped, and swept back unwrapped with `nativeOut`
    /// @return WETH
    function weth() external view returns (IWETH9);

    /// @notice The deployment's adapter, which OPEN, OPEN_EXACT and INCREASE send tokens to
    /// @return The adapter
    function adapter() external view returns (address);

    /// @notice Pyth Core, where PostPrices posts (zero on a chain without it)
    /// @return Pyth Core
    function pyth() external view returns (IPyth);

    /**
     *  @notice Runs `actions` for msg.sender inside one lock, then sweeps every touched token back to msg.sender
     *  @dev Health is checked once, when the lock ends; liquidations are settled after the last action. Native ETH
     *       sent with the call is wrapped first. Not reentrant
     *  @param actions One byte per action (see `Action`)
     *  @param params ABI-encoded params of each action, in the order of `actions`
     *  @param deadline Latest block timestamp the call may execute at
     *  @param nativeOut Send swept WETH as native ETH
     *  @return lastId The position opened by the call, if any (0 otherwise)
     */
    function execute(bytes calldata actions, bytes[] calldata params, uint256 deadline, bool nativeOut)
        external
        payable
        returns (uint256 lastId);

    /**
     *  @notice One swap outside any lock: pulls `amountIn` of tokenIn from msg.sender (an ERC-20 approval, else
     *          Permit2) and sends the output to msg.sender
     *  @dev Through an aggregator only with a minimum above zero: the automator calls this on a keeper's route with
     *       none, so its swaps stay on the deployment's DEX. Emits `Swap`. Not reentrant
     *  @param tokenIn The token sold, pulled from msg.sender
     *  @param tokenOut The token bought, sent to msg.sender
     *  @param amountIn Exactly what is sold
     *  @param amountOutMin What must come out at least
     *  @param route The path in the DEX's encoding, tokenIn first, or an aggregator route
     *  @return amountOut What msg.sender received, at least `amountOutMin`
     */
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, bytes calldata route)
        external
        returns (uint256 amountOut);
}
