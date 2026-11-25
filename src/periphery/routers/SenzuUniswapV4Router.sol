// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SenzuBaseRouter} from "../SenzuBaseRouter.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/**
 *  @title  SenzuUniswapV4Router
 *  @notice SenzuBaseRouter swapping in hookless Uniswap v4 pools. Route: abi.encode(PoolKey[]), tokenIn's pool
 *          first, each hop starting in the currency the one before ended in. A route may start or end in a native ETH
 *          pool with tokenIn / tokenOut WETH.
 */
contract SenzuUniswapV4Router is SenzuBaseRouter, IUnlockCallback {
    using SafeTransferLib for address;
    using SafeCastLib for uint256;
    using SafeCast for int128;

    /// @notice A callback from anything but the PoolManager
    error SenzuRouter__NotPoolManager();

    /// @notice Uniswap v4 PoolManager
    IPoolManager public immutable poolManager;

    constructor(address collateral_, address weth_, address poolManager_, address pyth_)
        SenzuBaseRouter(collateral_, weth_, pyth_)
    {
        poolManager = IPoolManager(poolManager_);
    }

    /// @notice Uniswap v4 unlock callback, from the PoolManager only
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert SenzuRouter__NotPoolManager();
        (bool exactInput, address tokenIn, address tokenOut, uint256 amount, PoolKey[] memory keys) =
            abi.decode(data, (bool, address, address, uint256, PoolKey[]));
        (bool[] memory zeroForOne, Currency first, Currency last) = _directions(keys, tokenIn, tokenOut);

        uint256 paid;
        uint256 received;
        if (exactInput) {
            paid = amount;
            for (uint256 i; i < keys.length; ++i) {
                (uint256 spent, uint256 got) = _swapIn(keys[i], zeroForOne[i], -amount.toInt256());
                if (spent != amount) revert SenzuRouter__PartialFill();
                amount = got;
            }
            received = amount;
        } else {
            received = amount;
            for (uint256 i = keys.length; i > 0; --i) {
                (uint256 spent, uint256 got) = _swapIn(keys[i - 1], zeroForOne[i - 1], amount.toInt256());
                if (got != amount) revert SenzuRouter__PartialFill();
                amount = spent;
            }
            paid = amount;
        }
        _pay(first, paid);
        _take(last, received);
        return "";
    }

    function _swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, bytes memory route) internal override {
        poolManager.unlock(abi.encode(true, tokenIn, tokenOut, amountIn, abi.decode(route, (PoolKey[]))));
    }

    function _swapExactOut(address tokenIn, address tokenOut, uint256 amountOut, bytes memory route) internal override {
        poolManager.unlock(abi.encode(false, tokenIn, tokenOut, amountOut, abi.decode(route, (PoolKey[]))));
    }

    /// @dev Which pools a route may swap in, by hook: hookless ones only
    function _hookAllowed(address hooks) internal view virtual returns (bool) {
        return hooks == address(0);
    }

    function _acceptsEth(address from) internal view override returns (bool) {
        return from == address(weth) || from == address(poolManager);
    }

    function _directions(PoolKey[] memory keys, address tokenIn, address tokenOut)
        private
        view
        returns (bool[] memory zeroForOne, Currency first, Currency last)
    {
        if (keys.length == 0) revert SenzuRouter__InvalidRoute();
        zeroForOne = new bool[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            PoolKey memory key = keys[i];
            if (!_hookAllowed(address(key.hooks))) revert SenzuRouter__InvalidRoute();
            bool from0 = i == 0 ? _token(key.currency0) == tokenIn : key.currency0 == last;
            bool from1 = i == 0 ? Currency.unwrap(key.currency1) == tokenIn : key.currency1 == last;
            if (!from0 && !from1) revert SenzuRouter__InvalidRoute();
            if (i == 0) first = from0 ? key.currency0 : key.currency1;
            zeroForOne[i] = from0;
            last = from0 ? key.currency1 : key.currency0;
        }
        if (_token(last) != tokenOut) revert SenzuRouter__InvalidRoute();
    }

    function _swapIn(PoolKey memory key, bool zeroForOne, int256 amountSpecified)
        private
        returns (uint256 spent, uint256 got)
    {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta delta = poolManager.swap(key, SwapParams(zeroForOne, amountSpecified, limit), "");
        (int128 inDelta, int128 outDelta) =
            zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        spent = (-inDelta).toUint128();
        got = outDelta.toUint128();
    }

    function _pay(Currency currency, uint256 amount) private {
        if (currency.isAddressZero()) {
            weth.withdraw(amount);
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            Currency.unwrap(currency).safeTransfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    function _take(Currency currency, uint256 amount) private {
        poolManager.take(currency, address(this), amount);
        if (currency.isAddressZero()) weth.deposit{value: amount}();
    }

    function _token(Currency currency) private view returns (address) {
        return currency.isAddressZero() ? address(weth) : Currency.unwrap(currency);
    }
}
