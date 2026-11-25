// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 *  @title  ISenzuOracle
 *  @notice USD price per token from Chainlink. Feeds are write-once per token.
 */
interface ISenzuOracle {
    error SenzuOracle__NotAdmin();
    error SenzuOracle__FeedAlreadySet(address token);
    error SenzuOracle__FeedNotSet(address token);
    error SenzuOracle__InvalidPrice(address token);
    error SenzuOracle__StalePrice(address token);
    error SenzuOracle__InvalidFeed(address token);
    error SenzuOracle__PricePaused(address token);

    event FeedAdded(address indexed token, address indexed aggregator, uint32 heartbeat);
    event RatioFeedAdded(address indexed token, address indexed ratioAggregator, uint32 ratioHeartbeat);
    event PausableFeedAdded(address indexed token);

    /// @notice SenzuFactory (admin lookup)
    function factory() external view returns (address);

    /// @notice Feed config of a token
    function feedOf(address token) external view returns (address aggregator, uint32 heartbeat, uint8 tokenDecimals);

    /// @notice USD per 1 whole token, 1e18 precision. Reverts on a stale, invalid, missing or paused price.
    function priceUsd(address token) external view returns (uint256 priceWad);

    /// @notice Whether the token's price also stops while the token says its price is paused (stock tokens)
    function isPausable(address token) external view returns (bool);

    /// @notice `priceUsd` plus the token's decimals, in one call (what every valuation needs)
    function priceWithDecimals(address token) external view returns (uint256 priceWad, uint8 tokenDecimals);

    /// @notice `priceWithDecimals` of a pair's two tokens, in one call (what every health check reads)
    function pricesWithDecimals(address token0, address token1)
        external
        view
        returns (uint256 price0Wad, uint8 decimals0, uint256 price1Wad, uint8 decimals1);

    /// @notice Admin only. Adds the USD feed of a new token (write-once)
    function addFeed(address token, address aggregator, uint32 heartbeat) external;

    /**
     *  @notice Admin only, write-once. For a token priced through another asset, e.g. WBTC = WBTC/BTC × BTC/USD:
     *          `aggregator` is the underlying's USD feed (BTC/USD) and `ratioAggregator` the token's price in the
     *          underlying (WBTC/BTC). Each feed is checked against its own heartbeat on every read.
     */
    function addFeedWithRatio(
        address token,
        address aggregator,
        uint32 heartbeat,
        address ratioAggregator,
        uint32 ratioHeartbeat
    ) external;

    /**
     *  @notice Admin only, write-once. `addFeed` for a token that can pause its own price (Robinhood's stock tokens,
     *          around corporate actions): while the token's `oraclePaused()` is true the price reads as unavailable,
     *          exactly like a stale round (`PricePaused`); if that call fails, the read fails with the token's error
     */
    function addPausableFeed(address token, address aggregator, uint32 heartbeat) external;

    /// @notice The ratio feed of a token priced through another asset (zero if it has none)
    function ratioFeedOf(address token) external view returns (address ratioAggregator, uint32 ratioHeartbeat);
}
