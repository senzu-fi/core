// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 *  @title  ISenzuLens
 *  @notice Read-only batching for one deployment's frontend: one call per table or panel. Position ids are passed
 *          in (ERC-6909 has no enumeration).
 *
 *          Liquidation prices move the USD price of the token with the higher σ and hold the other's fixed, found by
 *          bisection on the collateral's health math. 0 means no liquidation price within 1000x of the current one.
 *
 *          The views never fail on a closed market: where the oracle refuses a price as stale or paused (a stock over
 *          the weekend), they price the token at its feed's last answer and flag it `stale`. The core refuses to act
 *          on that price; only closing works until the oracle prices it again.
 */
interface ISenzuLens {
    struct MarketView {
        address asset;
        uint8 decimals;
        uint256 priceWad;
        bool stale; // priceWad is the feed's last answer, which the oracle refuses (stale or paused)
        uint256 supplyAssets;
        uint256 borrowAssets;
        uint256 borrowShares;
        uint256 cash;
        uint256 utilizationWad;
        uint256 borrowAprWad;
        uint256 supplyAprWad;
        /// @dev The adaptive curve's rate at 90% utilization, as of now: rising while utilization is above it
        uint256 rateAtTargetAprWad;
        uint256 reserveFactorWad;
    }

    struct LenderView {
        address asset;
        uint256 shares;
        uint256 assets;
        uint256 valueUsdWad;
        uint256 maxWithdraw;
    }

    /// @notice Header of a pair's trade page
    struct PairView {
        bytes32 pairKey;
        bool enabled;
        address token0;
        address token1;
        uint256 price0Wad;
        uint256 price1Wad;
        uint160 oracleSqrtPriceX96; // token1 per token0, Uniswap convention
        uint256 sigma0Wad;
        uint256 sigma1Wad;
        uint256 penaltyWad; // the higher of the two tokens' liquidation penalties
        bool stale0; // price0Wad is the last answer, which the oracle refuses
        bool stale1;
    }

    struct LiquidationPrices {
        address token; // the token whose USD price moves
        uint256 lowerWad; // its USD price at liquidation below the current price (0 = none)
        uint256 upperWad; // above (0 = none)
    }

    struct DebtView {
        address asset;
        uint256 assets;
        uint256 valueUsdWad;
        uint256 borrowAprWad;
    }

    /// @notice One row of the Positions table
    struct PositionView {
        address account;
        uint256 id;
        address adapter;
        bytes32 pairKey;
        address token0;
        address token1;
        uint160 sqrtPaX96;
        uint160 sqrtPbX96;
        uint160 poolSqrtPriceX96;
        bool inRange; // pool price inside [pa, pb)
        uint256 units; // the account's balance of the id
        uint256 totalUnits;
        uint128 liquidity; // the account's share of the position's liquidity
        uint256 amount0; // underlying at the oracle price
        uint256 amount1;
        uint256 collateralUsdWad;
        uint256 debtUsdWad;
        int256 marginUsdWad; // collateral − debt
        uint256 healthWad; // below 1e18 = liquidatable
        uint256 penaltyWad; // the highest of its pair's tokens and its debts outside the pair
        uint256 feesOwed0; // pending
        uint256 feesOwed1;
        LiquidationPrices liquidation;
        DebtView[] debts;
        bool stale; // a price it's valued at (either token, any debt) is a last answer the oracle refuses
    }

    /// @notice `token`'s oracle price, else its feed's last answer while the oracle refuses it as stale or paused
    ///         (`stale`); any other refusal (no feed, an answer at or below 0) reverts with the oracle's error
    function price(address token) external view returns (uint256 priceWad, uint8 decimals, bool stale);

    /// @notice `price` in the oracle's shape: the health math these views run reads its prices here
    function priceWithDecimals(address token) external view returns (uint256 priceWad, uint8 decimals);
    function pricesWithDecimals(address token0, address token1)
        external
        view
        returns (uint256 price0Wad, uint8 decimals0, uint256 price1Wad, uint8 decimals1);

    function collateral() external view returns (address);
    function borrowable() external view returns (address);

    function getMarkets() external view returns (MarketView[] memory);
    function getMarket(address asset) external view returns (MarketView memory);
    function getLender(address account) external view returns (LenderView[] memory);

    /// @notice A pair of this lens's adapter: its key, prices, σ and liquidation penalty
    function getPair(address token0, address token1) external view returns (PairView memory);

    function getPosition(address account, uint256 id) external view returns (PositionView memory);
    function getPositions(address account, uint256[] calldata ids) external view returns (PositionView[] memory);
}
