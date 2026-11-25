// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISenzuOracle} from "../src/interfaces/ISenzuOracle.sol";
import {SenzuFactory} from "../src/modules/SenzuFactory.sol";
import {SenzuOracle} from "../src/modules/SenzuOracle.sol";
import {BorrowableDeployer} from "../src/modules/deployers/BorrowableDeployer.sol";
import {CollateralDeployer} from "../src/modules/deployers/CollateralDeployer.sol";
import {MockAggregator, MockERC20, MockStock} from "./mocks/Mocks.sol";
import {Test} from "forge-std/Test.sol";

contract SenzuOracleTest is Test {
    SenzuFactory factory;
    SenzuOracle oracle;
    MockERC20 weth;
    MockAggregator ethFeed;

    function setUp() public {
        vm.warp(1_000_000);
        factory = new SenzuFactory(
            address(this),
            address(0xBEEF),
            address(0xDA0),
            address(new BorrowableDeployer()),
            address(new CollateralDeployer())
        );
        oracle = new SenzuOracle(address(factory));
        weth = new MockERC20("WETH", 18);
        ethFeed = new MockAggregator(8, 2000e8);
    }

    function test_priceScaledToWad() public {
        oracle.addFeed(address(weth), address(ethFeed), 1 hours);
        assertEq(oracle.priceUsd(address(weth)), 2000e18);
        (address aggregator, uint32 heartbeat, uint8 tokenDecimals) = oracle.feedOf(address(weth));
        assertEq(aggregator, address(ethFeed));
        assertEq(heartbeat, 1 hours);
        assertEq(tokenDecimals, 18);
    }

    function test_addFeed_onlyAdmin() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(ISenzuOracle.SenzuOracle__NotAdmin.selector);
        oracle.addFeed(address(weth), address(ethFeed), 1 hours);
    }

    function test_addFeed_writeOnce() public {
        oracle.addFeed(address(weth), address(ethFeed), 1 hours);
        vm.expectRevert(abi.encodeWithSelector(ISenzuOracle.SenzuOracle__FeedAlreadySet.selector, address(weth)));
        oracle.addFeed(address(weth), address(ethFeed), 1 hours);
    }

    function test_revertsWithoutFeed() public {
        vm.expectRevert(abi.encodeWithSelector(ISenzuOracle.SenzuOracle__FeedNotSet.selector, address(weth)));
        oracle.priceUsd(address(weth));
    }

    function test_revertsWhenStale() public {
        oracle.addFeed(address(weth), address(ethFeed), 1 hours);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert(abi.encodeWithSelector(ISenzuOracle.SenzuOracle__StalePrice.selector, address(weth)));
        oracle.priceUsd(address(weth));
    }

    function test_revertsOnStaleRound() public {
        oracle.addFeed(address(weth), address(ethFeed), 1 hours);
        ethFeed.setRounds(5, 4);
        vm.expectRevert(abi.encodeWithSelector(ISenzuOracle.SenzuOracle__StalePrice.selector, address(weth)));
        oracle.priceUsd(address(weth));
    }

    function test_revertsOnNonPositivePrice() public {
        oracle.addFeed(address(weth), address(ethFeed), 1 hours);
        ethFeed.set(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ISenzuOracle.SenzuOracle__InvalidPrice.selector, address(weth)));
        oracle.priceUsd(address(weth));
    }

    /*  ================================================
                       Ratio feeds (WBTC)
        ================================================  */

    function _wbtc() internal returns (MockERC20 wbtc, MockAggregator btcFeed, MockAggregator ratioFeed) {
        wbtc = new MockERC20("WBTC", 8);
        btcFeed = new MockAggregator(8, 80_000e8);
        ratioFeed = new MockAggregator(8, 0.995e8); // WBTC at a 0.5% discount to BTC
        oracle.addFeedWithRatio(address(wbtc), address(btcFeed), 1 hours, address(ratioFeed), 1 days);
    }

    function test_ratioFeed_multipliesBothFeeds() public {
        (MockERC20 wbtc,,) = _wbtc();
        assertEq(oracle.priceUsd(address(wbtc)), 79_600e18);
        (uint256 price, uint8 decimals) = oracle.priceWithDecimals(address(wbtc));
        assertEq(price, 79_600e18);
        assertEq(decimals, 8);
    }

    /// @dev A price under a wei per whole token would make a debt worth nothing
    function test_ratioFeed_aPriceRoundingToZeroReverts() public {
        MockERC20 dust = new MockERC20("DUST", 18);
        oracle.addFeedWithRatio(
            address(dust), address(new MockAggregator(18, 1)), 1 hours, address(new MockAggregator(18, 0.5e18)), 1 days
        );
        vm.expectRevert(abi.encodeWithSelector(ISenzuOracle.SenzuOracle__InvalidPrice.selector, address(dust)));
        oracle.priceUsd(address(dust));
    }

    function test_ratioFeed_eachFeedHasItsOwnHeartbeat() public {
        (MockERC20 wbtc, MockAggregator btcFeed, MockAggregator ratioFeed) = _wbtc();

        // 2 hours on: BTC/USD (1h heartbeat) is stale, the ratio (24h) is not
        vm.warp(block.timestamp + 2 hours);
        ratioFeed.set(0.995e8, block.timestamp - 2 hours);
        vm.expectRevert(abi.encodeWithSelector(ISenzuOracle.SenzuOracle__StalePrice.selector, address(wbtc)));
        oracle.priceUsd(address(wbtc));

        btcFeed.set(80_000e8, block.timestamp);
        assertEq(oracle.priceUsd(address(wbtc)), 79_600e18);

        // A day later with a fresh BTC price: the ratio is stale
        vm.warp(block.timestamp + 1 days + 1);
        btcFeed.set(80_000e8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ISenzuOracle.SenzuOracle__StalePrice.selector, address(wbtc)));
        oracle.priceUsd(address(wbtc));
    }

    function test_ratioFeed_invalidAnswerReverts() public {
        (MockERC20 wbtc,, MockAggregator ratioFeed) = _wbtc();
        ratioFeed.set(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ISenzuOracle.SenzuOracle__InvalidPrice.selector, address(wbtc)));
        oracle.priceUsd(address(wbtc));
    }

    function test_ratioFeed_writeOnceAndAdminOnly() public {
        (MockERC20 wbtc, MockAggregator btcFeed, MockAggregator ratioFeed) = _wbtc();
        (address ratio, uint32 heartbeat) = oracle.ratioFeedOf(address(wbtc));
        assertEq(ratio, address(ratioFeed));
        assertEq(heartbeat, 1 days);
        (ratio,) = oracle.ratioFeedOf(address(weth));
        assertEq(ratio, address(0), "plain feeds have no ratio");

        vm.expectRevert(abi.encodeWithSelector(ISenzuOracle.SenzuOracle__FeedAlreadySet.selector, address(wbtc)));
        oracle.addFeedWithRatio(address(wbtc), address(btcFeed), 1 hours, address(ratioFeed), 1 days);

        MockERC20 other = new MockERC20("OTHER", 18);
        vm.prank(address(0xBAD));
        vm.expectRevert(ISenzuOracle.SenzuOracle__NotAdmin.selector);
        oracle.addFeedWithRatio(address(other), address(btcFeed), 1 hours, address(ratioFeed), 1 days);

        vm.expectRevert(abi.encodeWithSelector(ISenzuOracle.SenzuOracle__InvalidFeed.selector, address(other)));
        oracle.addFeedWithRatio(address(other), address(btcFeed), 1 hours, address(0), 1 days);
    }

    /*  ================================================
                             stocks
        ================================================  */

    /// @dev A stock token can pause its own price (corporate actions): while it says paused, there is no price
    function test_pausableFeed_noPriceWhilePaused() public {
        MockStock nvda = new MockStock("NVDA");
        MockAggregator nvdaFeed = new MockAggregator(8, 180e8);
        oracle.addPausableFeed(address(nvda), address(nvdaFeed), 1 days);
        assertTrue(oracle.isPausable(address(nvda)));
        assertFalse(oracle.isPausable(address(weth)));
        assertEq(oracle.priceUsd(address(nvda)), 180e18);

        nvda.setOraclePaused(true);
        vm.expectRevert(abi.encodeWithSelector(ISenzuOracle.SenzuOracle__PricePaused.selector, address(nvda)));
        oracle.priceUsd(address(nvda));
        vm.expectRevert(abi.encodeWithSelector(ISenzuOracle.SenzuOracle__PricePaused.selector, address(nvda)));
        oracle.priceWithDecimals(address(nvda));

        nvda.setOraclePaused(false);
        assertEq(oracle.priceUsd(address(nvda)), 180e18);
    }

    /// @dev Fail closed: a pausable token that stops answering has no price
    function test_pausableFeed_noAnswerMeansNoPrice() public {
        MockStock nvda = new MockStock("NVDA");
        oracle.addPausableFeed(address(nvda), address(new MockAggregator(8, 180e8)), 1 days);
        vm.mockCallRevert(address(nvda), abi.encodeWithSignature("oraclePaused()"), "");
        vm.expectRevert();
        oracle.priceUsd(address(nvda));
    }

    /// @dev Only a token that can answer is added as pausable (it would read as paused forever); admin only,
    ///      write-once like every feed
    function test_pausableFeed_onlyForATokenThatAnswers() public {
        vm.expectRevert();
        oracle.addPausableFeed(address(weth), address(ethFeed), 1 hours);

        MockStock nvda = new MockStock("NVDA");
        MockAggregator nvdaFeed = new MockAggregator(8, 180e8);
        vm.prank(address(0xBAD));
        vm.expectRevert(ISenzuOracle.SenzuOracle__NotAdmin.selector);
        oracle.addPausableFeed(address(nvda), address(nvdaFeed), 1 days);

        oracle.addPausableFeed(address(nvda), address(nvdaFeed), 1 days);
        vm.expectRevert(abi.encodeWithSelector(ISenzuOracle.SenzuOracle__FeedAlreadySet.selector, address(nvda)));
        oracle.addPausableFeed(address(nvda), address(nvdaFeed), 1 days);
    }
}
