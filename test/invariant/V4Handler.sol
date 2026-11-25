// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {UniswapV4Adapter} from "../../src/adapters/UniswapV4Adapter.sol";
import {ISenzuFactory} from "../../src/interfaces/ISenzuFactory.sol";
import {UniswapV4State} from "../../src/libraries/uniswap/UniswapV4State.sol";
import {SenzuUniswapV4Router} from "../../src/periphery/routers/SenzuUniswapV4Router.sol";
import {MockERC20, MockWETH} from "../mocks/Mocks.sol";
import {deployPoolManager} from "../utils/UniswapV4Bytecode.sol";
import {LocalRouterHandler} from "./LocalRouterHandler.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Anyone else in the pool: adds liquidity, swaps and donates, paying with tokens minted or ETH dealt on demand
contract V4PoolUser is IUnlockCallback {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    IPoolManager internal immutable PM;
    address internal immutable WETH;

    uint8 internal constant MINT = 0;
    uint8 internal constant SWAP = 1;
    uint8 internal constant DONATE = 2;
    uint8 internal constant ALIGN = 3;
    uint8 internal constant SWAP_FROM = 4;

    constructor(IPoolManager pm, address weth_) {
        PM = pm;
        WETH = weth_;
    }

    function mint(PoolKey memory key, int24 lower, int24 upper, uint128 liquidity) external {
        PM.unlock(abi.encode(MINT, key, abi.encode(lower, upper, liquidity)));
    }

    function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) external {
        PM.unlock(abi.encode(SWAP, key, abi.encode(zeroForOne, amountIn)));
    }

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1) external {
        PM.unlock(abi.encode(DONATE, key, abi.encode(amount0, amount1)));
    }

    function swapToPrice(PoolKey memory key, bool zeroForOne, uint160 target) external {
        PM.unlock(abi.encode(ALIGN, key, abi.encode(zeroForOne, target)));
    }

    function swapFrom(PoolKey memory key, address payer, bool zeroForOne, uint256 amountIn) external {
        PM.unlock(abi.encode(SWAP_FROM, key, abi.encode(payer, zeroForOne, amountIn)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(PM), "not the PoolManager");
        (uint8 op, PoolKey memory key, bytes memory p) = abi.decode(data, (uint8, PoolKey, bytes));
        BalanceDelta delta;
        if (op == MINT) {
            (int24 lower, int24 upper, uint128 liquidity) = abi.decode(p, (int24, int24, uint128));
            (delta,) = PM.modifyLiquidity(
                key, ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), bytes32(0)), ""
            );
        } else if (op == SWAP) {
            (bool zeroForOne, uint256 amountIn) = abi.decode(p, (bool, uint256));
            uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            delta = PM.swap(key, SwapParams(zeroForOne, -int256(amountIn), limit), "");
        } else if (op == DONATE) {
            (uint256 amount0, uint256 amount1) = abi.decode(p, (uint256, uint256));
            delta = PM.donate(key, amount0, amount1, "");
        } else if (op == ALIGN) {
            (bool zeroForOne, uint160 target) = abi.decode(p, (bool, uint160));
            delta = PM.swap(key, SwapParams(zeroForOne, -int256(type(int128).max), target), "");
        } else {
            (address payer, bool zeroForOne, uint256 amountIn) = abi.decode(p, (address, bool, uint256));
            uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            delta = PM.swap(key, SwapParams(zeroForOne, -int256(amountIn), limit), "");
            _settleFrom(key.currency0, payer, delta.amount0());
            _settleFrom(key.currency1, payer, delta.amount1());
            return "";
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    function _settleFrom(Currency currency, address payer, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint128(-amount);
            if (currency.isAddressZero()) {
                MockERC20(WETH).transferFrom(payer, address(this), owed);
                MockWETH(WETH).withdraw(owed);
                PM.settle{value: owed}();
            } else {
                PM.sync(currency);
                MockERC20(Currency.unwrap(currency)).transferFrom(payer, address(PM), owed);
                PM.settle();
            }
        } else if (amount > 0) {
            uint256 got = uint256(uint128(amount));
            if (currency.isAddressZero()) {
                PM.take(currency, address(this), got);
                MockWETH(WETH).deposit{value: got}();
                MockERC20(WETH).transfer(payer, got);
            } else {
                PM.take(currency, payer, got);
            }
        }
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint128(-amount);
            if (currency.isAddressZero()) {
                vm.deal(address(this), owed);
                PM.settle{value: owed}();
            } else {
                PM.sync(currency);
                MockERC20(Currency.unwrap(currency)).mint(address(PM), owed);
                PM.settle();
            }
        } else if (amount > 0) {
            PM.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    receive() external payable {}
}

/**
 *  @notice The core and the real UniswapV4Adapter against Uniswap v4's real PoolManager (mainnet's code, etched; no
 *          fork). `native`: the ETH/USDC pool, the adapter taking WETH and wrapping and unwrapping it; otherwise a
 *          WETH/USDC pool of two ERC-20s, USDC its currency0
 */
contract V4Handler is LocalRouterHandler {
    uint24 internal constant FEE = 3000;
    uint256 internal constant POOLS_SLOT = 6;
    uint256 internal constant POSITIONS_OFFSET = 6;
    IPoolManager internal immutable PM;

    bool public immutable native;
    V4PoolUser public poolUser;
    PoolKey internal key;
    bytes32 internal poolId;

    constructor(bool native_) {
        native = native_;
        PM = IPoolManager(deployPoolManager());
        MockERC20 weth_ = new MockWETH();
        MockERC20 usdc_;
        do {
            usdc_ = new MockERC20("USDC", 6);
        } while (!native_ && address(usdc_) > address(weth_));
        ISenzuFactory.Deployment memory d = factory.deploy(
            "V4", address(new UniswapV4Adapter(factory.collateralAddress("V4"), address(PM), address(weth_)))
        );
        _list(d, weth_, usdc_, native_);
        _wireRouter(address(new SenzuUniswapV4Router(d.collateral, address(weth_), address(PM), address(0))));

        key = PoolKey({
            currency0: Currency.wrap(native_ ? address(0) : address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: SPACING,
            hooks: IHooks(address(0))
        });
        poolId = PoolId.unwrap(key.toId());
        _setRanges(PM.initialize(key, _oracleSqrtPriceX96()));
        poolUser = new V4PoolUser(PM, address(weth_));
        poolUser.mint(key, ranges[0][0], ranges[0][1], 1e16);
        vm.startPrank(ATTACKER);
        token0.approve(address(poolUser), type(uint256).max);
        token1.approve(address(poolUser), type(uint256).max);
        vm.stopPrank();
    }

    function _route(address, address) internal view override returns (bytes memory) {
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = key;
        return abi.encode(keys);
    }

    function _v4() internal view returns (UniswapV4Adapter) {
        return UniswapV4Adapter(payable(address(adapter)));
    }

    function _mintData(uint256 r, uint128 liquidity) internal view override returns (bytes memory) {
        return abi.encode(
            UniswapV4Adapter.MintData({
                poolKey: key, tickLower: ranges[r][0], tickUpper: ranges[r][1], liquidity: liquidity
            })
        );
    }

    /// @dev WETH the adapter unwraps must be backed by ETH
    function _give(MockERC20 token, address to, uint256 amount) internal override {
        if (!native || token != weth || amount == 0) {
            super._give(token, to, amount);
            return;
        }
        vm.deal(address(this), amount);
        MockWETH(address(weth)).deposit{value: amount}();
        weth.transfer(to, amount);
    }

    function _sentIn(MockERC20 token) internal view override returns (uint256) {
        return token.balanceOf(address(adapter)) - _v4().held(address(token));
    }

    function _poolSwap(bool zeroForOne, uint256 amount) internal override returns (bool) {
        try poolUser.swap(key, zeroForOne, amount) {
            return true;
        } catch {
            return false;
        }
    }

    function _alignPoolToOracle() internal override returns (bool) {
        uint160 target = _oracleSqrtPriceX96();
        uint160 current = UniswapV4State.sqrtPriceX96(PM, poolId);
        if (current == target) return true;
        try poolUser.swapToPrice(key, current > target, target) {
            return UniswapV4State.sqrtPriceX96(PM, poolId) == target;
        } catch {
            return false;
        }
    }

    function _attackerPoolSwap(bool zeroForOne, uint256 amount) internal override returns (bool) {
        try poolUser.swapFrom(key, ATTACKER, zeroForOne, amount) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev v4's donate: fees paid to the liquidity in range, the adapter's positions' among it
    function _donate(uint256 a, uint256 b) internal override {
        uint256 amount0 = token0 == weth ? _bound(a, 0, 1e18) : _bound(a, 0, 2_000e6);
        uint256 amount1 = token1 == weth ? _bound(b, 0, 1e18) : _bound(b, 0, 2_000e6);
        try poolUser.donate(key, amount0, amount1) {}
        catch {
            _fail("donate reverted");
        }
    }

    /// @notice Each position is its own PoolManager position (the adapter's, salted by its id), holding its units
    function checkPool() public view override {
        for (uint256 i; i < allIds.length; ++i) {
            require(_poolLiquidity(allIds[i]) == collateral.totalSupply(allIds[i]), "PoolManager liquidity != units");
        }
    }

    /// @notice What a position's holders are owed is held for it, or pending in the PoolManager, within one wei per
    ///         call made
    function checkFeesBacked() public view override {
        for (uint256 i; i < allIds.length; ++i) {
            uint256 id = allIds[i];
            (uint256 owed0, uint256 owed1) = _owed(id);
            (uint256 pending0, uint256 pending1) = _pending(id);
            (,, uint128 held0, uint128 held1) = _v4().fees(id);
            require(owed0 <= held0 + pending0 + totalCalls, "token0 fees owed exceed the held and pending");
            require(owed1 <= held1 + pending1 + totalCalls, "token1 fees owed exceed the held and pending");
        }
    }

    /// @notice The adapter holds exactly its positions' held fees, plus what was sent to it since the last deposit,
    ///         and no ETH
    function checkAdapterBalances() public view override {
        uint256 held0;
        uint256 held1;
        for (uint256 i; i < allIds.length; ++i) {
            (,, uint128 h0, uint128 h1) = _v4().fees(allIds[i]);
            held0 += h0;
            held1 += h1;
        }
        require(
            _v4().held(address(token0)) == held0 && _v4().held(address(token1)) == held1,
            "held != the positions' held fees"
        );
        require(
            token0.balanceOf(address(adapter)) == held0 + stray[address(token0)]
                && token1.balanceOf(address(adapter)) == held1 + stray[address(token1)],
            "adapter holds tokens beyond its fees and what was sent since the last deposit"
        );
        require(address(adapter).balance == 0, "adapter holds ETH");
    }

    /// @dev Held fee dust after every holder collected: at most 1 wei of floor rounding per call + 1 per (holder, id)
    function _checkUnwoundAdapter() internal view override {
        checkAdapterBalances();
        for (uint256 i; i < allIds.length; ++i) {
            require(_poolLiquidity(allIds[i]) == 0, "unwindAll: v4 PoolManager liquidity remained");
        }
        uint256 bound = totalCalls * 2 + allIds.length * holders.length + 2;
        require(_v4().held(address(token0)) <= bound, "unwindAll: excess token0 fee dust in v4 adapter");
        require(_v4().held(address(token1)) <= bound, "unwindAll: excess token1 fee dust in v4 adapter");
    }

    function feeDust() public view override returns (uint256 dust0, uint256 dust1) {
        for (uint256 i; i < allIds.length; ++i) {
            uint256 id = allIds[i];
            (uint256 owed0, uint256 owed1) = _owed(id);
            (uint256 pending0, uint256 pending1) = _pending(id);
            (,, uint128 held0, uint128 held1) = _v4().fees(id);
            (uint256 have0, uint256 have1) = (_lessCut(held0 + pending0), _lessCut(held1 + pending1));
            if (have0 > owed0 + dust0) dust0 = have0 - owed0;
            if (have1 > owed1 + dust1) dust1 = have1 - owed1;
        }
    }

    function _poolLiquidity(uint256 id) internal view returns (uint128) {
        int24[2] memory r = ranges[rangeOf[id]];
        bytes32 position = keccak256(abi.encodePacked(address(adapter), r[0], r[1], bytes32(id)));
        uint256 pool = uint256(keccak256(abi.encode(poolId, POOLS_SLOT)));
        return uint128(uint256(PM.extsload(keccak256(abi.encode(position, pool + POSITIONS_OFFSET)))));
    }

    function _pending(uint256 id) internal view returns (uint256 pending0, uint256 pending1) {
        int24[2] memory r = ranges[rangeOf[id]];
        (uint256 inside0, uint256 inside1, uint256 last0, uint256 last1) =
            UniswapV4State.positionFees(PM, poolId, address(adapter), r[0], r[1], bytes32(id));
        uint256 liquidity = _poolLiquidity(id);
        unchecked {
            pending0 = FullMath.mulDiv(inside0 - last0, liquidity, Q128);
            pending1 = FullMath.mulDiv(inside1 - last1, liquidity, Q128);
        }
    }
}

/// @notice Cold-start empty-market mode on the real Uniswap v4 PoolManager: markets start at 0 supply, 1-wei dust biased
contract V4EmptyMarketHandler is V4Handler(true) {
    function _seedMarkets() internal pure override returns (bool) {
        return false;
    }
}
