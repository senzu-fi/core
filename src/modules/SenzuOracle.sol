// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISenzuFactory} from "../interfaces/ISenzuFactory.sol";
import {ISenzuOracle} from "../interfaces/ISenzuOracle.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

/// @dev What Robinhood's stock tokens expose about their price
interface IPausablePrice {
    function oraclePaused() external view returns (bool);
}

/**
 *  @title  SenzuOracle
 *  @author Senzu
 *  @notice USD price per token from Chainlink, write-once feeds. Every read requires answer > 0, updatedAt within
 *          the heartbeat and answeredInRound >= roundId. A ratio feed prices a token through another asset (WBTC =
 *          WBTC/BTC × BTC/USD). A pausable feed's price is unavailable while its token reports `oraclePaused()` or
 *          can't answer.
 */
contract SenzuOracle is ISenzuOracle {
    using SafeCastLib for int256;

    struct Feed {
        address aggregator;
        uint32 heartbeat;
        uint8 tokenDecimals;
        uint8 feedDecimals;
        bool hasRatio;
        bool pausable;
    }

    struct RatioFeed {
        address aggregator;
        uint32 heartbeat;
        uint8 decimals;
    }

    mapping(address token => Feed) internal _feeds;

    mapping(address token => RatioFeed) internal _ratioFeeds;

    /// @inheritdoc ISenzuOracle
    address public immutable override factory;

    constructor(address factory_) {
        factory = factory_;
    }

    /// @inheritdoc ISenzuOracle
    function feedOf(address token)
        external
        view
        override
        returns (address aggregator, uint32 heartbeat, uint8 tokenDecimals)
    {
        Feed memory feed = _feeds[token];
        return (feed.aggregator, feed.heartbeat, feed.tokenDecimals);
    }

    /// @inheritdoc ISenzuOracle
    function ratioFeedOf(address token)
        external
        view
        override
        returns (address ratioAggregator, uint32 ratioHeartbeat)
    {
        RatioFeed memory ratio = _ratioFeeds[token];
        return (ratio.aggregator, ratio.heartbeat);
    }

    /// @inheritdoc ISenzuOracle
    function isPausable(address token) external view override returns (bool) {
        return _feeds[token].pausable;
    }

    /// @inheritdoc ISenzuOracle
    function priceUsd(address token) external view override returns (uint256 priceWad) {
        (priceWad,) = _price(token);
    }

    /// @inheritdoc ISenzuOracle
    function priceWithDecimals(address token) external view override returns (uint256 priceWad, uint8 tokenDecimals) {
        return _price(token);
    }

    /// @inheritdoc ISenzuOracle
    function pricesWithDecimals(address token0, address token1)
        external
        view
        override
        returns (uint256 price0Wad, uint8 decimals0, uint256 price1Wad, uint8 decimals1)
    {
        (price0Wad, decimals0) = _price(token0);
        (price1Wad, decimals1) = _price(token1);
    }

    function _price(address token) internal view returns (uint256 priceWad, uint8 tokenDecimals) {
        Feed memory feed = _feeds[token];
        if (feed.aggregator == address(0)) revert SenzuOracle__FeedNotSet(token);

        if (feed.pausable && IPausablePrice(token).oraclePaused()) revert SenzuOracle__PricePaused(token);

        priceWad = _read(token, feed.aggregator, feed.heartbeat) * 10 ** (18 - feed.feedDecimals);
        tokenDecimals = feed.tokenDecimals;

        if (feed.hasRatio) {
            RatioFeed memory ratio = _ratioFeeds[token];
            priceWad = FixedPointMathLib.fullMulDiv(
                priceWad, _read(token, ratio.aggregator, ratio.heartbeat), 10 ** ratio.decimals
            );
            if (priceWad == 0) revert SenzuOracle__InvalidPrice(token);
        }
    }

    function _read(address token, address aggregator, uint32 heartbeat) internal view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(aggregator).latestRoundData();

        if (answer <= 0) revert SenzuOracle__InvalidPrice(token);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp - updatedAt > heartbeat || answeredInRound < roundId) {
            revert SenzuOracle__StalePrice(token);
        }
        return answer.toUint256();
    }

    /// @inheritdoc ISenzuOracle
    function addFeed(address token, address aggregator, uint32 heartbeat) external override {
        _addFeed(token, aggregator, heartbeat, false, false);
    }

    /// @inheritdoc ISenzuOracle
    function addPausableFeed(address token, address aggregator, uint32 heartbeat) external override {
        _addFeed(token, aggregator, heartbeat, false, true);
        // Reverts for a token without `oraclePaused()`: its price would never read
        IPausablePrice(token).oraclePaused();
        emit PausableFeedAdded(token);
    }

    /// @inheritdoc ISenzuOracle
    function addFeedWithRatio(
        address token,
        address aggregator,
        uint32 heartbeat,
        address ratioAggregator,
        uint32 ratioHeartbeat
    ) external override {
        _addFeed(token, aggregator, heartbeat, true, false);
        if (ratioAggregator == address(0) || ratioHeartbeat == 0) revert SenzuOracle__InvalidFeed(token);

        uint8 decimals = AggregatorV3Interface(ratioAggregator).decimals();
        if (decimals > 18) revert SenzuOracle__InvalidFeed(token);
        (, int256 answer,,,) = AggregatorV3Interface(ratioAggregator).latestRoundData();
        if (answer <= 0) revert SenzuOracle__InvalidPrice(token);

        _ratioFeeds[token] = RatioFeed({aggregator: ratioAggregator, heartbeat: ratioHeartbeat, decimals: decimals});
        emit RatioFeedAdded(token, ratioAggregator, ratioHeartbeat);
    }

    function _addFeed(address token, address aggregator, uint32 heartbeat, bool hasRatio, bool pausable) internal {
        if (msg.sender != ISenzuFactory(factory).admin()) revert SenzuOracle__NotAdmin();
        if (_feeds[token].aggregator != address(0)) revert SenzuOracle__FeedAlreadySet(token);
        if (token == address(0) || aggregator == address(0) || heartbeat == 0) {
            revert SenzuOracle__InvalidFeed(token);
        }

        uint8 feedDecimals = AggregatorV3Interface(aggregator).decimals();
        uint8 tokenDecimals = IERC20Metadata(token).decimals();
        if (feedDecimals > 18 || tokenDecimals > 36) revert SenzuOracle__InvalidFeed(token);

        (, int256 answer,,,) = AggregatorV3Interface(aggregator).latestRoundData();
        if (answer <= 0) revert SenzuOracle__InvalidPrice(token);

        _feeds[token] = Feed({
            aggregator: aggregator,
            heartbeat: heartbeat,
            tokenDecimals: tokenDecimals,
            feedDecimals: feedDecimals,
            hasRatio: hasRatio,
            pausable: pausable
        });

        emit FeedAdded(token, aggregator, heartbeat);
    }
}
