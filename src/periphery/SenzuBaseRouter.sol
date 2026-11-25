// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISenzuAdapter} from "../interfaces/ISenzuAdapter.sol";
import {ISenzuBorrowable} from "../interfaces/ISenzuBorrowable.sol";
import {ISenzuCollateral} from "../interfaces/ISenzuCollateral.sol";
import {ISenzuERC6909} from "../interfaces/ISenzuERC6909.sol";
import {ISenzuLockCallback} from "../interfaces/ISenzuLockCallback.sol";
import {ISenzuRouter} from "../interfaces/ISenzuRouter.sol";
import {IPyth} from "../interfaces/external/pyth/IPyth.sol";
import {lenderId} from "../libraries/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/**
 *  @title  SenzuBaseRouter
 *  @author Senzu
 *  @notice Every action of `ISenzuRouter`; each DEX's router adds that DEX's swaps (`_swapExactIn`,
 *          `_swapExactOut`, and the pool callbacks)
 */
abstract contract SenzuBaseRouter is ISenzuRouter {
    using SafeTransferLib for address;

    /**
     *  @custom:member user Who the call acts for: `execute`'s caller. Every action acts for it and every token comes
     *                 back to it
     *  @custom:member lastId The position the last Open made; a later action's id 0 means it (`_positionId`)
     *  @custom:member tokens Every token the call touched, swept back to the user at the end
     *  @custom:member unsettled Per entry of `tokens`, what the call's liquidations repaid and the collateral is
     *                 still owed: paid after the last action
     *  @custom:member wrapped Whether the call wrapped ETH sent with it
     *  @custom:member swapOnly Whether every action only moves tokens or swaps (Pull, Permit, PostPrices, Swap): its
     *                 swaps are the user's own and emit `Swap`
     */
    struct Context {
        address user;
        uint256 lastId;
        address[] tokens;
        uint256 tokenCount;
        uint256[] unsettled;
        bool nativeOut;
        bool wrapped;
        bool swapOnly;
        bool hasUnsettled;
        bool lastAction;
    }

    /// @inheritdoc ISenzuRouter
    uint256 public constant ALL = type(uint256).max;

    // The aggregators a route may go through, the same address on every chain (checked on mainnet and Robinhood)
    // but 1inch's, which has one per chain: both are listed, each unused on the other chain
    address internal constant ZERO_EX = 0x0000000000001fF3684f28c67538d4D072C22734;
    address internal constant KYBERSWAP = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address internal constant ONE_INCH = 0x111111125421cA6dc452d289314280a0f8842A65;
    address internal constant ONE_INCH_ROBINHOOD = 0x5A705DE8982235a7fa45bB83dCaCf03a211389C7;
    address internal constant VELORA = 0x6A000F20005980200259B80c5102003040001068;
    address internal constant OPENOCEAN = 0x6352a56caadC4F1E25CD6c75970Fa768A3304e64;

    uint256 internal constant MAX_TOKENS = 16;

    /// @inheritdoc ISenzuRouter
    ISenzuCollateral public immutable collateral;

    /// @inheritdoc ISenzuRouter
    ISenzuBorrowable public immutable borrowable;

    /// @inheritdoc ISenzuRouter
    IWETH9 public immutable weth;

    /// @inheritdoc ISenzuRouter
    address public immutable adapter;

    /// @inheritdoc ISenzuRouter
    IPyth public immutable pyth;

    /// @dev Who the running `execute` or `swap` acts for: the lock callback acts for it alone, never
    ///      for an account read from data, and only while this router's own call holds the lock
    address transient _user;

    constructor(address collateral_, address weth_, address pyth_) {
        collateral = ISenzuCollateral(collateral_);
        borrowable = ISenzuCollateral(collateral_).borrowable();
        adapter = ISenzuCollateral(collateral_).adapter();
        weth = IWETH9(weth_);
        pyth = IPyth(pyth_);
    }

    /// @dev One call at a time, acting for `user` while it runs
    modifier actingFor(address user) {
        if (_user != address(0)) revert SenzuRouter__Reentrant();
        _user = user;
        _;
        _user = address(0);
    }

    /// @notice Accepts native ETH only from WETH (unwrapping) and the DEX's own senders (`_acceptsEth`)
    receive() external payable {
        if (!_acceptsEth(msg.sender)) revert SenzuRouter__UnexpectedEth();
    }

    /**
     *  @dev Each DEX's router: sells exactly `amountIn` of tokenIn along `route` on its DEX, to this router. The
     *       caller measures the output and checks the minimum; an aggregator route never reaches this
     *  @param tokenIn The token sold, from this router's balance
     *  @param tokenOut The token bought
     *  @param amountIn Exactly what is sold
     *  @param route The path in the DEX's encoding, tokenIn first; reverts `SenzuRouter__InvalidRoute` otherwise
     */
    function _swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, bytes memory route) internal virtual;

    /**
     *  @dev Each DEX's router: buys exactly `amountOut` of tokenOut along `route` on its DEX, to this router. The
     *       caller measures what it spent and checks the maximum
     *  @param tokenIn The token sold, from this router's balance
     *  @param tokenOut The token bought
     *  @param amountOut Exactly what is bought
     *  @param route The path in the DEX's encoding, tokenIn first; reverts `SenzuRouter__InvalidRoute` otherwise
     */
    function _swapExactOut(address tokenIn, address tokenOut, uint256 amountOut, bytes memory route) internal virtual;

    /**
     *  @dev Who may send this router native ETH; each DEX's router adds its own (v4's PoolManager for native pools)
     *  @param from The sender
     *  @return Whether it may
     */
    function _acceptsEth(address from) internal view virtual returns (bool) {
        return from == address(weth);
    }

    /// @inheritdoc ISenzuRouter
    // slither-disable-next-line reentrancy-eth
    function execute(bytes calldata actions, bytes[] calldata params, uint256 deadline, bool nativeOut)
        external
        payable
        actingFor(msg.sender)
        returns (uint256 lastId)
    {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert SenzuRouter__Expired();
        if (actions.length != params.length) revert SenzuRouter__LengthMismatch();

        bool wrapped = msg.value > 0;
        if (wrapped) weth.deposit{value: msg.value}();

        address[] memory tokens;
        (lastId, tokens) =
            abi.decode(collateral.lock(abi.encode(actions, params, wrapped, nativeOut)), (uint256, address[]));

        for (uint256 i; i < tokens.length; ++i) {
            _sweep(tokens[i], nativeOut, msg.sender);
        }
    }

    /// @inheritdoc ISenzuRouter
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, bytes calldata route)
        external
        actingFor(msg.sender)
        returns (uint256 amountOut)
    {
        uint256 heldIn = tokenIn.balanceOf(address(this));
        tokenIn.safeTransferFrom2(msg.sender, address(this), amountIn);
        amountOut = _checkedSwap(tokenIn, tokenOut, amountIn, amountOutMin, route);
        tokenOut.safeTransfer(msg.sender, amountOut);
        // What an aggregator didn't spend goes back too
        uint256 unspent = tokenIn.balanceOf(address(this)) - heldIn;
        if (unspent > 0) tokenIn.safeTransfer(msg.sender, unspent);
        emit Swap(msg.sender, tokenIn, tokenOut, amountIn - unspent, amountOut);
    }

    /// @inheritdoc ISenzuLockCallback
    function senzuLockAcquired(bytes calldata data) external override returns (bytes memory) {
        address user = _user;
        if (msg.sender != address(collateral) || user == address(0)) revert SenzuRouter__NotCollateral();
        // `data` is `execute`'s abi.encode(actions, params, wrapped, nativeOut). abi.decode would copy every param
        // to memory: this reads the fields in place (two offsets to a length and its contents, then the two bools)
        bool wrapped;
        bool nativeOut;
        bytes calldata actions;
        bytes[] calldata params;
        assembly ("memory-safe") {
            wrapped := calldataload(add(data.offset, 64))
            nativeOut := calldataload(add(data.offset, 96))
            let a := add(data.offset, calldataload(data.offset))
            actions.length := calldataload(a)
            actions.offset := add(a, 32)
            let p := add(data.offset, calldataload(add(data.offset, 32)))
            params.length := calldataload(p)
            params.offset := add(p, 32)
        }

        Context memory ctx = Context({
            user: user,
            lastId: 0,
            tokens: new address[](MAX_TOKENS),
            tokenCount: 0,
            unsettled: new uint256[](MAX_TOKENS),
            nativeOut: nativeOut,
            wrapped: wrapped,
            swapOnly: _swapOnly(actions),
            hasUnsettled: false,
            lastAction: false
        });
        if (wrapped) _track(ctx, address(weth));

        uint256 n = actions.length;
        for (uint256 i; i < n; ++i) {
            ctx.lastAction = i + 1 == n;
            _run(ctx, uint8(actions[i]), params[i]);
        }

        address[] memory tokens = ctx.tokens;
        uint256 count = ctx.tokenCount;
        for (uint256 i; i < count; ++i) {
            if (ctx.unsettled[i] != 0) collateral.settle(tokens[i], ctx.unsettled[i]);
        }
        // `execute` sweeps the touched tokens: trim the array to them
        assembly ("memory-safe") {
            mstore(tokens, count)
        }
        return abi.encode(ctx.lastId, tokens);
    }

    function _swapOnly(bytes calldata actions) private pure returns (bool) {
        for (uint256 i; i < actions.length; ++i) {
            uint8 action = uint8(actions[i]);
            if (
                action != uint8(Action.Pull) && action != uint8(Action.Permit) && action != uint8(Action.PostPrices)
                    && action != uint8(Action.Swap)
            ) {
                return false;
            }
        }
        return true;
    }

    /// @dev Runs one action. Dispatches on the raw byte so DEX routers can define codes `128..255` in `_runDex`
    ///      without extending `ISenzuRouter.Action`
    function _run(Context memory ctx, uint8 action, bytes calldata p) private {
        if (action == uint8(Action.Pull)) _pull(ctx, p);
        else if (action == uint8(Action.Open)) _open(ctx, p);
        else if (action == uint8(Action.Increase)) _increase(ctx, p);
        else if (action == uint8(Action.Borrow)) _borrow(ctx, p);
        else if (action == uint8(Action.Swap)) _swap(ctx, p);
        else if (action == uint8(Action.Repay)) _repay(ctx, p);
        else if (action == uint8(Action.Redeem)) _redeem(ctx, p);
        else if (action == uint8(Action.CollectFees)) _collectFees(ctx, p);
        else if (action == uint8(Action.Compound)) _compound(ctx, p);
        else if (action == uint8(Action.Supply)) _supply(ctx, p);
        else if (action == uint8(Action.Withdraw)) _withdraw(ctx, p);
        else if (action == uint8(Action.Liquidate)) _liquidate(ctx, p);
        else if (action == uint8(Action.SwapForDebt)) _swapForDebt(ctx, p);
        else if (action == uint8(Action.OpenExact)) _openExact(ctx, p);
        else if (action == uint8(Action.Authorize)) _authorize(ctx, p);
        else if (action == uint8(Action.PostPrices)) _postPrices(p);
        else if (action == uint8(Action.Permit)) _permit(ctx, p);
        else if (action == uint8(Action.IncreaseFromUser)) _increaseFromUser(ctx, p);
        else _runDex(ctx, action, p);
    }

    /**
     *  @dev Shared optional actions (`ClaimRewards`, `SetStake`) and DEX-local actions (`128..255`): each DEX's router
     *       runs its own, the rest revert `SenzuRouter__UnsupportedAction`
     *  @param ctx The call's context
     *  @param action The action byte
     *  @param p Its params
     */
    function _runDex(Context memory ctx, uint8 action, bytes calldata p) internal virtual {
        (ctx, p);
        revert SenzuRouter__UnsupportedAction(action);
    }

    /*  ================================================
                            ACTIONS
        ================================================  */

    function _pull(Context memory ctx, bytes calldata p) private {
        (address token, uint256 amount) = abi.decode(p, (address, uint256));
        _track(ctx, token);
        // slither-disable-start arbitrary-send-erc20
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        token.safeTransferFrom2(ctx.user, address(this), amount);
        // slither-disable-end arbitrary-send-erc20
    }

    function _open(Context memory ctx, bytes calldata p) private {
        (bytes memory adapterData, address[] memory tokens, uint256[] memory minimums) =
            abi.decode(p, (bytes, address[], uint256[]));
        if (tokens.length != minimums.length) revert SenzuRouter__LengthMismatch();
        bool direct = _paysUser(ctx);
        for (uint256 i; i < tokens.length; ++i) {
            if (!direct) _track(ctx, tokens[i]);
            uint256 bal = tokens[i].balanceOf(address(this));
            if (bal > 0) tokens[i].safeTransfer(adapter, bal);
        }
        (uint256 id,, address token0, address token1, uint256 used0, uint256 used1) =
            collateral.open(ctx.user, _recipient(ctx), adapterData);
        ctx.lastId = id;
        if (!direct) {
            _track(ctx, token0);
            _track(ctx, token1);
        }
        for (uint256 i; i < tokens.length; ++i) {
            uint256 deposited = tokens[i] == token0 ? used0 : (tokens[i] == token1 ? used1 : 0);
            if (deposited < minimums[i]) revert SenzuRouter__DepositBelowMinimum(tokens[i], deposited, minimums[i]);
        }
    }

    function _increase(Context memory ctx, bytes calldata p) private {
        (uint256 id, uint256 amount0, uint256 amount1, uint256 min0, uint256 min1, bytes memory adapterData) =
            abi.decode(p, (uint256, uint256, uint256, uint256, uint256, bytes));
        _addLiquidity(ctx, _positionId(ctx, id), amount0, amount1, min0, min1, adapterData);
    }

    function _increaseFromUser(Context memory ctx, bytes calldata p) private {
        (uint256 id, uint256 fromUser0, uint256 fromUser1, uint256 min0, uint256 min1, bytes memory adapterData) =
            abi.decode(p, (uint256, uint256, uint256, uint256, uint256, bytes));
        id = _positionId(ctx, id);
        (address token0, address token1) = _tokensOf(ctx, id);
        if (fromUser0 == ALL) fromUser0 = token0.balanceOf(ctx.user);
        if (fromUser1 == ALL) fromUser1 = token1.balanceOf(ctx.user);
        if (fromUser0 == 0 && fromUser1 == 0) {
            if (min0 > 0) revert SenzuRouter__DepositBelowMinimum(token0, 0, min0);
            if (min1 > 0) revert SenzuRouter__DepositBelowMinimum(token1, 0, min1);
            return;
        }
        // slither-disable-start arbitrary-send-erc20
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        if (fromUser0 > 0) token0.safeTransferFrom2(ctx.user, adapter, fromUser0);
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        if (fromUser1 > 0) token1.safeTransferFrom2(ctx.user, adapter, fromUser1);
        // slither-disable-end arbitrary-send-erc20
        (, uint256 deposited0, uint256 deposited1) =
            collateral.increaseLiquidity(ctx.user, id, _recipient(ctx), adapterData);
        if (deposited0 < min0) revert SenzuRouter__DepositBelowMinimum(token0, deposited0, min0);
        if (deposited1 < min1) revert SenzuRouter__DepositBelowMinimum(token1, deposited1, min1);
    }

    function _borrow(Context memory ctx, bytes calldata p) private {
        (uint256 id, address asset, uint256 amount) = abi.decode(p, (uint256, address, uint256));
        _track(ctx, asset);
        collateral.borrow(ctx.user, _positionId(ctx, id), asset, amount, address(this));
    }

    function _swap(Context memory ctx, bytes calldata p) private {
        (address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, bytes memory route) =
            abi.decode(p, (address, address, uint256, uint256, bytes));
        _track(ctx, tokenIn);
        _track(ctx, tokenOut);
        // One read for both: ALL's amount, and what the event measures the spend against (a swap inside a position
        // action emits nothing and reads only for ALL)
        uint256 heldIn = amountIn == ALL || ctx.swapOnly ? tokenIn.balanceOf(address(this)) : 0;
        if (amountIn == ALL) amountIn = heldIn;
        uint256 received = _checkedSwap(tokenIn, tokenOut, amountIn, amountOutMin, route);
        if (ctx.swapOnly) {
            emit Swap(
                ctx.user,
                ctx.wrapped && tokenIn == address(weth) ? address(0) : tokenIn,
                ctx.nativeOut && tokenOut == address(weth) ? address(0) : tokenOut,
                heldIn - tokenIn.balanceOf(address(this)),
                received
            );
        }
    }

    function _repay(Context memory ctx, bytes calldata p) private {
        (uint256 id, address asset, uint256 amount) = abi.decode(p, (uint256, address, uint256));
        id = _positionId(ctx, id);
        _track(ctx, asset);
        if (amount == ALL) {
            amount = asset.balanceOf(address(this));
            if (amount == 0 || borrowable.debtOf(ctx.user, id, asset) == 0) return;
        }
        _approveMax(asset, address(borrowable), amount);
        borrowable.repay(ctx.user, id, asset, amount);
    }

    function _redeem(Context memory ctx, bytes calldata p) private {
        (uint256 id, uint256 units, uint256 min0, uint256 min1, bytes memory adapterData) =
            abi.decode(p, (uint256, uint256, uint256, uint256, bytes));
        id = _positionId(ctx, id);
        _trackUnlessPaid(ctx, id);
        if (units == ALL) units = collateral.balanceOf(ctx.user, id);
        (uint256 amount0, uint256 amount1) = collateral.redeem(ctx.user, id, units, _recipient(ctx), adapterData);
        if (amount0 < min0 || amount1 < min1) {
            (address token0, address token1) = ISenzuAdapter(adapter).tokens(id);
            if (amount0 < min0) revert SenzuRouter__InsufficientOutput(token0, amount0, min0);
            revert SenzuRouter__InsufficientOutput(token1, amount1, min1);
        }
    }

    function _collectFees(Context memory ctx, bytes calldata p) private {
        uint256 id = _positionId(ctx, abi.decode(p, (uint256)));
        _trackUnlessPaid(ctx, id);
        ISenzuAdapter(adapter).collectFees(ctx.user, id, _recipient(ctx));
    }

    function _compound(Context memory ctx, bytes calldata p) private {
        (uint256 id, uint256 min0, uint256 min1, bytes memory adapterData) =
            abi.decode(p, (uint256, uint256, uint256, bytes));
        id = _positionId(ctx, id);
        _trackPosition(ctx, id);
        (uint256 fee0, uint256 fee1) = ISenzuAdapter(adapter).collectFees(ctx.user, id, address(this));
        _addLiquidity(ctx, id, fee0, fee1, min0, min1, adapterData);
    }

    function _supply(Context memory ctx, bytes calldata p) private {
        (address asset, uint256 amount) = abi.decode(p, (address, uint256));
        _track(ctx, asset);
        if (amount == ALL) amount = asset.balanceOf(address(this));
        _approveMax(asset, address(borrowable), amount);
        borrowable.supply(asset, amount, ctx.user);
    }

    function _withdraw(Context memory ctx, bytes calldata p) private {
        (address asset, uint256 shares) = abi.decode(p, (address, uint256));
        if (!_paysUser(ctx)) _track(ctx, asset);
        if (shares == ALL) shares = borrowable.balanceOf(ctx.user, lenderId(asset));
        borrowable.withdraw(asset, shares, _recipient(ctx), ctx.user);
    }

    /// @dev The repayment and fee are settled after the last action (`senzuLockAcquired`), so later actions can pay
    function _liquidate(Context memory ctx, bytes calldata p) private {
        (address borrower, uint256 id, address asset, uint256 repayAssets) =
            abi.decode(p, (address, uint256, address, uint256));
        uint256 index = _track(ctx, asset);
        (, uint256 repaid, uint256 fee) = collateral.liquidate(borrower, id, asset, repayAssets, ctx.user);
        uint256 due = repaid + fee;
        if (due > 0) ctx.hasUnsettled = true;
        ctx.unsettled[index] += due;
        _approveMax(asset, address(borrowable), ctx.unsettled[index]);
    }

    function _swapForDebt(Context memory ctx, bytes calldata p) private {
        (uint256 id, address asset, address tokenIn, uint256 maxIn, bytes memory route) =
            abi.decode(p, (uint256, address, address, uint256, bytes));
        id = _positionId(ctx, id);
        if (tokenIn == asset) revert SenzuRouter__InvalidRoute();
        if (_aggregatorOf(route) != address(0)) revert SenzuRouter__InvalidAggregatorRoute();
        _track(ctx, asset);
        _track(ctx, tokenIn);

        uint256 debt = borrowable.debtOf(ctx.user, id, asset);
        uint256 held = asset.balanceOf(address(this));
        if (debt <= held) return;
        uint256 missing = debt - held;
        uint256 balanceIn = tokenIn.balanceOf(address(this));
        if (maxIn == ALL) maxIn = balanceIn;
        _swapExactOut(tokenIn, asset, missing, route);

        uint256 spent = balanceIn - tokenIn.balanceOf(address(this));
        if (spent > maxIn) revert SenzuRouter__ExcessiveInput(tokenIn, spent, maxIn);
        uint256 received = asset.balanceOf(address(this)) - held;
        if (received < missing) revert SenzuRouter__InsufficientOutput(asset, received, missing);
    }

    function _openExact(Context memory ctx, bytes calldata p) private {
        (bytes memory adapterData, uint256 fromUser0, uint256 fromUser1, uint256 maxBorrow0, uint256 maxBorrow1) =
            abi.decode(p, (bytes, uint256, uint256, uint256, uint256));
        (address token0, address token1, uint256 amount0, uint256 amount1) =
            ISenzuAdapter(adapter).quoteDeposit(adapterData);
        uint256 id = collateral.nextPositionId();
        bool direct = _paysUser(ctx);
        _fund(ctx, id, token0, amount0, fromUser0, maxBorrow0, direct);
        _fund(ctx, id, token1, amount1, fromUser1, maxBorrow1, direct);
        (ctx.lastId,,,,,) = collateral.open(ctx.user, _recipient(ctx), adapterData);
    }

    function _authorize(Context memory ctx, bytes calldata p) private {
        (bool lending, uint256 deadline, uint8 v, bytes32 r, bytes32 s) =
            abi.decode(p, (bool, uint256, uint8, bytes32, bytes32));
        ISenzuERC6909 token = lending ? ISenzuERC6909(address(borrowable)) : ISenzuERC6909(address(collateral));
        // As Uniswap's Permit2Forwarder: a front-run signature must not block the call; a missing operator reverts
        // at the first action that needs it
        try token.setOperatorBySig(ctx.user, address(this), true, deadline, v, r, s) {} catch {}
    }

    function _permit(Context memory ctx, bytes calldata p) private {
        (IAllowanceTransfer.PermitBatch memory batch, bytes memory signature) =
            abi.decode(p, (IAllowanceTransfer.PermitBatch, bytes));
        // As `_authorize`: a signature someone submitted first must not block the call; a missing allowance reverts at
        // the first pull that needs it
        try IPermit2(SafeTransferLib.PERMIT2).permit(ctx.user, batch, signature) {} catch {}
    }

    function _postPrices(bytes calldata p) private {
        bytes[] memory updates = abi.decode(p, (bytes[]));
        uint256 fee = pyth.getUpdateFee(updates);
        if (fee > 0) weth.withdraw(fee);
        pyth.updatePriceFeeds{value: fee}(updates);
    }

    /*  ================================================
                            HELPERS
        ================================================  */

    /// @dev Sends `amount` of each token to the adapter (ALL: what the router holds) and adds it to `id`; at least
    ///      min0/min1 must go in, the rest comes back
    function _addLiquidity(
        Context memory ctx,
        uint256 id,
        uint256 amount0,
        uint256 amount1,
        uint256 min0,
        uint256 min1,
        bytes memory adapterData
    ) private {
        (address token0, address token1) = _tokensOf(ctx, id);
        if (amount0 == ALL) amount0 = token0.balanceOf(address(this));
        if (amount1 == ALL) amount1 = token1.balanceOf(address(this));
        if (amount0 == 0 && amount1 == 0) {
            if (min0 > 0) revert SenzuRouter__DepositBelowMinimum(token0, 0, min0);
            if (min1 > 0) revert SenzuRouter__DepositBelowMinimum(token1, 0, min1);
            return;
        }

        if (amount0 > 0) token0.safeTransfer(adapter, amount0);
        if (amount1 > 0) token1.safeTransfer(adapter, amount1);
        (, uint256 deposited0, uint256 deposited1) =
            collateral.increaseLiquidity(ctx.user, id, _recipient(ctx), adapterData);
        if (deposited0 < min0) revert SenzuRouter__DepositBelowMinimum(token0, deposited0, min0);
        if (deposited1 < min1) revert SenzuRouter__DepositBelowMinimum(token1, deposited1, min1);
    }

    /// @dev Pays the adapter `amount` of `token` for an OpenExact: the router's balance first, then the user's wallet
    ///      up to `fromUser`, then a borrow against the new position up to `maxBorrow`
    function _fund(
        Context memory ctx,
        uint256 id,
        address token,
        uint256 amount,
        uint256 fromUser,
        uint256 maxBorrow,
        bool direct
    ) private {
        if (!direct) _track(ctx, token);
        if (amount == 0) return;
        uint256 held = token.balanceOf(address(this));
        uint256 sent = held < amount ? held : amount;
        if (sent > 0) {
            if (direct) _track(ctx, token);
            token.safeTransfer(adapter, sent);
        }
        uint256 rest = amount - sent;
        if (fromUser == ALL) fromUser = token.balanceOf(ctx.user);
        uint256 pulled = rest < fromUser ? rest : fromUser;
        // slither-disable-start arbitrary-send-erc20
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        if (pulled > 0) token.safeTransferFrom2(ctx.user, adapter, pulled);
        // slither-disable-end arbitrary-send-erc20
        rest -= pulled;
        if (rest > maxBorrow) revert SenzuRouter__ExcessiveInput(token, rest, maxBorrow);
        if (rest > 0) collateral.borrow(ctx.user, id, token, rest, adapter);
    }

    function _checkedSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, bytes memory route)
        private
        returns (uint256 received)
    {
        if (tokenIn == tokenOut) revert SenzuRouter__InvalidRoute();
        uint256 before = tokenOut.balanceOf(address(this));
        if (amountIn > 0) {
            address aggregator = _aggregatorOf(route);
            if (aggregator != address(0)) _swapThrough(aggregator, tokenIn, amountIn, amountOutMin, route);
            else _swapExactIn(tokenIn, tokenOut, amountIn, route);
        }
        received = tokenOut.balanceOf(address(this)) - before;
        if (received < amountOutMin) revert SenzuRouter__InsufficientOutput(tokenOut, received, amountOutMin);
    }

    /// @inheritdoc ISenzuRouter
    function aggregators() external pure returns (address[] memory list) {
        list = new address[](6);
        list[0] = ZERO_EX;
        list[1] = KYBERSWAP;
        list[2] = ONE_INCH;
        list[3] = ONE_INCH_ROBINHOOD;
        list[4] = VELORA;
        list[5] = OPENOCEAN;
    }

    /// @inheritdoc ISenzuRouter
    function isAggregator(address target) public pure returns (bool) {
        return target == ZERO_EX || target == KYBERSWAP || target == ONE_INCH || target == ONE_INCH_ROBINHOOD
            || target == VELORA || target == OPENOCEAN;
    }

    /// @dev The aggregator a route starts with, or zero for a route on the deployment's DEX: no DEX route can start
    ///      with one (v3/Aero paths start with tokenIn, v4's with an ABI offset)
    function _aggregatorOf(bytes memory route) private pure returns (address aggregator) {
        if (route.length < 20) return address(0);
        // The first 20 bytes on purpose: the prefix that marks an aggregator route
        // forge-lint: disable-next-line(unsafe-typecast)
        aggregator = address(bytes20(route));
        if (!isAggregator(aggregator)) return address(0);
    }

    /**
     *  @dev Sells `amountIn` through `aggregator` with the route's calldata after its 20-byte prefix. The aggregator
     *       is approved for exactly `amountIn` during the call and for nothing after it, and `_checkedSwap` measures
     *       the output by balance against a minimum that must be above zero: calldata paying anyone else, or keeping
     *       the input, reverts the whole call. Called with no value, so ETH never leaves the router
     */
    function _swapThrough(
        address aggregator,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMin,
        bytes memory route
    ) private {
        if (amountOutMin == 0) revert SenzuRouter__InvalidAggregatorRoute();
        bytes memory data;
        // The calldata after the prefix, in place: its length overwrites the prefix (route isn't read after)
        // slither-disable-next-line assembly
        assembly ("memory-safe") {
            data := add(route, 20)
            mstore(data, sub(mload(route), 20))
        }
        tokenIn.safeApproveWithRetry(aggregator, amountIn);
        // slither-disable-next-line low-level-calls
        (bool ok, bytes memory reason) = aggregator.call(data);
        if (!ok) {
            // slither-disable-next-line assembly
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
        tokenIn.safeApprove(aggregator, 0);
    }

    function _approveMax(address token, address spender, uint256 amount) private {
        if (IERC20(token).allowance(address(this), spender) < amount) {
            token.safeApproveWithRetry(spender, type(uint256).max);
        }
    }

    /// @dev An existing position's two tokens, tracked
    function _trackPosition(Context memory ctx, uint256 id) private view returns (address token0, address token1) {
        _requireOpened(id);
        return _trackTokensOf(ctx, id);
    }

    /// @dev The last action pays the user straight, a hop through the router fewer, unless the router must still
    ///      unwrap ETH or pay a liquidation's repayment with what it holds
    function _paysUser(Context memory ctx) private pure returns (bool) {
        return ctx.lastAction && !ctx.nativeOut && !ctx.hasUnsettled;
    }

    /// @dev Where an action sends what comes out: the user (`_paysUser`), or the router, which sweeps it at the end
    function _recipient(Context memory ctx) private view returns (address) {
        return _paysUser(ctx) ? ctx.user : address(this);
    }

    /// @dev An existing position's two tokens, tracked unless the action pays the user straight
    function _tokensOf(Context memory ctx, uint256 id) private view returns (address token0, address token1) {
        if (!_paysUser(ctx)) return _trackPosition(ctx, id);
        _requireOpened(id);
        return ISenzuAdapter(adapter).tokens(id);
    }

    /// @dev `_trackPosition` without reading the tokens when the action pays the user straight
    function _trackUnlessPaid(Context memory ctx, uint256 id) private view {
        if (_paysUser(ctx)) _requireOpened(id);
        else _trackPosition(ctx, id);
    }

    function _requireOpened(uint256 id) private view {
        if (id == 0 || id >= collateral.nextPositionId()) revert SenzuRouter__NoPosition();
    }

    function _trackTokensOf(Context memory ctx, uint256 id) private view returns (address token0, address token1) {
        (token0, token1) = ISenzuAdapter(adapter).tokens(id);
        _track(ctx, token0);
        _track(ctx, token1);
    }

    /// @dev Adds `token` to the tokens the call sweeps back to the user, once; returns its index in `ctx.tokens`
    function _track(Context memory ctx, address token) private pure returns (uint256 index) {
        uint256 count = ctx.tokenCount;
        for (; index < count; ++index) {
            if (ctx.tokens[index] == token) return index;
        }
        if (count == MAX_TOKENS) revert SenzuRouter__TooManyTokens();
        ctx.tokens[count] = token;
        ctx.tokenCount = count + 1;
    }

    /// @dev Id 0 means the position this call opened last, or the one it is about to open (a borrow before Open)
    function _positionId(Context memory ctx, uint256 id) private view returns (uint256) {
        if (id != 0) return id;
        return ctx.lastId != 0 ? ctx.lastId : collateral.nextPositionId();
    }

    /// @dev `_positionId`, for each DEX's own actions: an existing position only
    function _positionIdOf(Context memory ctx, uint256 id) internal view returns (uint256 positionId) {
        positionId = _positionId(ctx, id);
        _requireOpened(positionId);
    }

    function _sweep(address token, bool nativeOut, address to) private {
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) return;
        if (nativeOut && token == address(weth)) {
            weth.withdraw(balance);
            // `to` is the caller
            // forge-lint: disable-next-line(arbitrary-send-eth)
            to.safeTransferETH(balance);
        } else {
            token.safeTransfer(to, balance);
        }
    }
}
