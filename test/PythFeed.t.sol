// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {MockERC20, MockPyth, MockSwapRouter, MockWETH} from "./mocks/Mocks.sol";
import {HubFixture} from "./utils/HubFixture.sol";
import {RouterPlan} from "./utils/RouterPlan.sol";
import {ISenzuOracle} from "src/interfaces/ISenzuOracle.sol";
import {PythFeed} from "src/modules/PythFeed.sol";

/// @notice A token Chainlink doesn't price is listed through a PythFeed: Pyth Core's price read as a Chainlink
///         aggregator, kept fresh by whoever acts (the router's PostPrices)
contract PythFeedTest is HubFixture {
    using RouterPlan for RouterPlan.Plan;

    bytes32 constant ID = keccak256("THIN/USD");

    MockPyth pyth;
    PythFeed feed;
    MockERC20 thin;
    MockSwapRouter senzuRouter;

    function setUp() public override {
        super.setUp();
        pyth = new MockPyth();
        _post(10e8, 0, block.timestamp);
        feed = new PythFeed(address(pyth), ID, "THIN / USD");

        thin = new MockERC20("THIN", 18);
        oracle.addFeed(address(thin), address(feed), uint32(feed.MAX_AGE()));
        borrowable.createMarket(address(thin), 0.1e18);
        riskConfig.setTokenRisk(address(adapter), address(thin), 1.3e18, 1.05e18, true);
        riskConfig.setLiquid(address(adapter), address(thin));

        thin.mint(BOB, 10_000e18);
        vm.startPrank(BOB);
        thin.approve(address(borrowable), type(uint256).max);
        borrowable.supply(address(thin), 10_000e18, BOB);
        vm.stopPrank();

        vm.etch(address(weth), address(new MockWETH()).code);
        senzuRouter = new MockSwapRouter(address(collateral), address(weth), address(pyth));
        vm.prank(ALICE);
        collateral.setOperator(address(senzuRouter), true);
    }

    function _post(int64 price, uint64 conf, uint256 publishTime) internal {
        pyth.set(ID, price, conf, -8, publishTime, false);
    }

    function _update(int64 price, uint256 publishTime) internal pure returns (bytes[] memory updates) {
        updates = new bytes[](1);
        updates[0] = abi.encode(ID, price, uint64(0), int32(-8), publishTime);
    }

    function _stale() internal view returns (bytes memory) {
        return abi.encodeWithSelector(ISenzuOracle.SenzuOracle__StalePrice.selector, address(thin));
    }

    /*  ================================================
                        As an aggregator
        ================================================  */

    function test_readsAsAChainlinkRound() public view {
        assertEq(feed.decimals(), 8);
        assertEq(feed.description(), "THIN / USD");
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        assertEq(answer, 10e8);
        assertEq(updatedAt, block.timestamp);
        assertEq(startedAt, updatedAt);
        assertEq(roundId, block.timestamp);
        assertEq(answeredInRound, roundId);
        assertEq(oracle.priceUsd(address(thin)), 10e18);
    }

    /// @notice Chainlink's whole interface: Pyth Core keeps only the newest price, so there is no past round to read
    function test_hasNoPastRounds() public {
        assertEq(feed.version(), 1);
        vm.expectRevert(PythFeed.PythFeed__NoRoundHistory.selector);
        feed.getRoundData(uint80(block.timestamp));
    }

    /// @dev The oracle's heartbeat judges the age: usable for MAX_AGE, stale a second later
    function test_usableForMaxAge_thenStale() public {
        vm.warp(block.timestamp + 60);
        assertEq(oracle.priceUsd(address(thin)), 10e18);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(_stale());
        oracle.priceUsd(address(thin));
        // The feed itself still answers with the old round, as a Chainlink feed does
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(answer, 10e8);
        assertEq(updatedAt, block.timestamp - 61);
    }

    /// @dev Pyth's clock can run ahead of the chain's: such a price is read as of now, up to MAX_AGE ahead
    function test_aPriceAheadOfTheBlock() public {
        _post(11e8, 0, block.timestamp + 60);
        (,,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, block.timestamp);
        assertEq(oracle.priceUsd(address(thin)), 11e18);

        _post(11e8, 0, block.timestamp + 61);
        vm.expectRevert(PythFeed.PythFeed__PriceAhead.selector);
        oracle.priceUsd(address(thin));
    }

    function test_confidenceWiderThanTheBound_reverts() public {
        _post(10e8, 0.2e8, block.timestamp); // 2% exactly
        assertEq(oracle.priceUsd(address(thin)), 10e18);
        _post(10e8, 0.2e8 + 1, block.timestamp);
        vm.expectRevert(PythFeed.PythFeed__UncertainPrice.selector);
        oracle.priceUsd(address(thin));
    }

    function test_aPriceThatIsNotPositive_isTheOraclesToRefuse() public {
        _post(0, 0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ISenzuOracle.SenzuOracle__InvalidPrice.selector, address(thin)));
        oracle.priceUsd(address(thin));
        _post(-1, 0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ISenzuOracle.SenzuOracle__InvalidPrice.selector, address(thin)));
        oracle.priceUsd(address(thin));
    }

    /// @dev The oracle can't replace a feed, so a changed exponent must not stop it: the price keeps its scale
    function test_aChangedExponent_isRescaled() public {
        assertEq(oracle.priceUsd(address(thin)), 10e18);
        pyth.set(ID, 10e6, 0, -6, block.timestamp, false);
        assertEq(oracle.priceUsd(address(thin)), 10e18);
        pyth.set(ID, 10e10, 0, -10, block.timestamp, false);
        assertEq(oracle.priceUsd(address(thin)), 10e18);
        pyth.set(ID, 10, 0, 0, block.timestamp, false);
        assertEq(oracle.priceUsd(address(thin)), 10e18);

        // The confidence check reads the same at any scale: 3% of the price is too wide at -10 as at -8
        pyth.set(ID, 10e10, 0.3e10, -10, block.timestamp, false);
        vm.expectRevert(PythFeed.PythFeed__UncertainPrice.selector);
        oracle.priceUsd(address(thin));
    }

    function test_anExponentOutOfRange_reverts() public {
        pyth.set(ID, 1, 0, 1, block.timestamp, false);
        vm.expectRevert(PythFeed.PythFeed__InvalidExponent.selector);
        oracle.priceUsd(address(thin));
        pyth.set(ID, 1, 0, -19, block.timestamp, false);
        vm.expectRevert(PythFeed.PythFeed__InvalidExponent.selector);
        oracle.priceUsd(address(thin));
    }

    function test_constructor_needsThePostedFeedAndAUsableExponent() public {
        vm.expectRevert(MockPyth.PriceFeedNotFound.selector);
        new PythFeed(address(pyth), keccak256("NONE/USD"), "NONE / USD");

        pyth.set(keccak256("UP/USD"), 1, 0, 1, block.timestamp, false);
        vm.expectRevert(PythFeed.PythFeed__InvalidFeed.selector);
        new PythFeed(address(pyth), keccak256("UP/USD"), "UP / USD");

        pyth.set(keccak256("DEEP/USD"), 1, 0, -19, block.timestamp, false);
        vm.expectRevert(PythFeed.PythFeed__InvalidFeed.selector);
        new PythFeed(address(pyth), keccak256("DEEP/USD"), "DEEP / USD");
    }

    /// @dev Listing needs the feed posted once, at any age
    function test_listing_worksOnAnOldStoredPrice() public {
        bytes32 other = keccak256("OLD/USD");
        pyth.set(other, 5e8, 0, -8, block.timestamp - 5 days, false);
        MockERC20 old = new MockERC20("OLD", 18);
        PythFeed oldFeed = new PythFeed(address(pyth), other, "OLD / USD");
        oracle.addFeed(address(old), address(oldFeed), uint32(oldFeed.MAX_AGE()));
        vm.expectRevert(abi.encodeWithSelector(ISenzuOracle.SenzuOracle__StalePrice.selector, address(old)));
        oracle.priceUsd(address(old));
    }

    /*  ================================================
                       Through the router
        ================================================  */

    /// @dev Nothing posted for ten minutes: no price, no borrow. PostPrices first makes the same call work, while
    ///      the Chainlink-priced tokens need nothing posted
    function test_postPrices_firstMakesTheCallsPriceFresh() public {
        vm.warp(block.timestamp + 10 minutes);
        RouterPlan.Plan memory p;
        p = p.borrow(id, address(thin), 10e18);
        vm.prank(ALICE);
        vm.expectRevert(_stale());
        senzuRouter.execute(p.actions, p.params, block.timestamp, false);

        RouterPlan.Plan memory q;
        q = q.postPrices(_update(12e8, block.timestamp));
        q = q.borrow(id, address(thin), 10e18);
        vm.prank(ALICE);
        senzuRouter.execute(q.actions, q.params, block.timestamp, false);
        assertEq(borrowable.debtOf(ALICE, id, address(thin)), 10e18);
        assertEq(oracle.priceUsd(address(thin)), 12e18);
    }

    /// @dev Where Pyth charges for updates, the fee comes from the call's ETH; the rest goes back
    function test_postPrices_paysPythsFeeFromTheCallsEth() public {
        vm.warp(block.timestamp + 10 minutes);
        pyth.setFee(1 gwei);
        vm.deal(address(weth), 1e18); // the mock WETH pays its unwraps from its own ETH
        vm.deal(ALICE, 1e18);

        RouterPlan.Plan memory p;
        p = p.postPrices(_update(12e8, block.timestamp));
        p = p.borrow(id, address(thin), 10e18);
        vm.prank(ALICE);
        senzuRouter.execute{value: 1e18}(p.actions, p.params, block.timestamp, true);

        assertEq(address(pyth).balance, 1 gwei);
        assertEq(ALICE.balance, 1e18 - 1 gwei);
        assertEq(borrowable.debtOf(ALICE, id, address(thin)), 10e18);
    }

    /// @dev An older update than the stored price changes nothing: a caller can't pick a past price
    function test_postPrices_anOlderUpdateIsIgnored() public {
        RouterPlan.Plan memory p;
        p = p.postPrices(_update(1e8, block.timestamp - 30));
        vm.prank(ALICE);
        senzuRouter.execute(p.actions, p.params, block.timestamp, false);
        assertEq(oracle.priceUsd(address(thin)), 10e18);
    }
}
