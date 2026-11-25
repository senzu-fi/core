// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {UniswapV3Adapter} from "../../src/adapters/UniswapV3Adapter.sol";
import {ISenzuFactory} from "../../src/interfaces/ISenzuFactory.sol";
import {SenzuUniswapV3Router} from "../../src/periphery/routers/SenzuUniswapV3Router.sol";
import {MockERC20} from "../mocks/Mocks.sol";
import {deployUniswapV3Factory} from "../utils/UniswapV3Bytecode.sol";
import {LocalRouterHandler} from "./LocalRouterHandler.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface IUniswapV3FactoryLike {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

/// @dev Anyone else in the pool: mints and swaps with tokens minted on demand
contract PoolUser {
    function mint(IUniswapV3Pool pool, address recipient, int24 lower, int24 upper, uint128 liquidity) external {
        pool.mint(recipient, lower, upper, liquidity, abi.encode(pool.token0(), pool.token1()));
    }

    function swap(IUniswapV3Pool pool, bool zeroForOne, int256 amount) external {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        pool.swap(address(this), zeroForOne, amount, limit, abi.encode(pool.token0(), pool.token1()));
    }

    function swapToPrice(IUniswapV3Pool pool, uint160 target) external {
        (uint160 current,,,,,,) = pool.slot0();
        if (current == target) return;
        bool zeroForOne = current > target;
        pool.swap(address(this), zeroForOne, int256(type(int128).max), target, abi.encode(pool.token0(), pool.token1()));
    }

    function swapFrom(IUniswapV3Pool pool, address payer, bool zeroForOne, int256 amount) external {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        pool.swap(payer, zeroForOne, amount, limit, abi.encode(pool.token0(), pool.token1(), payer));
    }

    function uniswapV3MintCallback(uint256 owed0, uint256 owed1, bytes calldata data) external {
        _pay(owed0, owed1, data);
    }

    function uniswapV3SwapCallback(int256 delta0, int256 delta1, bytes calldata data) external {
        uint256 owed0 = delta0 > 0 ? uint256(delta0) : 0;
        uint256 owed1 = delta1 > 0 ? uint256(delta1) : 0;
        if (data.length == 96) {
            (address token0, address token1, address payer) = abi.decode(data, (address, address, address));
            if (owed0 > 0) MockERC20(token0).transferFrom(payer, msg.sender, owed0);
            if (owed1 > 0) MockERC20(token1).transferFrom(payer, msg.sender, owed1);
            return;
        }
        _pay(owed0, owed1, data);
    }

    function _pay(uint256 owed0, uint256 owed1, bytes calldata data) private {
        (address token0, address token1) = abi.decode(data, (address, address));
        if (owed0 > 0) MockERC20(token0).mint(msg.sender, owed0);
        if (owed1 > 0) MockERC20(token1).mint(msg.sender, owed1);
    }
}

/// @notice The core and the real UniswapV3Adapter against a real Uniswap v3 pool (published bytecode, no fork)
contract V3Handler is LocalRouterHandler {
    uint24 internal constant FEE = 3000;

    IUniswapV3Pool public pool;
    PoolUser public poolUser;
    uint256[RANGES] public donated;

    constructor(bool wethIsToken0) {
        address v3 = deployUniswapV3Factory();
        ISenzuFactory.Deployment memory d =
            factory.deploy("V3", address(new UniswapV3Adapter(factory.collateralAddress("V3"), v3)));
        MockERC20 weth_ = new MockERC20("WETH", 18);
        MockERC20 usdc_;
        do {
            usdc_ = new MockERC20("USDC", 6);
        } while ((address(weth_) < address(usdc_)) != wethIsToken0);
        _list(d, weth_, usdc_, wethIsToken0);
        _wireRouter(address(new SenzuUniswapV3Router(d.collateral, address(weth_), v3, address(0))));

        pool = IUniswapV3Pool(IUniswapV3FactoryLike(v3).createPool(address(token0), address(token1), FEE));
        pool.initialize(_oracleSqrtPriceX96());
        (, int24 tick,,,,,) = pool.slot0();
        _setRanges(tick);
        poolUser = new PoolUser();
        poolUser.mint(pool, address(poolUser), ranges[0][0], ranges[0][1], 1e16);
        vm.startPrank(ATTACKER);
        token0.approve(address(poolUser), type(uint256).max);
        token1.approve(address(poolUser), type(uint256).max);
        vm.stopPrank();
    }

    function _mintData(uint256 r, uint128 liquidity) internal view override returns (bytes memory) {
        return abi.encode(
            UniswapV3Adapter.MintData({
                token0: address(token0),
                token1: address(token1),
                fee: FEE,
                tickLower: ranges[r][0],
                tickUpper: ranges[r][1],
                liquidity: liquidity
            })
        );
    }

    function _route(address tokenIn, address tokenOut) internal pure override returns (bytes memory) {
        return abi.encodePacked(tokenIn, FEE, tokenOut);
    }

    function _poolSwap(bool zeroForOne, uint256 amount) internal override returns (bool) {
        try poolUser.swap(pool, zeroForOne, int256(amount)) {
            return true;
        } catch {
            return false;
        }
    }

    function _alignPoolToOracle() internal override returns (bool) {
        uint160 target = _oracleSqrtPriceX96();
        try poolUser.swapToPrice(pool, target) {
            (uint160 cur,,,,,,) = pool.slot0();
            return cur == target;
        } catch {
            return false;
        }
    }

    function _attackerPoolSwap(bool zeroForOne, uint256 amount) internal override returns (bool) {
        try poolUser.swapFrom(pool, ATTACKER, zeroForOne, int256(amount)) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev Liquidity someone else adds to the adapter's range in the pool: it belongs to no position. Only the two
    ///      one-sided ranges, so the others' fee dust stays measurable
    function _donate(uint256 rangeSeed, uint256 liquidity) internal override {
        uint256 r = 3 + rangeSeed % 2;
        uint128 l = uint128(_bound(liquidity, 1e6, 1e12));
        poolUser.mint(pool, address(adapter), ranges[r][0], ranges[r][1], l);
        donated[r] += l;
    }

    /// @notice The adapter's liquidity in each pool range is its positions' there, plus what others added
    function checkPool() public view override {
        for (uint256 r; r < RANGES; ++r) {
            uint256 sum = donated[r];
            for (uint256 i; i < allIds.length; ++i) {
                if (rangeOf[allIds[i]] == r) sum += collateral.totalSupply(allIds[i]);
            }
            (uint128 liquidity,,,,) = pool.positions(_key(r));
            require(liquidity == sum, "pool range liquidity != positions' units");
        }
    }

    /// @notice What holders are owed in fees in a range is in the pool for the adapter to collect, within one wei per
    ///         call made (the pool rounds a range's fees down at every poke)
    function checkFeesBacked() public view override {
        for (uint256 r; r < RANGES; ++r) {
            uint256 owed0;
            uint256 owed1;
            uint256 anyId;
            for (uint256 i; i < allIds.length; ++i) {
                if (rangeOf[allIds[i]] != r) continue;
                anyId = allIds[i];
                (uint256 fee0, uint256 fee1) = _owed(allIds[i]);
                owed0 += fee0;
                owed1 += fee1;
            }
            if (anyId == 0) continue;
            (uint128 liquidity, uint256 last0, uint256 last1, uint128 have0, uint128 have1) = pool.positions(_key(r));
            (uint256 inside0, uint256 inside1) = UniswapV3Adapter(address(adapter)).feeGrowth(anyId);
            unchecked {
                inside0 -= last0;
                inside1 -= last1;
            }
            require(
                owed0 <= have0 + FullMath.mulDiv(inside0, liquidity, Q128) + totalCalls,
                "token0 fees owed exceed the pool's"
            );
            require(
                owed1 <= have1 + FullMath.mulDiv(inside1, liquidity, Q128) + totalCalls,
                "token1 fees owed exceed the pool's"
            );
        }
    }

    /// @notice The pool holds a v3 position's fees and liquidity: the adapter holds only what was sent to it since
    ///         the last deposit
    function checkAdapterBalances() public view override {
        require(
            token0.balanceOf(address(adapter)) == stray[address(token0)]
                && token1.balanceOf(address(adapter)) == stray[address(token1)],
            "adapter holds tokens"
        );
    }

    function _checkUnwoundAdapter() internal view override {
        checkAdapterBalances();
        for (uint256 r; r < RANGES; ++r) {
            (uint128 liquidity,,,,) = pool.positions(_key(r));
            require(liquidity == donated[r], "unwindAll: v3 pool liquidity remained");
        }
    }

    /// @dev Per range, skipping ranges others added liquidity to: that liquidity's fees belong to nobody
    function feeDust() public view override returns (uint256 dust0, uint256 dust1) {
        for (uint256 r; r < RANGES; ++r) {
            if (donated[r] > 0) continue;
            (uint256 have0, uint256 have1, uint256 owed0, uint256 owed1) = _rangeFees(r);
            (have0, have1) = (_lessCut(have0), _lessCut(have1));
            if (have0 > owed0 + dust0) dust0 = have0 - owed0;
            if (have1 > owed1 + dust1) dust1 = have1 - owed1;
        }
    }

    /// @dev What the pool holds and accrues for the adapter's range, and what its positions' holders are owed
    function _rangeFees(uint256 r) internal view returns (uint256 have0, uint256 have1, uint256 owed0, uint256 owed1) {
        uint256 anyId;
        for (uint256 i; i < allIds.length; ++i) {
            if (rangeOf[allIds[i]] != r) continue;
            anyId = allIds[i];
            (uint256 fee0, uint256 fee1) = _owed(anyId);
            owed0 += fee0;
            owed1 += fee1;
        }
        if (anyId == 0) return (0, 0, 0, 0);
        (uint128 liquidity, uint256 last0, uint256 last1, uint128 tokensOwed0, uint128 tokensOwed1) =
            pool.positions(_key(r));
        (uint256 inside0, uint256 inside1) = UniswapV3Adapter(address(adapter)).feeGrowth(anyId);
        unchecked {
            inside0 -= last0;
            inside1 -= last1;
        }
        have0 = tokensOwed0 + FullMath.mulDiv(inside0, liquidity, Q128);
        have1 = tokensOwed1 + FullMath.mulDiv(inside1, liquidity, Q128);
    }

    function _key(uint256 r) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(address(adapter), ranges[r][0], ranges[r][1]));
    }
}

/// @notice Cold-start empty-market mode on the real Uniswap v3 pool: markets start at 0 supply, 1-wei dust biased
contract V3EmptyMarketHandler is V3Handler(true) {
    function _seedMarkets() internal pure override returns (bool) {
        return false;
    }
}
