// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SenzuBaseRouter} from "../SenzuBaseRouter.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/**
 *  @title  SenzuV3PathRouter
 *  @notice SenzuBaseRouter swapping in Uniswap v3 style pools (v3 and its forks). Route: a packed path, tokenIn first
 *          in both directions (tokenIn, tier, token, tier, ..., tokenOut; 20-byte tokens, 3-byte tiers). Each DEX's
 *          router says what a tier is and finds the pool (`_poolOf`).
 */
abstract contract SenzuV3PathRouter is SenzuBaseRouter {
    using SafeTransferLib for address;
    using SafeCastLib for uint256;
    using SafeCastLib for int256;

    uint256 internal constant HOP = 23;

    address transient _pool;

    constructor(address collateral_, address weth_, address pyth_) SenzuBaseRouter(collateral_, weth_, pyth_) {}

    /// @dev The DEX's pool for two tokens (in either order) and a hop's 3 tier bytes; an unknown pool is an invalid
    ///      route
    function _poolOf(address a, address b, uint24 tier) internal view virtual returns (address);

    /// @notice Uniswap v3's swap callback, the name Slipstream kept. A fork that renamed it adds its own external
    ///         function calling `_swapCallback`
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        _swapCallback(amount0Delta, amount1Delta, data);
    }

    /// @dev Pays only the pool being swapped in
    function _swapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) internal {
        if (msg.sender != _pool) revert SenzuRouter__NotPool();
        (bytes memory route, uint256 i, bool exactOutput) = abi.decode(data, (bytes, uint256, bool));
        uint256 owed = (amount0Delta > 0 ? amount0Delta : amount1Delta).toUint256();
        (address a,,) = _hop(route, i);

        if (!exactOutput || i == 0) {
            a.safeTransfer(msg.sender, owed);
            return;
        }
        (address prev, uint24 tier,) = _hop(route, i - 1);
        bool zeroForOne = prev < a;
        address pool = msg.sender;
        // forge-lint: disable-next-line(missing-events-access-control)
        _pool = _poolOf(prev, a, tier);
        // The pool checks its balance only after this callback returns
        IUniswapV3Pool(_pool)
            .swap(pool, zeroForOne, -owed.toInt256(), _limit(zeroForOne), abi.encode(route, i - 1, true));
    }

    function _swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, bytes memory route) internal override {
        uint256 hops = _checkRoute(route, tokenIn, tokenOut);
        uint256 amount = amountIn;
        for (uint256 i; i < hops; ++i) {
            (address a, uint24 tier, address b) = _hop(route, i);
            bool zeroForOne = a < b;
            _pool = _poolOf(a, b, tier);
            (int256 d0, int256 d1) = IUniswapV3Pool(_pool)
                .swap(address(this), zeroForOne, amount.toInt256(), _limit(zeroForOne), abi.encode(route, i, false));
            if ((zeroForOne ? d0 : d1).toUint256() != amount) revert SenzuRouter__PartialFill();
            amount = (-(zeroForOne ? d1 : d0)).toUint256();
        }
        _pool = address(0);
    }

    function _swapExactOut(address tokenIn, address tokenOut, uint256 amountOut, bytes memory route) internal override {
        uint256 last = _checkRoute(route, tokenIn, tokenOut) - 1;
        (address a, uint24 tier, address b) = _hop(route, last);
        bool zeroForOne = a < b;
        _pool = _poolOf(a, b, tier);
        (int256 d0, int256 d1) = IUniswapV3Pool(_pool)
            .swap(address(this), zeroForOne, -amountOut.toInt256(), _limit(zeroForOne), abi.encode(route, last, true));
        if ((-(zeroForOne ? d1 : d0)).toUint256() != amountOut) revert SenzuRouter__PartialFill();
        _pool = address(0);
    }

    function _checkRoute(bytes memory route, address tokenIn, address tokenOut) private pure returns (uint256 hops) {
        if (route.length < 20 + HOP || (route.length - 20) % HOP != 0) revert SenzuRouter__InvalidRoute();
        hops = (route.length - 20) / HOP;
        (address first,,) = _hop(route, 0);
        (,, address last) = _hop(route, hops - 1);
        if (first != tokenIn || last != tokenOut) revert SenzuRouter__InvalidRoute();
    }

    function _hop(bytes memory route, uint256 i) private pure returns (address a, uint24 tier, address b) {
        uint256 at = i * HOP;
        assembly ("memory-safe") {
            let p := add(add(route, 32), at)
            a := shr(96, mload(p))
            tier := shr(232, mload(add(p, 20)))
            b := shr(96, mload(add(p, 23)))
        }
    }

    function _limit(bool zeroForOne) private pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }
}
