// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {UniswapV3Adapter} from "../../src/adapters/UniswapV3Adapter.sol";
import {SenzuBorrowable} from "../../src/core/SenzuBorrowable.sol";
import {SenzuCollateral} from "../../src/core/SenzuCollateral.sol";
import {ISenzuFactory} from "../../src/interfaces/ISenzuFactory.sol";
import {HealthResult} from "../../src/libraries/Types.sol";
import {LiquidityAmounts} from "../../src/libraries/uniswap/LiquidityAmounts.sol";
import {SenzuFactory} from "../../src/modules/SenzuFactory.sol";
import {SenzuOracle} from "../../src/modules/SenzuOracle.sol";
import {SenzuRiskConfig} from "../../src/modules/SenzuRiskConfig.sol";
import {BorrowableDeployer} from "../../src/modules/deployers/BorrowableDeployer.sol";
import {CollateralDeployer} from "../../src/modules/deployers/CollateralDeployer.sol";
import {SenzuBaseRouter} from "../../src/periphery/SenzuBaseRouter.sol";
import {SenzuUniswapV3Router} from "../../src/periphery/routers/SenzuUniswapV3Router.sol";
import {RouterPlan} from "../utils/RouterPlan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Tied leverage on mainnet: deposit WBTC/WETH, borrow BOTH legs and add them as liquidity in one
///         transaction with no swap. Real Uniswap v3 WBTC/WETH 0.05% pool and Chainlink. Needs ETH_RPC_URL.
contract TiedLeverageForkTest is Test {
    uint256 constant FORK_BLOCK = 26_055_083; // BTC ≈ $83,500, ETH ≈ $2,690

    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; // token0, 8 decimals
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // token1
    address constant NFPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant POOL = 0x4585FE77225b41b697C938B018E2Ac67Ac5a20c0;
    address constant BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant WBTC_BTC = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23; // WBTC = WBTC/BTC × BTC/USD
    address constant ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint24 constant FEE = 500;

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    SenzuBorrowable borrowable;

    SenzuCollateral collateral;
    UniswapV3Adapter adapter;
    SenzuBaseRouter senzuRouter;
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
        SenzuOracle oracle = SenzuOracle(factory.oracle());
        ISenzuFactory.Deployment memory set = factory.deploy(
            "Test",
            address(
                new UniswapV3Adapter(factory.collateralAddress("Test"), INonfungiblePositionManager(NFPM).factory())
            )
        );
        SenzuRiskConfig riskConfig = SenzuRiskConfig(factory.riskConfig());
        borrowable = SenzuBorrowable(set.borrowable);
        collateral = SenzuCollateral(set.collateral);
        adapter = UniswapV3Adapter(set.adapter);
        // No swap here: both legs are borrowed at the range's ratio
        senzuRouter = new SenzuUniswapV3Router(address(collateral), WETH, address(0), address(0)); // no swaps

        oracle.addFeedWithRatio(WBTC, BTC_USD, 1 hours, WBTC_BTC, 1 days);
        oracle.addFeed(WETH, ETH_USD, 1 hours);
        borrowable.createMarket(WBTC, 0.1e18);
        borrowable.createMarket(WETH, 0.1e18);

        riskConfig.setTokenRisk(address(adapter), WBTC, 1.15e18, 1.05e18, true);
        riskConfig.setTokenRisk(address(adapter), WETH, 1.15e18, 1.05e18, true);
        riskConfig.setPairEnabled(address(adapter), WBTC, WETH, true);

        // Bob lends both assets
        deal(WBTC, BOB, 100e8);
        deal(WETH, BOB, 3_000e18);
        vm.startPrank(BOB);
        IERC20(WBTC).approve(address(borrowable), type(uint256).max);
        IERC20(WETH).approve(address(borrowable), type(uint256).max);
        borrowable.supply(WBTC, 100e8, BOB);
        borrowable.supply(WETH, 3_000e18, BOB);
        vm.stopPrank();

        // ±10% range around the current price (tick spacing 10)
        (, int24 tick,,,,,) = IUniswapV3Pool(POOL).slot0();
        tickLower = (tick - 953) / 10 * 10;
        tickUpper = (tick + 953) / 10 * 10 + 10;

        deal(WBTC, ALICE, 1e8);
        deal(WETH, ALICE, 50e18);
        vm.startPrank(ALICE);
        IERC20(WBTC).approve(address(senzuRouter), type(uint256).max);
        IERC20(WETH).approve(address(senzuRouter), type(uint256).max);
        collateral.setOperator(address(senzuRouter), true);
        vm.stopPrank();
    }

    /// @dev Token amounts `liquidity` holds in Alice's range at the pool's current price, rounded up by 1 wei
    function _amountsFor(uint128 liquidity) internal view returns (uint256 amount0, uint256 amount1) {
        (uint160 sqrtPrice,,,,,,) = IUniswapV3Pool(POOL).slot0();
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPrice, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity
        );
        (amount0, amount1) = (amount0 + 1, amount1 + 1);
    }

    /// @notice 3x leverage: deposit the amounts for L, borrow the amounts for 2L of both tokens, no swap
    function test_fork_borrowBothLegsNoSwap() public {
        // Margin: liquidity worth about 0.05 BTC + the matching ETH
        uint128 depositL = 1e13;
        (uint256 dep0, uint256 dep1) = _amountsFor(depositL);
        (uint256 bor0, uint256 bor1) = _amountsFor(2 * depositL);
        assertGt(dep0, 0);
        assertGt(dep1, 0);

        bytes memory mint = abi.encode(
            UniswapV3Adapter.MintData({
                token0: WBTC, token1: WETH, fee: FEE, tickLower: tickLower, tickUpper: tickUpper, liquidity: 0
            })
        );
        // Both legs borrowed at the range's ratio: no swap
        RouterPlan.Plan memory p;
        p = RouterPlan.pull(p, WBTC, dep0);
        p = RouterPlan.pull(p, WETH, dep1);
        p = RouterPlan.open(p, mint, WBTC, WETH);
        p = RouterPlan.borrow(p, 0, WBTC, bor0);
        p = RouterPlan.borrow(p, 0, WETH, bor1);
        p = RouterPlan.increase(p, 0, RouterPlan.ALL, RouterPlan.ALL, 0, 0);

        uint256 wbtcBefore = IERC20(WBTC).balanceOf(ALICE);
        uint256 wethBefore = IERC20(WETH).balanceOf(ALICE);

        vm.prank(ALICE);
        uint256 id = senzuRouter.execute(p.actions, p.params, block.timestamp, false);
        uint256 liquidity = collateral.balanceOf(ALICE, id);

        // 3x the deposited liquidity, in one transaction, with no swap
        assertApproxEqRel(liquidity, 3 * uint256(depositL), 0.0001e18, "three times the margin's liquidity");
        assertEq(borrowable.debtOf(ALICE, id, WBTC), bor0);
        assertEq(borrowable.debtOf(ALICE, id, WETH), bor1);

        // Borrowed in the range's ratio, so almost nothing comes back unused: Alice's wallet only changed by her margin
        assertApproxEqAbs(wbtcBefore - IERC20(WBTC).balanceOf(ALICE), dep0, 3);
        assertApproxEqRel(wethBefore - IERC20(WETH).balanceOf(ALICE), dep1, 0.0001e18);

        // Both debts are tied to the collateral's own tokens
        HealthResult memory h = collateral.health(ALICE, id);
        console2.log("margin    WBTC (1e8) / WETH (1e18):", dep0, dep1);
        console2.log("borrowed  WBTC (1e8) / WETH (1e18):", bor0, bor1);
        console2.log("position value USD (1e18):", h.collateralUsdWad);
        console2.log("debt USD (1e18):          ", h.debtUsdWad);
        console2.log("health factor (1e18):     ", h.healthWad);
        assertGt(h.healthWad, 1.05e18, "passed the borrow check");
        assertApproxEqRel(h.debtUsdWad * 3, h.collateralUsdWad * 2, 0.001e18, "debt is 2/3 of the position");

        // Nothing is left behind in the router or the adapter
        assertEq(IERC20(WBTC).balanceOf(address(senzuRouter)), 0);
        assertEq(IERC20(WETH).balanceOf(address(senzuRouter)), 0);
        assertEq(IERC20(WBTC).balanceOf(address(adapter)), 0);
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0);
    }
}
