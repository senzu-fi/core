// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {UniswapV4Adapter} from "../../src/adapters/UniswapV4Adapter.sol";
import {SenzuBorrowable} from "../../src/core/SenzuBorrowable.sol";
import {SenzuCollateral} from "../../src/core/SenzuCollateral.sol";
import {ISenzuAdapter} from "../../src/interfaces/ISenzuAdapter.sol";
import {ISenzuFactory} from "../../src/interfaces/ISenzuFactory.sol";
import {SenzuFactory} from "../../src/modules/SenzuFactory.sol";
import {SenzuOracle} from "../../src/modules/SenzuOracle.sol";
import {SenzuRiskConfig} from "../../src/modules/SenzuRiskConfig.sol";
import {BorrowableDeployer} from "../../src/modules/deployers/BorrowableDeployer.sol";
import {CollateralDeployer} from "../../src/modules/deployers/CollateralDeployer.sol";
import {SenzuBaseRouter} from "../../src/periphery/SenzuBaseRouter.sol";
import {SenzuUniswapV4Router} from "../../src/periphery/routers/SenzuUniswapV4Router.sol";
import {AdapterSuite} from "../utils/AdapterSuite.sol";
import {V4RouterHarness} from "../utils/RouterHarness.sol";
import {RouterPlan} from "../utils/RouterPlan.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";

/// @dev A pool key with plain addresses, for this test's own PoolManager calls (same ABI as v4-core's PoolKey)
struct V4PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @dev The same key as v4-core's PoolKey, what the adapter's MintData takes
function toPoolKey(V4PoolKey memory k) pure returns (PoolKey memory) {
    return PoolKey({
        currency0: Currency.wrap(k.currency0),
        currency1: Currency.wrap(k.currency1),
        fee: k.fee,
        tickSpacing: k.tickSpacing,
        hooks: IHooks(k.hooks)
    });
}
import {ISenzuCollateral} from "../../src/interfaces/ISenzuCollateral.sol";
import {ISenzuRouter} from "../../src/interfaces/ISenzuRouter.sol";
import {HealthMath} from "../../src/libraries/HealthMath.sol";
import {HealthResult, Shape} from "../../src/libraries/Types.sol";
import {lockLiquidator} from "../utils/LockLiquidator.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @dev Circle's USDC (FiatToken): its pauser stops every transfer
interface IFiatToken {
    function pauser() external view returns (address);
    function pause() external;
    function unpause() external;
}

interface IPoolManagerSwap {
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(V4PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

/// @dev Exact-input swaps straight against the v4 PoolManager. Test-only volume generator.
contract V4Swapper {
    IPoolManagerSwap constant PM = IPoolManagerSwap(0x000000000004444c5dc75cB358380D2e3dE08A90);

    function swap(V4PoolKey memory key, bool zeroForOne, uint256 amountIn) external {
        PM.unlock(abi.encode(key, zeroForOne, amountIn));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(PM));
        (V4PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (V4PoolKey, bool, uint256));
        int256 delta = PM.swap(
            key,
            IPoolManagerSwap.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        // BalanceDelta: amount0 in the high 128 bits, amount1 in the low; negative = owed to the pool
        int128 amount0 = int128(delta >> 128);
        int128 amount1 = int128(delta);
        _settle(key.currency0, amount0);
        _settle(key.currency1, amount1);
        return "";
    }

    function _settle(address currency, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint128(-amount);
            if (currency == address(0)) {
                PM.settle{value: owed}();
            } else {
                PM.sync(currency);
                IERC20(currency).transfer(address(PM), owed);
                PM.settle();
            }
        } else if (amount > 0) {
            PM.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    receive() external payable {}
}

/// @notice The Uniswap deployment with the v4 adapter on an Ethereum mainnet fork, against the real v4 ETH/USDC
///         0.30% pool (native ETH). Needs ETH_RPC_URL (read from .env); skipped without it.
contract UniswapV4ForkTest is AdapterSuite {
    uint256 constant FORK_BLOCK = 26_055_083; // ETH ≈ $2,690

    address constant STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    int24 constant SPACING = 60;
    int24 constant TEN_PERCENT = 953; // ln(1.1) / ln(1.0001)

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA201);

    SenzuOracle oracle;
    SenzuBorrowable borrowable;
    SenzuCollateral collateral;
    UniswapV4Adapter adapter;
    V4PoolKey poolKey;
    int24 tickLower;
    int24 tickUpper;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc, FORK_BLOCK);

        SenzuFactory factory = new SenzuFactory(
            address(this),
            address(0x6A6D),
            address(0xDA0),
            address(new BorrowableDeployer()),
            address(new CollateralDeployer())
        );
        oracle = SenzuOracle(factory.oracle());
        oracle.addFeed(WETH, ETH_USD, 1 hours);
        oracle.addFeed(USDC, USDC_USD, 1 days);

        ISenzuFactory.Deployment memory d = factory.deploy(
            "Uniswap", address(new UniswapV4Adapter(factory.collateralAddress("Uniswap"), POOL_MANAGER, WETH))
        );
        borrowable = SenzuBorrowable(d.borrowable);
        collateral = SenzuCollateral(d.collateral);
        SenzuRiskConfig riskConfig = SenzuRiskConfig(factory.riskConfig());

        borrowable.createMarket(USDC, 0.1e18);
        borrowable.createMarket(WETH, 0.1e18);

        adapter = UniswapV4Adapter(payable(d.adapter));

        riskConfig.setTokenRisk(address(adapter), WETH, 1.15e18, 1.05e18, true);
        riskConfig.setTokenRisk(address(adapter), USDC, 1.02e18, 1.05e18, true);
        riskConfig.setFeeCut(address(adapter), 0.02e18); // the deploy's cut: every payout below pays it
        riskConfig.setPairEnabled(address(adapter), WETH, USDC, true);

        deal(USDC, BOB, 1_000_000e6);
        vm.startPrank(BOB);
        IERC20(USDC).approve(address(borrowable), type(uint256).max);
        borrowable.supply(USDC, 1_000_000e6, BOB);
        vm.stopPrank();

        poolKey =
            V4PoolKey({currency0: address(0), currency1: USDC, fee: 3000, tickSpacing: SPACING, hooks: address(0)});
        (uint160 sqrtPrice,,,) = IStateView(STATE_VIEW).getSlot0(PoolId.wrap(keccak256(abi.encode(poolKey))));
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPrice);
        tickLower = _floor(tick - TEN_PERCENT);
        tickUpper = _floor(tick + TEN_PERCENT) + SPACING;
    }

    /*  ================================================
                            Helpers
        ================================================  */

    /// @dev Between transactions the adapter holds exactly the fees it books as held
    modifier booksBalance() {
        _;
        address[2] memory tokens = [WETH, USDC];
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(IERC20(tokens[i]).balanceOf(address(adapter)), adapter.held(tokens[i]), "adapter books = balance");
        }
    }

    function _floor(int24 t) internal pure returns (int24 r) {
        r = t / SPACING * SPACING;
        if (t < 0 && t % SPACING != 0) r -= SPACING;
    }

    /// @dev Mints with whatever was pushed to the adapter first
    function _mintData() internal view returns (bytes memory) {
        return abi.encode(
            UniswapV4Adapter.MintData({
                poolKey: toPoolKey(poolKey), tickLower: tickLower, tickUpper: tickUpper, liquidity: 0
            })
        );
    }

    /// @dev Alice opens a ±10% ETH/USDC position with 1 WETH + 3,000 USDC
    /// @dev Compounding as the router does it (no core compound since 2026-10-15): the holder's fees go straight to
    ///      the adapter, which adds what it holds as liquidity; what doesn't fit is refunded to the holder
    function _compound(address who, uint256 id) internal returns (uint256 added) {
        vm.startPrank(who);
        adapter.collectFees(who, id, address(adapter));
        (added,,) = collateral.increaseLiquidity(who, id, who, "");
        vm.stopPrank();
    }

    function _open() internal returns (uint256 id) {
        deal(WETH, ALICE, 1e18);
        deal(USDC, ALICE, 3_000e6);
        bytes memory data = _mintData();
        vm.startPrank(ALICE);
        IERC20(WETH).transfer(address(adapter), 1e18);
        IERC20(USDC).transfer(address(adapter), 3_000e6);
        (id,,,,,) = collateral.open(ALICE, ALICE, data);
        vm.stopPrank();
    }

    /// @dev A second holder of `id`: units don't transfer, so Carol gets them in a partial liquidation. Alice
    ///      keeps the rest of her debt; the price comes back after
    function _liquidatePart(uint256 id) internal {
        vm.prank(ALICE);
        collateral.borrow(ALICE, id, USDC, 3_500e6, ALICE);
        uint256 crashed = oracle.priceUsd(WETH) * 65 / 100;
        vm.mockCall(
            ETH_USD,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(crashed / 1e10), block.timestamp, block.timestamp, uint80(1))
        );
        deal(USDC, CAROL, 875e6 * 11 / 10); // the repayment and the protocol's share of her bonus
        vm.startPrank(CAROL);
        IERC20(USDC).approve(address(borrowable), type(uint256).max);
        lockLiquidator().liquidate(collateral, ALICE, id, USDC, 875e6, CAROL);
        vm.stopPrank();
        vm.clearMockedCalls();
        assertGt(collateral.balanceOf(CAROL, id), 0);
    }

    function _usd(uint256 weth, uint256 usdc) internal view returns (uint256) {
        return weth * oracle.priceUsd(WETH) / 1e18 + usdc * oracle.priceUsd(USDC) / 1e6;
    }

    /// @dev Trades 50 ETH back and forth through the v4 pool three times
    function _generateVolume() internal {
        V4Swapper swapper = new V4Swapper();
        vm.deal(address(swapper), 150e18);
        deal(USDC, address(swapper), 500_000e6);
        for (uint256 i; i < 3; ++i) {
            swapper.swap(poolKey, true, 50e18);
            swapper.swap(poolKey, false, 134_000e6);
        }
    }

    /*  ================================================
                             Tests
        ================================================  */

    /// @dev The adapter reads the PoolManager's storage itself: it must read what StateView reads
    function test_fork_v4_stateMatchesStateView() public booksBalance {
        uint256 id = _open();
        IStateView view_ = IStateView(STATE_VIEW);
        PoolId poolId = PoolId.wrap(keccak256(abi.encode(poolKey)));
        assertEq(adapter.poolId(id), PoolId.unwrap(poolId), "poolId is the PoolManager's id");
        for (uint256 i; i < 3; ++i) {
            (uint160 sqrtPrice,,,) = view_.getSlot0(poolId);
            assertEq(adapter.poolSqrtPriceX96(id), sqrtPrice, "price");

            (uint128 liquidity, uint256 last0, uint256 last1) =
                view_.getPositionInfo(poolId, address(adapter), tickLower, tickUpper, bytes32(id));
            (uint256 inside0, uint256 inside1) = view_.getFeeGrowthInside(poolId, tickLower, tickUpper);
            (uint256 booked0, uint256 booked1,,) = adapter.fees(id);
            uint256 pending0;
            uint256 pending1;
            unchecked {
                pending0 = FullMath.mulDiv(inside0 - last0, liquidity, 1 << 128);
                pending1 = FullMath.mulDiv(inside1 - last1, liquidity, 1 << 128);
            }
            (uint256 preview0, uint256 preview1) = adapter.feeGrowth(id);
            assertEq(preview0, booked0 + FullMath.mulDiv(pending0, 1 << 128, liquidity), "token0 growth");
            assertEq(preview1, booked1 + FullMath.mulDiv(pending1, 1 << 128, liquidity), "token1 growth");
            if (i == 1) {
                _poke(id);
            }
            _generateVolume();
        }
    }

    function test_fork_v4_openValuesTheDeposit() public booksBalance {
        uint256 id = _open();

        // No NFT: the adapter's own pool position, salted with the position id, holds exactly the units
        (uint128 poolLiquidity,,) = IStateView(STATE_VIEW)
            .getPositionInfo(
                PoolId.wrap(keccak256(abi.encode(poolKey))), address(adapter), tickLower, tickUpper, bytes32(id)
            );
        assertEq(poolLiquidity, adapter.units(id));
        assertEq(collateral.totalSupply(id), adapter.units(id));
        assertEq(collateral.balanceOf(ALICE, id), adapter.units(id));

        Shape memory s = adapter.shape(id);
        assertEq(s.token0, WETH, "native ETH shows as WETH");
        assertEq(s.token1, USDC);

        uint256 usedUsd = _usd(1e18 - IERC20(WETH).balanceOf(ALICE), 3_000e6 - IERC20(USDC).balanceOf(ALICE));
        assertApproxEqRel(collateral.health(ALICE, id).collateralUsdWad, usedUsd, 0.005e18);
        assertEq(address(adapter).balance, 0, "no ETH left behind");
        assertEq(IERC20(WETH).balanceOf(address(adapter)) + IERC20(USDC).balanceOf(address(adapter)), 0);
    }

    function test_fork_v4_poolPriceMatchesOracle() public booksBalance {
        uint256 lpId = _open();
        uint256 poolSqrt = adapter.poolSqrtPriceX96(lpId);
        uint256 oracleSqrt = HealthMath.sqrtPriceX96FromUsd(oracle.priceUsd(WETH), oracle.priceUsd(USDC), 18, 6);
        assertApproxEqRel(poolSqrt, oracleSqrt, 0.005e18);
    }

    function test_fork_v4_borrowRedeemRepayRedeemAll() public booksBalance {
        uint256 id = _open();
        vm.prank(ALICE);
        collateral.borrow(ALICE, id, USDC, 1_500e6, ALICE);

        uint256 half = collateral.balanceOf(ALICE, id) / 2;
        uint256 valueBefore = collateral.health(ALICE, id).collateralUsdWad;
        uint256 wethBefore = IERC20(WETH).balanceOf(ALICE);
        vm.prank(ALICE);
        (uint256 out0, uint256 out1) = collateral.redeem(ALICE, id, half, ALICE, "");
        assertEq(IERC20(WETH).balanceOf(ALICE) - wethBefore, out0, "ETH arrives as WETH");
        assertApproxEqRel(_usd(out0, out1), valueBefore / 2, 0.005e18);

        // Repay, then redeem the rest: the other half comes back as tokens
        vm.startPrank(ALICE);
        IERC20(USDC).approve(address(borrowable), type(uint256).max);
        borrowable.repay(ALICE, id, USDC, type(uint256).max);
        uint256 weth = IERC20(WETH).balanceOf(ALICE);
        uint256 usdc = IERC20(USDC).balanceOf(ALICE);
        collateral.redeem(ALICE, id, collateral.balanceOf(ALICE, id), ALICE, "");
        adapter.collectFees(ALICE, id, ALICE);
        vm.stopPrank();
        uint256 back = _usd(IERC20(WETH).balanceOf(ALICE) - weth, IERC20(USDC).balanceOf(ALICE) - usdc);
        assertApproxEqRel(back, valueBefore - _usd(out0, out1), 0.005e18, "the other half, as tokens");
        assertEq(adapter.units(id), 0);
        assertEq(IERC20(WETH).balanceOf(address(adapter)) + IERC20(USDC).balanceOf(address(adapter)), 0);
    }

    /// @dev A removal's principal goes to its recipient even when that is address(0) (USDC refuses it, so the redeem
    ///      reverts): it never stays in the adapter, where the next deposit would take it
    function test_fork_v4_aRedeemToAddressZeroLeavesNothingInTheAdapter() public booksBalance {
        uint256 id = _open();
        uint256 units = collateral.balanceOf(ALICE, id);
        vm.prank(ALICE);
        try collateral.redeem(ALICE, id, units, address(0), "") {} catch {}
    }

    /// @dev Only minting: an existing PositionManager NFT can't come in
    function test_fork_v4_existingNftsAreRefused() public booksBalance {
        vm.prank(ALICE);
        vm.expectRevert(); // not MintData: fails to decode
        collateral.open(ALICE, ALICE, abi.encode(uint8(0), abi.encode(uint256(1))));
    }

    /// @dev The router pushes a mint's tokens to the adapter, which mints with its balance minus the fees it holds for
    ///      positions: a new position never takes another's held fees, and those stay collectable in full
    function test_fork_v4_aMintNeverSpendsHeldFees() public booksBalance {
        uint256 id = _open();
        _generateVolume();
        // A redeem checkpoints the holder, which collects the position's fees into the adapter
        vm.prank(ALICE);
        collateral.redeem(ALICE, id, 1, ALICE, "");
        uint256 heldWeth = adapter.held(WETH);
        uint256 heldUsdc = adapter.held(USDC);
        assertGt(heldWeth + heldUsdc, 0, "fees held for the position");
        (uint256 owed0, uint256 owed1) = adapter.feesOwed(ALICE, id);

        uint256 second = _open();
        assertGt(collateral.balanceOf(ALICE, second), 0);
        assertEq(adapter.held(WETH), heldWeth, "held fees untouched by the mint");
        assertEq(adapter.held(USDC), heldUsdc);
        assertEq(IERC20(WETH).balanceOf(address(adapter)), heldWeth, "the mint used or refunded all it was sent");
        assertEq(IERC20(USDC).balanceOf(address(adapter)), heldUsdc);

        vm.prank(ALICE);
        (uint256 got0, uint256 got1) = adapter.collectFees(ALICE, id, ALICE);
        assertEq(got0, owed0, "still collectable in full");
        assertEq(got1, owed1);
    }

    function test_fork_v4_previewIsWhatThePokeBooks() public booksBalance {
        uint256 id = _open();
        for (uint256 i; i < 3; ++i) {
            _generateVolume();
            (uint256 preview0, uint256 preview1) = adapter.feeGrowth(id);
            (uint256 poked0, uint256 poked1) = _poke(id);
            assertEq(preview0, poked0, "token0 growth");
            assertEq(preview1, poked1, "token1 growth");
            assertGt(poked0 + poked1, 0, "real fees");
        }
    }

    function test_fork_v4_feesAccrueAndSplitBetweenHolders() public booksBalance {
        uint256 id = _open();
        _generateVolume();

        (uint256 owed0, uint256 owed1) = adapter.feesOwed(ALICE, id);
        assertGt(owed0 + owed1, 0, "real fees accrued");

        // Carol takes units in a liquidation: the fees Alice hadn't collected go with them
        _liquidatePart(id);
        uint256 alice = collateral.balanceOf(ALICE, id);
        uint256 carol = collateral.balanceOf(CAROL, id);
        (uint256 seized0, uint256 seized1) = adapter.feesOwed(CAROL, id);
        assertApproxEqRel(seized0, owed0 * carol / (alice + carol), 0.001e18, "the seized units' share");
        assertApproxEqRel(seized1, owed1 * carol / (alice + carol), 0.001e18);
        _generateVolume();

        // Both rounds split by balance
        (uint256 alice0, uint256 alice1) = adapter.feesOwed(ALICE, id);
        (uint256 carol0, uint256 carol1) = adapter.feesOwed(CAROL, id);
        assertApproxEqRel(alice0 * carol / alice, carol0, 0.001e18, "split by balance");
        assertApproxEqRel(alice1 * carol / alice, carol1, 0.001e18);

        (, address dao) = SenzuRiskConfig(collateral.riskConfig()).feeCut(address(adapter));
        (uint256 daoWeth, uint256 daoUsdc) = (IERC20(WETH).balanceOf(dao), IERC20(USDC).balanceOf(dao));
        vm.prank(ALICE);
        (uint256 got0, uint256 got1) = adapter.collectFees(ALICE, id, ALICE);
        assertEq(got0, alice0);
        assertEq(got1, alice1);
        // The cut is 2% of what was owed, so 2/98 of the holder's (token0 is WETH here)
        assertApproxEqAbs(IERC20(WETH).balanceOf(dao) - daoWeth, got0 * 2 / 98, 1, "the protocol's cut");
        assertApproxEqAbs(IERC20(USDC).balanceOf(dao) - daoUsdc, got1 * 2 / 98, 1);
        uint256 carolWeth = IERC20(WETH).balanceOf(CAROL);
        uint256 carolUsdc = IERC20(USDC).balanceOf(CAROL);
        vm.prank(CAROL);
        adapter.collectFees(CAROL, id, CAROL);
        assertEq(IERC20(WETH).balanceOf(CAROL) - carolWeth, carol0);
        assertEq(IERC20(USDC).balanceOf(CAROL) - carolUsdc, carol1);

        assertLe(adapter.held(WETH), 2, "only rounding dust left");
        assertLe(adapter.held(USDC), 2, "only rounding dust left");
        assertEq(IERC20(WETH).balanceOf(address(adapter)), adapter.held(WETH), "held = balance");
        assertEq(IERC20(USDC).balanceOf(address(adapter)), adapter.held(USDC), "held = balance");
    }

    function test_fork_v4_compoundTurnsRealFeesIntoLiquidity() public booksBalance {
        uint256 id = _open();
        _generateVolume();
        (uint256 owed0, uint256 owed1) = adapter.feesOwed(ALICE, id);
        assertGt(owed0 + owed1, 0);

        uint256 unitsBefore = collateral.balanceOf(ALICE, id);
        uint256 valueBefore = collateral.health(ALICE, id).collateralUsdWad;
        uint256 added = _compound(ALICE, id);

        assertGt(added, 0);
        assertEq(collateral.balanceOf(ALICE, id), unitsBefore + added);
        assertEq(collateral.totalSupply(id), adapter.units(id), "units = v4 liquidity");
        (owed0, owed1) = adapter.feesOwed(ALICE, id);
        assertEq(owed0 + owed1, 0, "all fees went in");
        assertGt(collateral.health(ALICE, id).collateralUsdWad, valueBefore);
        assertEq(IERC20(WETH).balanceOf(address(adapter)), adapter.held(WETH), "no stray tokens");
        assertEq(IERC20(USDC).balanceOf(address(adapter)), adapter.held(USDC), "no stray tokens");
    }

    function test_fork_v4_liquidation() public booksBalance {
        uint256 id = _open();
        vm.prank(ALICE);
        collateral.borrow(ALICE, id, USDC, 3_500e6, ALICE);

        uint256 crashed = oracle.priceUsd(WETH) * 65 / 100;
        vm.mockCall(
            ETH_USD,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(crashed / 1e10), block.timestamp, block.timestamp, uint80(1))
        );
        assertTrue(collateral.health(ALICE, id).minSurplusUsdWad < 0);

        deal(USDC, BOB, 10_000e6);
        vm.startPrank(BOB);
        IERC20(USDC).approve(address(borrowable), type(uint256).max);
        (uint256 seized,) = lockLiquidator().liquidate(collateral, ALICE, id, USDC, type(uint256).max, BOB);
        vm.stopPrank();
        assertEq(collateral.balanceOf(BOB, id), seized);
        assertGt(seized, 0);
    }

    /// @dev No hooks at all: neither one that can act on removals nor a fee-only one (beforeInitialize + beforeSwap,
    ///      as Fables' pools have). A DEX built on v4 hooks gets its own adapter
    function test_fork_v4_refusesEveryHook() public booksBalance {
        deal(WETH, ALICE, 1e18);
        deal(USDC, ALICE, 3_000e6);
        address[2] memory hooks = [
            address(uint160(0xC0FFEE << 20) | uint160(1 << 9)),
            address(uint160(0xC0FFEE << 20) | uint160(1 << 7 | 1 << 13))
        ];
        for (uint256 i; i < hooks.length; i++) {
            poolKey.hooks = hooks[i];
            bytes memory data = _mintData();
            vm.prank(ALICE);
            vm.expectRevert(abi.encodeWithSelector(ISenzuAdapter.SenzuAdapter__HookNotAllowed.selector, hooks[i]));
            collateral.open(ALICE, ALICE, data);
        }
    }

    /// @dev The router's route through the test's pool (native ETH / USDC, no hook)
    /// @notice Each position is its own pool position, whose fees the adapter counts from zero: `deposit` returns
    ///         (0, 0), what a poke right after the open returns, even in a range another position already earned in.
    ///         The newcomer is owed nothing then, and earns from its open on
    function test_fork_v4_openInARangeWithFeesStartsAtZero() public booksBalance {
        uint256 a = _open();
        _generateVolume();
        vm.prank(ALICE);
        (uint256 a0, uint256 a1) = adapter.collectFees(ALICE, a, ALICE);
        assertGt(a0 + a1, 0, "the range earned");

        uint256 b = _open();
        (uint256 g0, uint256 g1) = adapter.feeGrowth(b);
        assertEq(g0, 0);
        assertEq(g1, 0);
        (g0, g1) = _poke(b);
        assertEq(g0, 0, "a poke finds nothing either");
        assertEq(g1, 0);
        (uint256 b0, uint256 b1) = adapter.feesOwed(ALICE, b);
        assertEq(b0 + b1, 0, "the newcomer is owed nothing");

        _generateVolume();
        vm.prank(ALICE);
        (b0, b1) = adapter.collectFees(ALICE, b, ALICE);
        assertGt(b0 + b1, 0, "and earns from its open on");
    }

    function _route() internal view returns (bytes memory) {
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = toPoolKey(poolKey);
        return abi.encode(keys);
    }

    /// @dev The swap goes through the v4 router, in the same v4 pool as the position
    function test_fork_v4_openLeveragedThroughRouter() public booksBalance {
        SenzuBaseRouter senzuRouter = new SenzuUniswapV4Router(address(collateral), WETH, POOL_MANAGER, address(0));
        bytes memory data = _mintData();
        bytes memory swapData = _route();
        // The 1 WETH of margin is sent as native ETH, which the router wraps
        RouterPlan.Plan memory p;
        p = RouterPlan.pull(p, USDC, 3_000e6);
        p = RouterPlan.open(p, data, WETH, USDC);
        p = RouterPlan.borrow(p, 0, USDC, 6_000e6);
        p = RouterPlan.swap(p, USDC, WETH, 3_000e6, 0, swapData);
        p = RouterPlan.increase(p, 0, RouterPlan.ALL, RouterPlan.ALL, 0, 0);

        deal(ALICE, 1 ether);
        deal(USDC, ALICE, 3_000e6);
        vm.startPrank(ALICE);
        IERC20(WETH).approve(address(senzuRouter), type(uint256).max);
        IERC20(USDC).approve(address(senzuRouter), type(uint256).max);
        collateral.setOperator(address(senzuRouter), true);
        uint256 id = senzuRouter.execute{value: 1 ether}(p.actions, p.params, block.timestamp, false);
        vm.stopPrank();

        HealthResult memory h = collateral.health(ALICE, id);
        assertApproxEqAbs(borrowable.debtOf(ALICE, id, USDC), 6_000e6, 1);
        assertGt(h.collateralUsdWad, 10_000e18, "margin + borrowed, in the v4 range");
        assertGt(h.healthWad, 1e18);
    }

    /*  ================================================
                             Swaps
        ================================================  */

    function _harness() internal returns (V4RouterHarness) {
        return new V4RouterHarness(address(collateral), WETH, POOL_MANAGER);
    }

    /// @dev WETH in and out of a native ETH pool: the router unwraps what it pays and wraps what it takes
    function test_fork_v4Router_exactInBothWays() public booksBalance {
        V4RouterHarness h = _harness();
        deal(USDC, address(h), 2_690e6);
        uint256 weth = h.exactIn(USDC, WETH, 2_690e6, _route());
        assertApproxEqRel(weth, 1e18, 0.02e18, "about 1 ETH at $2,690");

        uint256 usdc = h.exactIn(WETH, USDC, weth, _route());
        assertApproxEqRel(usdc, 2_690e6, 0.02e18, "back to about the same dollars, less two fees");
        assertEq(IERC20(WETH).balanceOf(address(h)), 0);
        assertEq(IERC20(USDC).balanceOf(address(h)), usdc);
        assertEq(address(h).balance, 0, "no native ETH left");
    }

    /// @dev Buys exactly the amount out, and spends only what it costs
    function test_fork_v4Router_exactOutSpendsWhatItCosts() public booksBalance {
        V4RouterHarness h = _harness();
        deal(WETH, address(h), 1e18);
        uint256 spent = h.exactOut(WETH, USDC, 1_000e6, _route());
        assertEq(IERC20(USDC).balanceOf(address(h)), 1_000e6);
        assertEq(IERC20(WETH).balanceOf(address(h)), 1e18 - spent, "the rest stays");
        assertApproxEqRel(spent, 0.372e18, 0.02e18);
    }

    /// @dev Pools without a hook only, and the route must lead from tokenIn to tokenOut
    function test_fork_v4Router_refusesHookedPoolsAndBadRoutes() public booksBalance {
        V4RouterHarness h = _harness();
        deal(USDC, address(h), 1_000e6);
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = toPoolKey(poolKey);
        keys[0].hooks = IHooks(address(uint160(0xC0FFEE << 20) | uint160(1 << 7)));
        vm.expectRevert(ISenzuRouter.SenzuRouter__InvalidRoute.selector);
        h.exactIn(USDC, WETH, 1_000e6, abi.encode(keys));

        // USDC into USDC: the pool leads to ETH
        vm.expectRevert(ISenzuRouter.SenzuRouter__InvalidRoute.selector);
        h.exactIn(USDC, USDC, 1_000e6, _route());

        vm.expectRevert(ISenzuRouter.SenzuRouter__InvalidRoute.selector);
        h.exactIn(USDC, WETH, 1_000e6, abi.encode(new PoolKey[](0)));

        // Only the PoolManager calls back
        vm.expectRevert(SenzuUniswapV4Router.SenzuRouter__NotPoolManager.selector);
        h.unlockCallback("");
    }

    /// @dev Audit 2026-10-05: 1 wei sent to the adapter used to make every native add that uses less ETH underflow,
    ///      such as a USDC-only range below the price
    function test_fork_v4_strayEthDoesntBlockAdds() public booksBalance {
        (bool ok,) = address(adapter).call{value: 1}("");
        assertTrue(ok);

        (uint160 sqrtPrice,,,) = IStateView(STATE_VIEW).getSlot0(PoolId.wrap(keccak256(abi.encode(poolKey))));
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPrice);
        bytes memory data = abi.encode(
            UniswapV4Adapter.MintData({
                poolKey: toPoolKey(poolKey),
                tickLower: _floor(tick - 2 * TEN_PERCENT),
                tickUpper: _floor(tick - TEN_PERCENT),
                liquidity: 0
            })
        );
        deal(USDC, ALICE, 3_000e6);
        vm.startPrank(ALICE);
        IERC20(USDC).transfer(address(adapter), 3_000e6);
        (uint256 id, uint256 units,,,,) = collateral.open(ALICE, ALICE, data);
        vm.stopPrank();
        assertGt(units, 0);
        assertEq(collateral.balanceOf(ALICE, id), units);
        assertEq(address(adapter).balance, 1, "the stray wei just stays");
    }

    /*  ================================================
                        Audit 2026-10-06
        ================================================  */

    /// @dev Audit 2026-10-06: every seize poked the adapter, which collects the position's fees in both pool tokens,
    ///      so while USDC was paused no ETH/USDC position could be liquidated, even for a WETH debt that needs no USDC
    ///      to move. A seize falls back to the fee growth the adapter already booked
    function test_fork_v4_liquidationWhileAPoolTokenIsPaused() public booksBalance {
        uint256 id = _open();
        deal(WETH, BOB, 10e18);
        vm.startPrank(BOB);
        IERC20(WETH).approve(address(borrowable), type(uint256).max);
        borrowable.supply(WETH, 10e18, BOB);
        vm.stopPrank();
        vm.prank(ALICE);
        collateral.borrow(ALICE, id, WETH, 1e18, ALICE);
        _generateVolume(); // fees in both tokens

        // ETH doubles: the WETH debt outgrows the position
        vm.mockCall(
            ETH_USD,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(oracle.priceUsd(WETH) * 2 / 1e10), block.timestamp, block.timestamp, uint80(1))
        );
        assertTrue(collateral.health(ALICE, id).minSurplusUsdWad < 0);

        IFiatToken usdc = IFiatToken(USDC);
        vm.prank(usdc.pauser());
        usdc.pause();

        deal(WETH, CAROL, 10e18);
        vm.startPrank(CAROL);
        IERC20(WETH).approve(address(borrowable), type(uint256).max);
        (uint256 seized,) = lockLiquidator().liquidate(collateral, ALICE, id, WETH, type(uint256).max, CAROL);
        vm.stopPrank();
        assertGt(seized, 0);

        // USDC moves again: the fees come out of the pool, and every holder's claim is covered
        vm.prank(usdc.pauser());
        usdc.unpause();
        address[3] memory holders = [ALICE, CAROL, address(0xDA0)];
        for (uint256 i; i < holders.length; ++i) {
            vm.prank(holders[i]);
            adapter.collectFees(holders[i], id, holders[i]);
        }
    }

    /// @dev Collects the position's pending fees and returns the growth the adapter booked
    function _poke(uint256 id) internal returns (uint256 growth0, uint256 growth1) {
        vm.prank(ALICE);
        adapter.collectFees(ALICE, id, ALICE);
        (growth0, growth1,,) = adapter.fees(id);
    }

    /*  ================================================
                        AdapterSuite
        ================================================  */

    function _suiteCollateral() internal view override returns (SenzuCollateral) {
        return collateral;
    }

    function _suiteAdapter() internal view override returns (ISenzuAdapter) {
        return adapter;
    }

    function _suiteAlice() internal pure override returns (address) {
        return ALICE;
    }

    function _suiteLiquidator() internal pure override returns (address) {
        return CAROL;
    }

    function _suiteDepositTokens() internal pure override returns (address, address, uint256, uint256) {
        return (WETH, USDC, 1e18, 3_000e6);
    }

    function _suiteMintData() internal view override returns (bytes memory) {
        return _mintData();
    }

    function _suiteNativeEthWeth() internal pure override returns (address) {
        return WETH;
    }

    function _suiteGenerateFees() internal override {
        _generateVolume();
    }

    function _suiteLiquidatePart(uint256 id) internal override returns (uint256) {
        _liquidatePart(id);
        return collateral.balanceOf(CAROL, id);
    }

    function _suiteLiquidateFull(uint256 id) internal override returns (uint256 seized) {
        vm.prank(ALICE);
        collateral.borrow(ALICE, id, USDC, 3_500e6, ALICE);
        uint256 crashed = oracle.priceUsd(WETH) * 30 / 100;
        vm.mockCall(
            ETH_USD,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(crashed / 1e10), block.timestamp, block.timestamp, uint80(1))
        );
        deal(USDC, CAROL, 10_000e6);
        vm.startPrank(CAROL);
        IERC20(USDC).approve(address(borrowable), type(uint256).max);
        (seized,) = lockLiquidator().liquidate(collateral, ALICE, id, USDC, type(uint256).max, CAROL);
        vm.stopPrank();
        vm.clearMockedCalls();
    }

    function _suiteCheckBooks() internal view override {
        assertEq(IERC20(WETH).balanceOf(address(adapter)), adapter.held(WETH), "adapter books = balance");
        assertEq(IERC20(USDC).balanceOf(address(adapter)), adapter.held(USDC), "adapter books = balance");
    }
}
