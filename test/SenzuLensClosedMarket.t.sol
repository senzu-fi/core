// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISenzuLens} from "../src/interfaces/ISenzuLens.sol";
import {ISenzuOracle} from "../src/interfaces/ISenzuOracle.sol";
import {SenzuLens} from "../src/periphery/SenzuLens.sol";
import {SenzuPreviews} from "../src/periphery/SenzuPreviews.sol";
import {MockAggregator, MockERC20, MockStock} from "./mocks/Mocks.sol";
import {HubFixture} from "./utils/HubFixture.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice The lens never fails on a closed market: a stock the oracle refuses (stale over the weekend, or paused)
///         reads at its feed's last answer, flagged `stale`, in every view; what the oracle refuses for any other
///         reason still reverts, and the previews keep the oracle's refusal, as the core would
contract SenzuLensClosedMarketTest is HubFixture {
    SenzuLens lens;
    MockStock nvda;
    MockAggregator nvdaFeed;
    uint256 stockId; // Carol's NVDA/USDC position, borrowing USDC and NVDA

    function setUp() public override {
        super.setUp();
        lens = new SenzuLens(address(collateral));
        nvda = new MockStock("NVDA");
        nvdaFeed = new MockAggregator(8, 180e8);
        oracle.addPausableFeed(address(nvda), address(nvdaFeed), 1 days);
        borrowable.createMarket(address(nvda), 0.1e18);
        riskConfig.setTokenRisk(address(adapter), address(nvda), 1.33e18, 1.05e18, true);
        riskConfig.setPairEnabled(address(adapter), address(nvda), address(usdc), true);

        nvda.mint(BOB, 10_000e18);
        vm.startPrank(BOB);
        nvda.approve(address(borrowable), type(uint256).max);
        borrowable.supply(address(nvda), 10_000e18, BOB);
        vm.stopPrank();

        bytes memory data =
            abi.encode(address(nvda), address(usdc), TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, uint128(1e15));
        vm.startPrank(CAROL);
        (stockId,,,,,) = collateral.open(CAROL, CAROL, data);
        collateral.borrow(CAROL, stockId, address(usdc), 5_000e6, CAROL);
        collateral.borrow(CAROL, stockId, address(nvda), 10e18, CAROL);
        vm.stopPrank();
    }

    /// @dev Stale without time passing (an unanswered round), so nothing else changes between the two reads
    function _closeMarket() internal {
        nvdaFeed.setRounds(2, 1);
    }

    function _market(address asset) internal view returns (ISenzuLens.MarketView memory m) {
        ISenzuLens.MarketView[] memory all = lens.getMarkets();
        for (uint256 i; i < all.length; ++i) {
            if (all[i].asset == asset) return all[i];
        }
    }

    function test_openMarket_notStale() public view {
        (uint256 priceWad, uint8 decimals, bool stale) = lens.price(address(nvda));
        assertEq(priceWad, 180e18);
        assertEq(decimals, 18);
        assertFalse(stale);
        assertFalse(lens.getPosition(CAROL, stockId).stale);
        assertFalse(_market(address(nvda)).stale);
    }

    function test_staleFeed_everyViewAtTheLastAnswer() public {
        ISenzuLens.PositionView memory open = lens.getPosition(CAROL, stockId);
        ISenzuLens.PairView memory pairOpen = lens.getPair(address(nvda), address(usdc));
        _closeMarket();
        vm.expectRevert(abi.encodeWithSelector(ISenzuOracle.SenzuOracle__StalePrice.selector, address(nvda)));
        oracle.priceUsd(address(nvda));

        ISenzuLens.MarketView memory m = _market(address(nvda));
        assertEq(m.priceWad, 180e18);
        assertTrue(m.stale);
        assertFalse(_market(address(usdc)).stale);

        ISenzuLens.PairView memory pair = lens.getPair(address(nvda), address(usdc));
        assertEq(pair.price0Wad, pairOpen.price0Wad);
        assertEq(pair.oracleSqrtPriceX96, pairOpen.oracleSqrtPriceX96);
        assertTrue(pair.stale0);
        assertFalse(pair.stale1);

        ISenzuLens.PositionView memory closed = lens.getPosition(CAROL, stockId);
        assertTrue(closed.stale);
        assertEq(closed.healthWad, open.healthWad, "health at the last answer, as before it went stale");
        assertEq(closed.collateralUsdWad, open.collateralUsdWad);
        assertEq(closed.debtUsdWad, open.debtUsdWad);
        assertEq(closed.liquidation.lowerWad, open.liquidation.lowerWad);

        assertGt(lens.getLender(BOB).length, 0);
    }

    function test_pausedToken_readsAtTheLastAnswer() public {
        nvda.setOraclePaused(true);
        (uint256 priceWad,, bool stale) = lens.price(address(nvda));
        assertEq(priceWad, 180e18);
        assertTrue(stale);
        assertTrue(lens.getPosition(CAROL, stockId).stale);
    }

    /// @dev Only the views read a last answer: the previews run at the oracle's prices, refused like the core's
    function test_previews_keepTheOraclesRefusal() public {
        SenzuPreviews previews = new SenzuPreviews(address(collateral));
        _closeMarket();
        vm.expectRevert(abi.encodeWithSelector(ISenzuOracle.SenzuOracle__StalePrice.selector, address(nvda)));
        previews.maxBorrow(CAROL, stockId, address(usdc));
    }

    function test_invalidAnswer_revertsWithTheOraclesError() public {
        nvdaFeed.set(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ISenzuOracle.SenzuOracle__InvalidPrice.selector, address(nvda)));
        lens.price(address(nvda));
        vm.expectRevert(abi.encodeWithSelector(ISenzuOracle.SenzuOracle__InvalidPrice.selector, address(nvda)));
        lens.getMarkets();
    }

    function test_noFeed_revertsWithTheOraclesError() public {
        address unlisted = address(new MockERC20("X", 18));
        vm.expectRevert(abi.encodeWithSelector(ISenzuOracle.SenzuOracle__FeedNotSet.selector, unlisted));
        lens.price(unlisted);
    }

    /// @dev A ratio feed's last answer is priced as the oracle prices a live one (WBTC = WBTC/BTC × BTC/USD)
    function test_ratioFeed_lastAnswerMatchesTheOraclesMath() public {
        MockERC20 wbtc = new MockERC20("WBTC", 8);
        MockAggregator btcUsd = new MockAggregator(8, 95_000e8);
        MockAggregator wbtcBtc = new MockAggregator(18, 0.9987e18);
        oracle.addFeedWithRatio(address(wbtc), address(btcUsd), 1 days, address(wbtcBtc), 1 days);
        (uint256 live,,) = lens.price(address(wbtc));
        assertEq(live, oracle.priceUsd(address(wbtc)));

        wbtcBtc.setRounds(2, 1);
        (uint256 last, uint8 decimals, bool stale) = lens.price(address(wbtc));
        assertTrue(stale);
        assertEq(last, live);
        assertEq(decimals, 8);
    }
}
