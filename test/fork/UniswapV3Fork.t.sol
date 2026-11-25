// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {UniswapV3Adapter} from "../../src/adapters/UniswapV3Adapter.sol";
import {SenzuBorrowable} from "../../src/core/SenzuBorrowable.sol";
import {SenzuCollateral} from "../../src/core/SenzuCollateral.sol";
import {ISenzuAdapter} from "../../src/interfaces/ISenzuAdapter.sol";
import {HealthResult, Shape} from "../../src/libraries/Types.sol";
import {SenzuFactory} from "../../src/modules/SenzuFactory.sol";
import {SenzuOracle} from "../../src/modules/SenzuOracle.sol";
import {SenzuRiskConfig} from "../../src/modules/SenzuRiskConfig.sol";
import {SenzuBaseRouter} from "../../src/periphery/SenzuBaseRouter.sol";
import {SenzuUniswapV3Router} from "../../src/periphery/routers/SenzuUniswapV3Router.sol";
import {AdapterSuite} from "../utils/AdapterSuite.sol";
import {V3RouterHarness} from "../utils/RouterHarness.sol";
import {RouterPlan} from "../utils/RouterPlan.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

interface IPermit2Domain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Ethereum mainnet fork at a pinned block, against the real Uniswap v3 USDC/WETH 0.05% pool.
///         Needs ETH_RPC_URL (read from .env); skipped without it.
contract UniswapV3ForkTest is AdapterSuite {
    using RouterPlan for RouterPlan.Plan;

    uint256 constant FORK_BLOCK = 26_055_083; // ETH ≈ $2,690

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant NFPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant SWAP_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant POOL = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640; // USDC/WETH 0.05%, token0 = USDC
    address constant ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    uint24 constant FEE = 500;

    address constant DAO = address(0xDA0);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA201);
    address constant WHALE = address(0x3A1E);

    SenzuFactory factory;
    SenzuOracle oracle;
    SenzuRiskConfig riskConfig;
    SenzuBorrowable borrowable;
    SenzuCollateral collateral;
    UniswapV3Adapter adapter;
    SenzuBaseRouter senzuRouter;
    bytes32 pairKey;
    int24 tickLower;
    int24 tickUpper;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc, FORK_BLOCK);

        factory = new SenzuFactory(
            address(this), address(0x6A6D), DAO, address(new BorrowableDeployer()), address(new CollateralDeployer())
        );
        oracle = SenzuOracle(factory.oracle());
        ISenzuFactory.Deployment memory set = factory.deploy(
            "Test",
            address(
                new UniswapV3Adapter(factory.collateralAddress("Test"), INonfungiblePositionManager(NFPM).factory())
            )
        );
        riskConfig = SenzuRiskConfig(factory.riskConfig());
        borrowable = SenzuBorrowable(set.borrowable);
        collateral = SenzuCollateral(set.collateral);
        adapter = UniswapV3Adapter(set.adapter);
        senzuRouter = new SenzuUniswapV3Router(
            address(collateral), WETH, INonfungiblePositionManager(NFPM).factory(), address(0)
        );

        oracle.addFeed(WETH, ETH_USD, 1 hours);
        oracle.addFeed(USDC, USDC_USD, 1 days);

        borrowable.createMarket(USDC, 0.1e18);
        borrowable.createMarket(WETH, 0.1e18);

        riskConfig.setTokenRisk(address(adapter), WETH, 1.15e18, 1.05e18, true);
        riskConfig.setTokenRisk(address(adapter), USDC, 1.02e18, 1.05e18, true);
        riskConfig.setFeeCut(address(adapter), 0.02e18); // the deploy's cut: every payout below pays it
        pairKey = keccak256(abi.encode(address(adapter), USDC, WETH));
        riskConfig.setPairEnabled(address(adapter), USDC, WETH, true);

        // Bob lends
        deal(USDC, BOB, 5_000_000e6);
        deal(WETH, BOB, 2_000e18);
        vm.startPrank(BOB);
        IERC20(USDC).approve(address(borrowable), type(uint256).max);
        IERC20(WETH).approve(address(borrowable), type(uint256).max);
        borrowable.supply(USDC, 5_000_000e6, BOB);
        borrowable.supply(WETH, 2_000e18, BOB);
        vm.stopPrank();

        // ±10% range around the current price (tick spacing 10)
        (, int24 tick,,,,,) = IUniswapV3Pool(POOL).slot0();
        tickLower = _floorTick(tick - 953);
        tickUpper = _floorTick(tick + 953) + 10;

        // Alice: approvals for the router, which is her operator on the Hub
        deal(USDC, ALICE, 100_000e6);
        deal(WETH, ALICE, 50e18);
        vm.startPrank(ALICE);
        IERC20(USDC).approve(address(senzuRouter), type(uint256).max);
        IERC20(WETH).approve(address(senzuRouter), type(uint256).max);
        collateral.setOperator(address(senzuRouter), true);
        vm.stopPrank();
    }

    /*  ================================================
                            Helpers
        ================================================  */

    /// @dev The pool holds a v3 position's fees and liquidity: between transactions the adapter holds nothing
    modifier booksBalance() {
        _;
        address[2] memory tokens = [WETH, USDC];
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(IERC20(tokens[i]).balanceOf(address(adapter)), 0, "adapter books = balance");
        }
    }

    function _floorTick(int24 t) internal pure returns (int24) {
        int24 r = t / 10 * 10;
        if (t < 0 && t % 10 != 0) r -= 10;
        return r;
    }

    /// @dev Mints with whatever was pushed to the adapter first
    /// @dev Compounding as the router does it (no core compound since 2026-10-15): the holder's fees go straight to
    ///      the adapter, which adds what it holds as liquidity; what doesn't fit is refunded to the holder
    function _compound(address who, uint256 id) internal returns (uint256 added) {
        vm.startPrank(who);
        adapter.collectFees(who, id, address(adapter));
        (added,,) = collateral.increaseLiquidity(who, id, who, "");
        vm.stopPrank();
    }

    function _mintData() internal view returns (bytes memory) {
        return abi.encode(
            UniswapV3Adapter.MintData({
                token0: USDC, token1: WETH, fee: FEE, tickLower: tickLower, tickUpper: tickUpper, liquidity: 0
            })
        );
    }

    /// @dev The router's route through the 0.05% pool
    function _route(address tokenIn, address tokenOut) internal pure returns (bytes memory) {
        return abi.encodePacked(tokenIn, FEE, tokenOut);
    }

    /// @dev "Create Position": 3,000 USDC + 1 WETH of margin, borrow 8,000 USDC, swap half of it into WETH
    function _openPlan() internal view returns (RouterPlan.Plan memory p) {
        p = RouterPlan.pull(p, USDC, 3_000e6);
        p = RouterPlan.pull(p, WETH, 1e18);
        p = RouterPlan.open(p, _mintData(), USDC, WETH);
        p = RouterPlan.borrow(p, 0, USDC, 8_000e6);
        p = RouterPlan.swap(p, USDC, WETH, 4_000e6, 0, _route(USDC, WETH));
        p = RouterPlan.increase(p, 0, RouterPlan.ALL, RouterPlan.ALL, 0, 0);
    }

    function _openLeveraged() internal returns (uint256 id) {
        RouterPlan.Plan memory p = _openPlan();
        vm.prank(ALICE);
        id = senzuRouter.execute(p.actions, p.params, block.timestamp, false);
    }

    function _mockEthPrice(int256 price) internal {
        vm.mockCall(
            ETH_USD,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), price, block.timestamp, block.timestamp, uint80(1))
        );
    }

    /**
     *  @dev A second holder of `id`: units don't transfer, so Carol gets them in a partial liquidation. Alice
     *       borrows 70% of her collateral in USDC, ETH falls at the oracle until she's liquidatable,
     *       Carol repays a quarter of the debt, and the price comes back. Alice keeps the rest of her debt
     */
    function _liquidatePart(uint256 id) internal returns (uint256 debt) {
        debt = collateral.health(ALICE, id).collateralUsdWad * 7 / 10 / 1e12;
        vm.prank(ALICE);
        collateral.borrow(ALICE, id, USDC, debt, ALICE);
        uint256 price = oracle.priceUsd(WETH);
        for (uint256 pct = 95; collateral.health(ALICE, id).minSurplusUsdWad >= 0; pct -= 5) {
            _mockEthPrice(int256(price * pct / 100 / 1e10));
        }
        deal(USDC, CAROL, debt / 4 * 11 / 10); // the repayment and the protocol's share of her bonus
        vm.startPrank(CAROL);
        IERC20(USDC).approve(address(borrowable), type(uint256).max);
        lockLiquidator().liquidate(collateral, ALICE, id, USDC, debt / 4, CAROL);
        vm.stopPrank();
        vm.clearMockedCalls();
        assertGt(collateral.balanceOf(CAROL, id), 0);
    }

    /// @dev Everyone left in `id` but Carol leaves it: Alice repays her debt and redeems every unit
    function _othersLeave(uint256 id) internal returns (uint256 out0, uint256 out1) {
        deal(USDC, ALICE, IERC20(USDC).balanceOf(ALICE) + borrowable.debtOf(ALICE, id, USDC) + 1e6);
        vm.startPrank(ALICE);
        IERC20(USDC).approve(address(borrowable), type(uint256).max);
        borrowable.repay(ALICE, id, USDC, type(uint256).max);
        (out0, out1) = collateral.redeem(ALICE, id, collateral.balanceOf(ALICE, id), ALICE, "");
        vm.stopPrank();
    }

    /// @dev The liquidity of the adapter's pool position for `lpId`'s range (every Senzu position on that range)
    function _rangeLiquidity(uint256 lpId) internal view returns (uint128 liquidity) {
        (, int24 lower, int24 upper) = adapter.positions(lpId);
        (liquidity,,,,) = IUniswapV3Pool(POOL).positions(keccak256(abi.encodePacked(address(adapter), lower, upper)));
    }

    /// @dev Pushes volume through Alice's range: whale swaps back and forth
    function _generateVolume() internal {
        deal(USDC, WHALE, 20_000_000e6);
        vm.startPrank(WHALE);
        IERC20(USDC).approve(SWAP_ROUTER, type(uint256).max);
        IERC20(WETH).approve(SWAP_ROUTER, type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            uint256 out = ISwapRouter02(SWAP_ROUTER)
                .exactInputSingle(ISwapRouter02.ExactInputSingleParams(USDC, WETH, FEE, WHALE, 5_000_000e6, 0, 0));
            ISwapRouter02(SWAP_ROUTER)
                .exactInputSingle(ISwapRouter02.ExactInputSingleParams(WETH, USDC, FEE, WHALE, out, 0, 0));
        }
        vm.stopPrank();
    }

    /*  ================================================
                             Tests
        ================================================  */

    /// @dev A wallet that approved only Permit2 (the real one) supplies with the permit riding in the same call. The
    ///      permit can't be replayed, and its allowance is what the router may pull
    function test_fork_permit2_pullsWithTheWalletsPermit() public {
        SenzuUniswapV3Router r = new SenzuUniswapV3Router(
            address(collateral), WETH, INonfungiblePositionManager(NFPM).factory(), address(0)
        );
        (address owner, uint256 key) = makeAddrAndKey("permit2 owner");
        deal(USDC, owner, 3_000e6);
        vm.prank(owner);
        IERC20(USDC).approve(SafeTransferLib.PERMIT2, type(uint256).max);

        IAllowanceTransfer.PermitBatch memory batch;
        batch.details = new IAllowanceTransfer.PermitDetails[](1);
        batch.details[0] = IAllowanceTransfer.PermitDetails(USDC, 2_000e6, uint48(block.timestamp + 1 days), 0);
        batch.spender = address(r);
        batch.sigDeadline = block.timestamp;
        bytes memory signature = _permit2Sig(key, batch);

        RouterPlan.Plan memory p;
        p = p.permit(batch, signature);
        p = p.pull(USDC, 1_500e6);
        p = p.supply(USDC, type(uint256).max);
        vm.prank(owner);
        r.execute(p.actions, p.params, block.timestamp, false);

        assertEq(IERC20(USDC).balanceOf(owner), 1_500e6);
        assertGt(borrowable.balanceOf(owner, uint256(uint160(USDC))), 0, "the lender shares are the wallet's");
        (uint160 left,,) = IPermit2(SafeTransferLib.PERMIT2).allowance(owner, USDC, address(r));
        assertEq(left, 500e6);

        // The same permit again is skipped; the pull past what's left reverts
        vm.prank(owner);
        vm.expectRevert();
        r.execute(p.actions, p.params, block.timestamp, false);
    }

    function _permit2Sig(uint256 key, IAllowanceTransfer.PermitBatch memory batch)
        internal
        view
        returns (bytes memory)
    {
        bytes32 detailsTypehash = keccak256(
            "PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
        );
        bytes32[] memory hashes = new bytes32[](batch.details.length);
        for (uint256 i; i < hashes.length; ++i) {
            hashes[i] = keccak256(abi.encode(detailsTypehash, batch.details[i]));
        }
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "PermitBatch(PermitDetails[] details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
                ),
                keccak256(abi.encodePacked(hashes)),
                batch.spender,
                batch.sigDeadline
            )
        );
        bytes32 domain = IPermit2Domain(SafeTransferLib.PERMIT2).DOMAIN_SEPARATOR();
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(rr, ss, v);
    }

    function test_fork_oraclePricesAreSane() public view {
        assertApproxEqRel(oracle.priceUsd(WETH), 2690e18, 0.02e18);
        assertApproxEqRel(oracle.priceUsd(USDC), 1e18, 0.01e18);
    }

    /// @dev The adapter mints in the pool itself: no position NFT, its own ledger per Senzu position
    function test_fork_mintsInThePoolWithNoNft() public booksBalance {
        (uint256 id, uint256 lpId) = _mintDirect(ALICE);
        uint256 liquidity = collateral.balanceOf(ALICE, id);

        assertGt(liquidity, 0);
        assertEq(collateral.totalSupply(id), _rangeLiquidity(lpId), "the pool holds exactly this position's liquidity");
        assertEq(adapter.poolId(lpId), bytes32(uint256(uint160(POOL))), "poolId is the pool's address");
        assertEq(
            keccak256(abi.encode(address(adapter), adapter.shape(lpId).token0, adapter.shape(lpId).token1)), pairKey
        );
        Shape memory shape = adapter.shape(lpId);
        assertEq(shape.token0, USDC);
        assertEq(shape.token1, WETH);
        assertEq(shape.liquidity, liquidity);

        // Valued at the oracle: roughly what went in, never slot0
        HealthResult memory h = collateral.health(ALICE, id);
        assertGt(h.collateralUsdWad, 5_000e18);
        assertLt(h.collateralUsdWad, 5_000e18 + 2 * 2800e18);
    }

    /// @dev Only minting: an existing NFT can't come in (it would need its liquidity moved out of the NFPM first)
    function test_fork_existingNftsAreRefused() public booksBalance {
        vm.prank(ALICE);
        vm.expectRevert(); // not MintData: fails to decode
        collateral.open(ALICE, ALICE, abi.encode(uint8(0), abi.encode(uint256(1))));
    }

    /// @dev Two positions on the same range share the adapter's pool position, each counting only its own liquidity
    function test_fork_twoPositionsShareARange() public booksBalance {
        (uint256 a, uint256 lpA) = _mintDirect(ALICE);
        (uint256 b, uint256 lpB) = _mintDirect(BOB);
        assertEq(
            _rangeLiquidity(lpA), collateral.totalSupply(a) + collateral.totalSupply(b), "one pool position for both"
        );
        _generateVolume();
        (uint256 a0, uint256 a1) = adapter.feesOwed(ALICE, a);
        (uint256 b0, uint256 b1) = adapter.feesOwed(BOB, b);
        assertApproxEqRel(a0, b0, 0.001e18, "same liquidity, same fees");
        assertApproxEqRel(a1, b1, 0.001e18);

        // Bob leaves; Alice's liquidity and fees are untouched
        uint256 bobUnits = collateral.balanceOf(BOB, b);
        uint256 usdc = IERC20(USDC).balanceOf(BOB);
        uint256 weth = IERC20(WETH).balanceOf(BOB);
        vm.prank(BOB);
        (uint256 out0, uint256 out1) = collateral.redeem(BOB, b, bobUnits, BOB, "");
        assertEq(_rangeLiquidity(lpB), collateral.totalSupply(a));
        assertEq(IERC20(USDC).balanceOf(BOB) - usdc, out0 + b0, "the redeem paid his fees with his tokens");
        assertEq(IERC20(WETH).balanceOf(BOB) - weth, out1 + b1);
        vm.prank(BOB);
        (uint256 got0, uint256 got1) = adapter.collectFees(BOB, b, BOB);
        assertEq(got0 + got1, 0, "nothing left to collect");
        vm.prank(ALICE);
        (got0, got1) = adapter.collectFees(ALICE, a, ALICE);
        assertApproxEqAbs(got0, a0, 2);
        assertApproxEqAbs(got1, a1, 2);
    }

    function test_fork_openLeveragedInOneTransaction() public booksBalance {
        uint256 usdcBefore = IERC20(USDC).balanceOf(ALICE);
        uint256 wethBefore = IERC20(WETH).balanceOf(ALICE);

        uint256 id = _openLeveraged();

        uint256 lpId = id;
        assertEq(
            collateral.totalSupply(id), _rangeLiquidity(lpId), "position supply == the range's liquidity in the pool"
        );
        assertEq(borrowable.debtOf(ALICE, id, USDC), 8_000e6);

        HealthResult memory h = collateral.health(ALICE, id);
        assertGt(h.healthWad, 1e18);
        // Margin ≈ $5.7k, borrowed $8k: the position holds most of the $13.7k (swap fees, ratio leftovers refunded)
        assertGt(h.collateralUsdWad, 12_000e18);

        // Nothing is left in the router or the adapter
        assertEq(IERC20(USDC).balanceOf(address(senzuRouter)), 0);
        assertEq(IERC20(WETH).balanceOf(address(senzuRouter)), 0);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0);

        // Alice spent at most her margin; leftovers came back
        assertLe(usdcBefore - IERC20(USDC).balanceOf(ALICE), 3_000e6);
        assertLe(wethBefore - IERC20(WETH).balanceOf(ALICE), 1e18);
    }

    /// @notice An open checkpoints the fee growth its mint left on the pool's own record of the range: the same number
    ///         as the adapter computes from the ticks, so a newcomer to a range that already earned is owed nothing
    function test_fork_openInARangeWithFeesOwesTheNewcomerNothing() public booksBalance {
        (uint256 a,) = _mintDirect(ALICE);
        _generateVolume();
        (uint256 a0, uint256 a1) = adapter.feesOwed(ALICE, a);
        assertGt(a0, 0);
        assertGt(a1, 0);

        (uint256 b,) = _mintDirect(BOB);
        (uint256 growth0, uint256 growth1) = adapter.feeGrowth(b);
        assertGt(growth0, 0);
        assertGt(growth1, 0);
        (uint256 b0, uint256 b1) = adapter.feesOwed(BOB, b);
        assertEq(b0, 0);
        assertEq(b1, 0);
        (uint256 after0, uint256 after1) = adapter.feesOwed(ALICE, a);
        assertEq(after0, a0, "Alice keeps what she earned");
        assertEq(after1, a1);
    }

    function test_fork_feesAccrueAndAreCollected() public booksBalance {
        uint256 id = _openLeveraged();
        _generateVolume();

        (uint256 fee0, uint256 fee1) = adapter.feesOwed(ALICE, id);
        assertGt(fee0, 0);
        assertGt(fee1, 0);

        uint256 usdcBefore = IERC20(USDC).balanceOf(ALICE);
        uint256 wethBefore = IERC20(WETH).balanceOf(ALICE);
        (, address dao) = riskConfig.feeCut(address(adapter));
        (uint256 daoUsdc, uint256 daoWeth) = (IERC20(USDC).balanceOf(dao), IERC20(WETH).balanceOf(dao));
        vm.prank(ALICE);
        adapter.collectFees(ALICE, id, ALICE);
        assertEq(IERC20(USDC).balanceOf(ALICE) - usdcBefore, fee0);
        assertEq(IERC20(WETH).balanceOf(ALICE) - wethBefore, fee1);
        // One collect from the pool pays both: the cut is 2% of what was owed, so 2/98 of the holder's
        assertApproxEqAbs(IERC20(USDC).balanceOf(dao) - daoUsdc, fee0 * 2 / 98, 1, "the protocol's cut");
        assertApproxEqAbs(IERC20(WETH).balanceOf(dao) - daoWeth, fee1 * 2 / 98, 1);
    }

    function test_fork_deleverageClosesThePosition() public booksBalance {
        uint256 id = _openLeveraged();
        uint256 usdcBefore = IERC20(USDC).balanceOf(ALICE);

        uint256 weth = _wethInPosition(id);
        RouterPlan.Plan memory p;
        p = RouterPlan.redeem(p, id, RouterPlan.ALL, 0, 0);
        p = RouterPlan.swap(p, WETH, USDC, weth, 0, _route(WETH, USDC));
        p = RouterPlan.repay(p, id, USDC, RouterPlan.ALL);
        vm.prank(ALICE);
        senzuRouter.execute(p.actions, p.params, block.timestamp, false);

        assertEq(collateral.balanceOf(ALICE, id), 0);
        assertEq(borrowable.debtOf(ALICE, id, USDC), 0);
        assertEq(_rangeLiquidity(id), 0);
        // She gets her margin back in USDC, minus swap costs
        assertGt(IERC20(USDC).balanceOf(ALICE) - usdcBefore, 5_000e6);
    }

    /// @dev SWAP_FOR_DEBT on v3: the USDC the redeem falls short of is bought exactly, so
    ///      the close repays everything and returns no USDC beyond the debt (the rest comes back as WETH)
    function test_fork_closeWithSwapForDebt() public booksBalance {
        uint256 id = _openLeveraged();
        uint256 usdcBefore = IERC20(USDC).balanceOf(ALICE);
        uint256 wethBefore = IERC20(WETH).balanceOf(ALICE);
        // The close pays her fees to her wallet, not to the router: the debt is repaid from the liquidity alone
        (uint256 fee0,) = adapter.feesOwed(ALICE, id);

        RouterPlan.Plan memory p;
        p = RouterPlan.redeem(p, id, RouterPlan.ALL, 0, 0);
        p = RouterPlan.swapForDebt(p, id, USDC, WETH, RouterPlan.ALL, _route(WETH, USDC));
        p = RouterPlan.repay(p, id, USDC, RouterPlan.ALL);
        vm.prank(ALICE);
        senzuRouter.execute(p.actions, p.params, block.timestamp, false);

        assertEq(borrowable.debtOf(ALICE, id, USDC), 0);
        assertEq(collateral.balanceOf(ALICE, id), 0);
        assertApproxEqAbs(IERC20(USDC).balanceOf(ALICE), usdcBefore + fee0, 2, "no USDC bought beyond the debt");
        // Margin ≈ $5.7k comes back in WETH
        (, int256 answer,,,) = AggregatorV3Interface(ETH_USD).latestRoundData();
        assertGt((IERC20(WETH).balanceOf(ALICE) - wethBefore) * uint256(answer) / 1e8, 5_000e18);
        assertEq(IERC20(USDC).balanceOf(address(senzuRouter)), 0);
        assertEq(IERC20(WETH).balanceOf(address(senzuRouter)), 0);
    }

    /*  ================================================
                             Swaps
        ================================================  */

    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    function _harness() internal returns (V3RouterHarness) {
        return new V3RouterHarness(address(collateral), WETH, INonfungiblePositionManager(NFPM).factory());
    }

    function test_fork_v3Router_exactInBothWays() public booksBalance {
        V3RouterHarness h = _harness();
        deal(USDC, address(h), 2_690e6);
        uint256 weth = h.exactIn(USDC, WETH, 2_690e6, _route(USDC, WETH));
        assertApproxEqRel(weth, 1e18, 0.02e18, "about 1 ETH at $2,690");

        uint256 usdc = h.exactIn(WETH, USDC, weth, _route(WETH, USDC));
        assertApproxEqRel(usdc, 2_690e6, 0.01e18);
        assertEq(IERC20(USDC).balanceOf(address(h)), usdc);
        assertEq(IERC20(WETH).balanceOf(address(h)), 0, "all of it sold");
    }

    /// @dev Buys exactly the amount out, and spends only what it costs
    function test_fork_v3Router_exactOutSpendsWhatItCosts() public booksBalance {
        V3RouterHarness h = _harness();
        deal(WETH, address(h), 1e18);
        uint256 spent = h.exactOut(WETH, USDC, 1_000e6, _route(WETH, USDC));
        assertEq(IERC20(USDC).balanceOf(address(h)), 1_000e6);
        assertEq(IERC20(WETH).balanceOf(address(h)), 1e18 - spent, "the rest stays");
        assertApproxEqRel(spent, 0.372e18, 0.02e18);
    }

    /// @dev Two v3 pools in a row (USDC → WETH 0.05% → WBTC 0.3%), both ways: nothing stops in between
    function test_fork_v3Router_multiHop() public booksBalance {
        V3RouterHarness h = _harness();
        bytes memory route = abi.encodePacked(USDC, FEE, WETH, uint24(3000), WBTC);
        deal(USDC, address(h), 10_000e6);
        uint256 wbtc = h.exactIn(USDC, WBTC, 10_000e6, route);
        assertGt(wbtc, 0);

        deal(USDC, address(h), 10_000e6);
        uint256 spent = h.exactOut(USDC, WBTC, wbtc / 2, route);
        assertEq(IERC20(WBTC).balanceOf(address(h)), wbtc + wbtc / 2);
        assertApproxEqRel(spent, 5_000e6, 0.01e18);
        assertEq(IERC20(WETH).balanceOf(address(h)), 0, "nothing left in between");
    }

    /// @dev Only the factory's pools (a fee tier with no pool has no code), routes that lead from tokenIn to tokenOut,
    ///      and callbacks from the pool being swapped in
    function test_fork_v3Router_refusesWhatIsntAV3Pool() public booksBalance {
        V3RouterHarness h = _harness();
        deal(USDC, address(h), 1_000e6);
        vm.expectRevert();
        h.exactIn(USDC, WETH, 1_000e6, abi.encodePacked(USDC, uint24(123), WETH));

        vm.expectRevert(ISenzuRouter.SenzuRouter__InvalidRoute.selector);
        h.exactIn(USDC, WETH, 1_000e6, abi.encodePacked(WETH, FEE, USDC));
        vm.expectRevert(ISenzuRouter.SenzuRouter__InvalidRoute.selector);
        h.exactIn(USDC, WETH, 1_000e6, abi.encodePacked(USDC, WETH));

        // The real pool calling outside a swap of this router, or anyone else
        vm.prank(POOL);
        vm.expectRevert(ISenzuRouter.SenzuRouter__NotPool.selector);
        h.uniswapV3SwapCallback(1_000e6, 0, abi.encode(_route(USDC, WETH), uint256(0), false));
    }

    /// @dev The WETH a full redeem returns (from the position at the pool price)
    function _wethInPosition(uint256 id) internal view returns (uint256 weth) {
        uint256 lpId = id;
        (uint160 sqrtPrice,,,,,,) = IUniswapV3Pool(POOL).slot0();
        (, weth) = _amounts(sqrtPrice, adapter.shape(lpId));
    }

    function _amounts(uint160 sqrtPrice, Shape memory shape) internal pure returns (uint256, uint256) {
        return LiquidityAmountsView.get(sqrtPrice, shape.sqrtPaX96, shape.sqrtPbX96, shape.liquidity);
    }

    function test_fork_liquidationPaysOutRealTokens() public booksBalance {
        uint256 id = _openLeveraged();

        // ETH -40% at the oracle (the pool isn't moved: liquidations don't care about slot0). At -25% the position
        // is still healthy: it's all ETH worth about $10.8k against $8k of debt
        _mockEthPrice(1614e8);
        assertTrue(collateral.health(ALICE, id).minSurplusUsdWad < 0);

        deal(USDC, CAROL, 100_000e6);
        vm.startPrank(CAROL);
        IERC20(USDC).approve(address(borrowable), type(uint256).max);
        (uint256 seized,) = lockLiquidator().liquidate(collateral, ALICE, id, USDC, type(uint256).max, CAROL);
        assertGt(seized, 0);

        // Carol redeems the seized liquidity for real tokens from the NFPM
        (uint256 amount0, uint256 amount1) = collateral.redeem(CAROL, id, seized, CAROL, "");
        vm.stopPrank();

        assertGt(amount0 + amount1, 0);
        assertEq(collateral.totalSupply(id), _rangeLiquidity(id));
    }

    /// @dev With the oracle away from the pool (a lagging feed in a fast move), an indebted position still redeems
    function test_fork_redeemWorksWhenThePoolIsAwayFromTheOracle() public booksBalance {
        uint256 id = _openLeveraged();
        (, int256 answer,,,) = AggregatorV3Interface(ETH_USD).latestRoundData();
        _mockEthPrice(answer * 97 / 100); // oracle 3% below the pool

        vm.prank(ALICE);
        (uint256 amount0, uint256 amount1) = collateral.redeem(ALICE, id, 1e9, ALICE, "");
        assertGt(amount0 + amount1, 0);
    }

    /*  ================================================
               Signed operator, compound, unwrap
        ================================================  */

    /// @dev `who` opens 5,000 USDC + 2 WETH in the current range, pushing the tokens to the adapter
    function _mintDirect(address who) internal returns (uint256 id, uint256 lpId) {
        deal(USDC, who, 100_000e6);
        deal(WETH, who, 50e18);
        vm.startPrank(who);
        IERC20(USDC).transfer(address(adapter), 5_000e6);
        IERC20(WETH).transfer(address(adapter), 2e18);
        (id,,,,,) = collateral.open(who, who, _mintData());
        vm.stopPrank();
        lpId = id;
    }

    /// @dev A pool the factory never made (here a fee tier that doesn't exist, then unsorted tokens) is refused by
    ///      name, in the quote too, as on the other adapters
    function test_fork_anUnknownPoolIsUnsupported() public {
        bytes memory noSuchFee = abi.encode(
            UniswapV3Adapter.MintData({
                token0: USDC, token1: WETH, fee: 1234, tickLower: tickLower, tickUpper: tickUpper, liquidity: 1e12
            })
        );
        bytes memory unsorted = abi.encode(
            UniswapV3Adapter.MintData({
                token0: WETH, token1: USDC, fee: FEE, tickLower: tickLower, tickUpper: tickUpper, liquidity: 1e12
            })
        );
        vm.expectRevert(ISenzuAdapter.SenzuAdapter__UnsupportedPool.selector);
        adapter.quoteDeposit(noSuchFee);
        vm.expectRevert(ISenzuAdapter.SenzuAdapter__UnsupportedPool.selector);
        adapter.quoteDeposit(unsorted);
        vm.startPrank(ALICE);
        vm.expectRevert(ISenzuAdapter.SenzuAdapter__UnsupportedPool.selector);
        collateral.open(ALICE, ALICE, noSuchFee);
        vm.expectRevert(ISenzuAdapter.SenzuAdapter__UnsupportedPool.selector);
        collateral.open(ALICE, ALICE, unsorted);
        vm.stopPrank();
    }

    /// @dev An exact liquidity that costs more than was sent reverts by name, as on v4
    function test_fork_anExactOpenNeedsItsTokens() public booksBalance {
        bytes memory exact = abi.encode(
            UniswapV3Adapter.MintData({
                token0: USDC, token1: WETH, fee: FEE, tickLower: tickLower, tickUpper: tickUpper, liquidity: 1e15
            })
        );
        (,, uint256 need0, uint256 need1) = adapter.quoteDeposit(exact);
        assertGt(need0, 1);
        assertGt(need1, 0);
        deal(USDC, ALICE, need0);
        deal(WETH, ALICE, need1);
        vm.startPrank(ALICE);
        IERC20(USDC).transfer(address(adapter), need0 - 1);
        IERC20(WETH).transfer(address(adapter), need1);
        vm.expectRevert(ISenzuAdapter.SenzuAdapter__Underfunded.selector);
        collateral.open(ALICE, ALICE, exact);
        IERC20(USDC).transfer(address(adapter), 1);
        (, uint256 units,,,,) = collateral.open(ALICE, ALICE, exact);
        vm.stopPrank();
        assertEq(units, 1e15, "exactly the quoted amounts");
    }

    /// @dev The units go to `to` and what the mint didn't use to `refundTo`: both are addresses, so only a test catches
    ///      them swapped on the way to the adapter
    function test_fork_openMintsToToAndRefundsToRefundTo() public booksBalance {
        address refundTo = makeAddr("refundTo");
        deal(USDC, ALICE, 5_000e6);
        deal(WETH, ALICE, 2e18);
        vm.startPrank(ALICE);
        IERC20(USDC).transfer(address(adapter), 5_000e6);
        IERC20(WETH).transfer(address(adapter), 2e18);
        (uint256 id, uint256 units,,, uint256 used0, uint256 used1) = collateral.open(ALICE, refundTo, _mintData());
        vm.stopPrank();

        assertEq(collateral.balanceOf(ALICE, id), units);
        assertEq(collateral.balanceOf(refundTo, id), 0);
        assertGt(5_000e6 - used0 + (2e18 - used1), 0, "the mint left something to refund");
        assertEq(IERC20(USDC).balanceOf(refundTo), 5_000e6 - used0);
        assertEq(IERC20(WETH).balanceOf(refundTo), 2e18 - used1);
        assertEq(IERC20(USDC).balanceOf(ALICE) + IERC20(WETH).balanceOf(ALICE), 0);
    }

    /// @dev An increase with nothing to add returns 0 and says nothing
    function test_fork_anEmptyIncreaseDoesNothing() public booksBalance {
        (uint256 id,) = _mintDirect(ALICE);
        uint256 units = collateral.balanceOf(ALICE, id);
        vm.recordLogs();
        vm.prank(ALICE);
        (uint256 added,,) = collateral.increaseLiquidity(ALICE, id, ALICE, "");
        assertEq(added, 0);
        assertEq(vm.getRecordedLogs().length, 0, "no event");
        assertEq(collateral.balanceOf(ALICE, id), units);
    }

    /// @dev A first-time user signs the operator approval; anyone submits it, then the user's first call goes through
    function test_fork_openLeveragedAfterOperatorSig_firstTimeUser() public booksBalance {
        (address user, uint256 key) = makeAddrAndKey("firstTimer");
        deal(USDC, user, 10_000e6);
        deal(WETH, user, 5e18);
        vm.startPrank(user);
        IERC20(USDC).approve(address(senzuRouter), type(uint256).max);
        IERC20(WETH).approve(address(senzuRouter), type(uint256).max);
        vm.stopPrank();
        assertFalse(collateral.isOperator(user, address(senzuRouter)));

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("SetOperator(address owner,address operator,bool approved,uint256 nonce,uint256 deadline)"),
                user,
                address(senzuRouter),
                true,
                collateral.nonces(user),
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 sig) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", collateral.DOMAIN_SEPARATOR(), structHash)));

        collateral.setOperatorBySig(user, address(senzuRouter), true, deadline, v, r, sig);
        RouterPlan.Plan memory p = _openPlan();
        vm.prank(user);
        uint256 id = senzuRouter.execute(p.actions, p.params, deadline, false);

        assertTrue(collateral.isOperator(user, address(senzuRouter)));
        assertEq(borrowable.debtOf(user, id, USDC), 8_000e6);
        assertGt(collateral.health(user, id).healthWad, 1e18);
    }

    function test_fork_compoundAddsRealFeesAsLiquidity() public booksBalance {
        uint256 id = _openLeveraged();
        _generateVolume();
        uint256 before = collateral.balanceOf(ALICE, id);

        uint256 added = _compound(ALICE, id);

        assertGt(added, 0);
        assertEq(collateral.balanceOf(ALICE, id), before + added);
        assertEq(collateral.totalSupply(id), _rangeLiquidity(id));
        (uint256 fee0, uint256 fee1) = adapter.feesOwed(ALICE, id);
        assertEq(fee0 + fee1, 0);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0);
    }

    /// @dev A position is left by redeeming every unit (there is no unwrap): all the tokens come back, with the
    ///      fees the account is owed, so nobody leaves fees behind by closing without collecting
    function test_fork_redeemReturnsTheTokensAndPaysTheFees() public booksBalance {
        (uint256 id,) = _mintDirect(ALICE);

        // Carol gets units in a liquidation, holds them during some volume, then redeems them all
        _liquidatePart(id);
        _generateVolume();
        uint256 carolUnits = collateral.balanceOf(CAROL, id);
        (uint256 carolOwed0, uint256 carolOwed1) = adapter.feesOwed(CAROL, id);
        assertGt(carolOwed0 + carolOwed1, 0);
        uint256 carolUsdc = IERC20(USDC).balanceOf(CAROL);
        uint256 carolWeth = IERC20(WETH).balanceOf(CAROL);
        vm.prank(CAROL);
        (uint256 carolOut0, uint256 carolOut1) = collateral.redeem(CAROL, id, carolUnits, CAROL, "");
        assertApproxEqAbs(IERC20(USDC).balanceOf(CAROL) - carolUsdc, carolOut0 + carolOwed0, 2, "tokens and fees");
        assertApproxEqAbs(IERC20(WETH).balanceOf(CAROL) - carolWeth, carolOut1 + carolOwed1, 2);
        (uint256 left0, uint256 left1) = adapter.feesOwed(CAROL, id);
        assertEq(left0 + left1, 0, "nothing stays owed");

        // Everyone else leaves: Alice's redeem pays out the tokens
        deal(USDC, ALICE, IERC20(USDC).balanceOf(ALICE) + borrowable.debtOf(ALICE, id, USDC) + 1e6);
        vm.startPrank(ALICE);
        IERC20(USDC).approve(address(borrowable), type(uint256).max);
        borrowable.repay(ALICE, id, USDC, type(uint256).max);
        uint256 usdc = IERC20(USDC).balanceOf(ALICE);
        uint256 weth = IERC20(WETH).balanceOf(ALICE);
        (uint256 aliceOwed0, uint256 aliceOwed1) = adapter.feesOwed(ALICE, id);
        assertGt(aliceOwed0 + aliceOwed1, 0);
        (uint256 out0, uint256 out1) = collateral.redeem(ALICE, id, collateral.balanceOf(ALICE, id), ALICE, "");
        vm.stopPrank();
        assertGt(out0 + out1, 0);
        assertApproxEqAbs(IERC20(USDC).balanceOf(ALICE) - usdc, out0 + aliceOwed0, 2, "the tokens back, with her fees");
        assertApproxEqAbs(IERC20(WETH).balanceOf(ALICE) - weth, out1 + aliceOwed1, 2);
        assertEq(collateral.totalSupply(id), 0);

        vm.prank(ALICE);
        (uint256 got0, uint256 got1) = adapter.collectFees(ALICE, id, ALICE);
        assertEq(got0 + got1, 0, "nothing left to collect");
    }

    /// @dev Audit M-01: the range's fees sit in the pool beside the principal a redeem frees. A fee pot short of what
    ///      the holder is owed (forced here) comes out of the fees: `to` gets the whole principal, and the
    ///      redeem returns what it sent
    function test_fork_aShortFeePotTakesFromTheFeesNotThePrincipal() public booksBalance {
        (uint256 id,) = _mintDirect(ALICE);
        _generateVolume();
        uint256 units = collateral.balanceOf(ALICE, id);
        uint256 snapshot = vm.snapshotState();
        vm.prank(ALICE);
        (uint256 principal0,) = collateral.redeem(ALICE, id, units, BOB, "");
        vm.revertToState(snapshot);

        // owed0 is the low half of the checkpoint's third slot (`checkpoints` is the adapter's slot 0)
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(id, keccak256(abi.encode(ALICE, uint256(0)))))) + 2);
        vm.store(address(adapter), slot, bytes32(uint256(vm.load(address(adapter), slot)) + 1000e6));
        (uint256 owed0,) = adapter.feesOwed(ALICE, id);
        uint256 bob = IERC20(USDC).balanceOf(BOB);
        uint256 alice = IERC20(USDC).balanceOf(ALICE);
        vm.prank(ALICE);
        (uint256 out0,) = collateral.redeem(ALICE, id, units, BOB, "");

        assertEq(out0, principal0, "the whole principal");
        assertEq(IERC20(USDC).balanceOf(BOB) - bob, out0, "sent as returned");
        assertLt(IERC20(USDC).balanceOf(ALICE) - alice, owed0 / 100, "the fees are short");
    }

    /// @dev Audit 2026-10-05: anyone can add liquidity to the adapter's position (the pool lets any caller name any
    ///      owner). Valued from the pool's figure, units were worth more than redeem pays, and liquidating such a
    ///      position lost money. Units are valued from the adapter's own ledger
    function test_fork_outsideLiquidityDoesntChangeUnitValue() public booksBalance {
        (uint256 id, uint256 lpId) = _mintDirect(ALICE);
        uint256 units = adapter.units(lpId);
        uint256 valueBefore = collateral.health(ALICE, id).collateralUsdWad;

        // A stranger adds 20% more liquidity to the adapter's range, straight through the pool
        OutsideMinter stranger = new OutsideMinter();
        deal(USDC, address(stranger), 10_000e6);
        deal(WETH, address(stranger), 10e18);
        stranger.mint(IUniswapV3Pool(POOL), address(adapter), tickLower, tickUpper, uint128(units / 5));

        assertGt(_rangeLiquidity(lpId), units, "the pool counts the outside liquidity");
        assertEq(adapter.units(lpId), units, "the adapter does not");
        assertEq(collateral.totalSupply(id), adapter.units(lpId));
        assertEq(collateral.health(ALICE, id).collateralUsdWad, valueBefore);

        // Redeeming every unit still works and leaves the outside liquidity in the pool
        vm.prank(ALICE);
        collateral.redeem(ALICE, id, units, ALICE, "");
        assertEq(adapter.units(lpId), 0);
        assertGt(_rangeLiquidity(lpId), 0);
    }

    /// @dev Audit lead 2026-10-05: in a USDC-only range (above the price), one unit of liquidity is worth 0 of both
    ///      tokens, and a collect of nothing is skipped. The redeem burns the unit and pays nothing
    ///      instead of reverting
    function test_fork_dustRedeemPaysNothingAndDoesNotRevert() public booksBalance {
        (, int24 tick,,,,,) = IUniswapV3Pool(POOL).slot0();
        tickLower = _floorTick(tick) + 100;
        tickUpper = tickLower + 1_000;
        (uint256 id, uint256 lpId) = _mintDirect(ALICE);
        uint256 units = adapter.units(lpId);

        vm.prank(ALICE);
        (uint256 amount0, uint256 amount1) = collateral.redeem(ALICE, id, 1, ALICE, "");
        assertEq(amount0, 0);
        assertEq(amount1, 0);
        assertEq(collateral.balanceOf(ALICE, id), units - 1);
        assertEq(adapter.units(lpId), units - 1);
        assertEq(_rangeLiquidity(lpId), units - 1);
    }

    /*  ================================================
                        Audit 2026-10-06
        ================================================  */

    function _gross(int24 t) internal view returns (uint128 gross) {
        (gross,,,,,,,) = IUniswapV3Pool(POOL).ticks(t);
    }

    /// @dev Audit 2026-10-06 (agent 10's fork PoC): Uniswap resets a tick's fee growth when its last liquidity
    ///      leaves, so an emptied v3 position reads a different growth once refilled. compound let a former holder
    ///      refill one: its fee snapshot underflowed to ~2^128 and it collected every fee left in the NFT, the
    ///      liquidated borrower's included. Only holders compound now, so an emptied position stays empty
    function test_fork_formerHolderCantRefillAnEmptiedPosition() public booksBalance {
        // A range no other liquidity uses: emptying the position clears both its ticks
        while (_gross(tickLower) != 0) tickLower -= 10;
        while (_gross(tickUpper) != 0) tickUpper += 10;
        vm.startPrank(ALICE);
        IERC20(USDC).transfer(address(adapter), 50_000e6);
        IERC20(WETH).transfer(address(adapter), 20e18);
        (uint256 id,,,,,) = collateral.open(ALICE, ALICE, _mintData());
        vm.stopPrank();
        // Carol gets units in a liquidation and holds them while fees accrue, then redeems them all (her fees come
        // with them): a former holder
        _liquidatePart(id);
        _generateVolume();
        uint256 carolUnits = collateral.balanceOf(CAROL, id);
        vm.prank(CAROL);
        collateral.redeem(CAROL, id, carolUnits, CAROL, "");

        _othersLeave(id);
        assertEq(collateral.totalSupply(id), 0, "position emptied");
        assertEq(_gross(tickLower), 0, "lower tick cleared");
        assertEq(_gross(tickUpper), 0, "upper tick cleared");

        // The only way to add is increaseLiquidity, and only holders may
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(ISenzuCollateral.SenzuCollateral__NotAHolder.selector, CAROL, id));
        collateral.increaseLiquidity(CAROL, id, CAROL, "");

        // Nobody is owed anything in it, and nobody collects anything from it
        address[2] memory formerHolders = [CAROL, ALICE];
        for (uint256 i; i < 2; ++i) {
            vm.prank(formerHolders[i]);
            (uint256 got0, uint256 got1) = adapter.collectFees(formerHolders[i], id, formerHolders[i]);
            assertEq(got0 + got1, 0);
        }
    }

    /// @dev Audit 2026-10-06: in range, fees in one token alone add no liquidity and the pool reverts on a zero mint,
    ///      so compounding them failed. Nothing is added now, and the fees go back to the holder
    function test_fork_compoundOfOneSidedFeesInRangeRefunds() public booksBalance {
        vm.startPrank(ALICE);
        IERC20(USDC).transfer(address(adapter), 50_000e6);
        IERC20(WETH).transfer(address(adapter), 20e18);
        (uint256 id,,,,,) = collateral.open(ALICE, ALICE, _mintData());
        vm.stopPrank();

        // Volume one way only, so the fees are all USDC
        deal(USDC, WHALE, 1_000_000e6);
        vm.startPrank(WHALE);
        IERC20(USDC).approve(SWAP_ROUTER, type(uint256).max);
        ISwapRouter02(SWAP_ROUTER)
            .exactInputSingle(ISwapRouter02.ExactInputSingleParams(USDC, WETH, FEE, WHALE, 1_000_000e6, 0, 0));
        vm.stopPrank();
        (uint256 owed0, uint256 owed1) = adapter.feesOwed(ALICE, id);
        assertGt(owed0, 0);
        assertEq(owed1, 0);

        uint256 usdcBefore = IERC20(USDC).balanceOf(ALICE);
        assertEq(_compound(ALICE, id), 0, "one token alone fits nothing in range");
        assertApproxEqAbs(IERC20(USDC).balanceOf(ALICE) - usdcBefore, owed0, 2, "the fees go back to Alice");
    }

    /// @dev The router pushes a mint's tokens to the adapter, which mints with everything it holds: a token anyone sent
    ///      it first is a gift to that mint (minted or refunded), and nothing stays behind
    function test_fork_strayTokenInTheAdapterGoesToTheNextMint() public booksBalance {
        deal(USDC, WHALE, 1e6);
        vm.prank(WHALE);
        IERC20(USDC).transfer(address(adapter), 1e6);

        uint256 id = _openLeveraged();
        assertGt(collateral.balanceOf(ALICE, id), 0);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0, "the stray USDC went into the mint or back");
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0);
        assertEq(IERC20(USDC).balanceOf(address(senzuRouter)), 0);
        assertEq(IERC20(WETH).balanceOf(address(senzuRouter)), 0);
    }

    /// @dev Audit 2026-10-06: the adapter refunds every token it holds, so one wei of the unused token that anyone
    ///      sent it came back to the router on a one-sided INCREASE, and `before - after` underflowed
    function test_fork_strayTokenInTheAdapterDoesntBlockAnIncrease() public booksBalance {
        // A WETH-only range below the price
        (, int24 tick,,,,,) = IUniswapV3Pool(POOL).slot0();
        tickUpper = _floorTick(tick) - 100;
        tickLower = tickUpper - 1_000;
        RouterPlan.Plan memory p;
        p = RouterPlan.pull(p, WETH, 2e18);
        p = RouterPlan.open(p, _mintData(), USDC, WETH);
        vm.prank(ALICE);
        uint256 id = senzuRouter.execute(p.actions, p.params, block.timestamp, false);
        uint256 units = collateral.balanceOf(ALICE, id);

        deal(USDC, WHALE, 1);
        vm.prank(WHALE);
        IERC20(USDC).transfer(address(adapter), 1);

        RouterPlan.Plan memory q;
        q = RouterPlan.pull(q, WETH, 1e18);
        q = RouterPlan.increase(q, id, 0, RouterPlan.ALL, 0, 0);
        vm.prank(ALICE);
        senzuRouter.execute(q.actions, q.params, block.timestamp, false);
        assertGt(collateral.balanceOf(ALICE, id), units);
        assertEq(IERC20(USDC).balanceOf(address(senzuRouter)), 0, "the stray wei is swept on");
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
        return (USDC, WETH, 5_000e6, 2e18);
    }

    function _suiteMintData() internal view override returns (bytes memory) {
        return _mintData();
    }

    function _suiteGenerateFees() internal override {
        _generateVolume();
    }

    function _suiteLiquidatePart(uint256 id) internal override returns (uint256) {
        _liquidatePart(id);
        return collateral.balanceOf(CAROL, id);
    }

    function _suiteLiquidateFull(uint256 id) internal override returns (uint256 seized) {
        uint256 debt = collateral.health(ALICE, id).collateralUsdWad * 7 / 10 / 1e12;
        vm.prank(ALICE);
        collateral.borrow(ALICE, id, USDC, debt, ALICE);
        _mockEthPrice(int256(oracle.priceUsd(WETH) * 30 / 100 / 1e10));
        deal(USDC, CAROL, debt * 2);
        vm.startPrank(CAROL);
        IERC20(USDC).approve(address(borrowable), type(uint256).max);
        (seized,) = lockLiquidator().liquidate(collateral, ALICE, id, USDC, type(uint256).max, CAROL);
        vm.stopPrank();
        vm.clearMockedCalls();
    }

    function _suiteCheckBooks() internal view override {
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0, "adapter books = balance");
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0, "adapter books = balance");
    }
}

import {ISenzuCollateral} from "../../src/interfaces/ISenzuCollateral.sol";
import {ISenzuFactory} from "../../src/interfaces/ISenzuFactory.sol";
import {ISenzuRouter} from "../../src/interfaces/ISenzuRouter.sol";
import {LiquidityAmounts} from "../../src/libraries/uniswap/LiquidityAmounts.sol";
import {BorrowableDeployer} from "../../src/modules/deployers/BorrowableDeployer.sol";
import {CollateralDeployer} from "../../src/modules/deployers/CollateralDeployer.sol";
import {lockLiquidator} from "../utils/LockLiquidator.sol";

library LiquidityAmountsView {
    function get(uint160 sqrtPrice, uint160 a, uint160 b, uint128 liquidity) internal pure returns (uint256, uint256) {
        return LiquidityAmounts.getAmountsForLiquidity(sqrtPrice, a, b, liquidity);
    }
}

/// @dev Adds liquidity to any owner's range straight through the pool, paying from its own balance
contract OutsideMinter {
    function mint(IUniswapV3Pool pool, address owner, int24 tickLower, int24 tickUpper, uint128 liquidity) external {
        pool.mint(owner, tickLower, tickUpper, liquidity, abi.encode(pool.token0(), pool.token1()));
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        (address token0, address token1) = abi.decode(data, (address, address));
        if (amount0Owed > 0) IERC20(token0).transfer(msg.sender, amount0Owed);
        if (amount1Owed > 0) IERC20(token1).transfer(msg.sender, amount1Owed);
    }
}
