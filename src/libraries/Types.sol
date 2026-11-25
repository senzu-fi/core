// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 *  @custom:member pendingReserveShares The protocol's lender shares (reserve factor, borrow fees and liquidation fees)
 *                 not minted yet: every share price counts them, `mintReserves` mints them to `protocolReserves`
 *  @custom:member interestRemainder Interest under one unit of the asset, times WAD, carried to the next accrual
 *  @custom:member rateAtTarget Borrow rate at the target utilization as of `lastAccrual`, per second (1e18 = 100%)
 */
struct Market {
    bool exists;
    uint8 index;
    uint128 totalSupplyAssets;
    uint112 pendingReserveShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint64 lastAccrual;
    uint64 reserveFactorWad;
    uint64 interestRemainder;
    uint64 rateAtTarget;
}

struct FeeCheckpoint {
    uint256 feeGrowthInside0X128;
    uint256 feeGrowthInside1X128;
    uint128 owed0;
    uint128 owed1;
}

/// @notice A range position (ISenzuRangeAdapter): liquidity L between two prices. Full-range (v2) positions use the
///         min/max sqrt prices
struct Shape {
    address token0;
    address token1;
    uint160 sqrtPaX96;
    uint160 sqrtPbX96;
    uint128 liquidity;
}

enum Rounding {
    Down,
    Up
}

/// @dev A debt lane holds its market's index in 8 bits
uint256 constant MAX_MARKETS = 256;

struct BorrowableState {
    mapping(address asset => Market) markets;
    /// @dev By `Market.index`. A fixed array has no length to read, so a debt's lane finds its asset in one read
    address[MAX_MARKETS] marketList;
    uint256 marketCount;
    /// @dev A position's debts, two lanes in one word (DebtLanes)
    mapping(address account => mapping(uint256 id => uint256)) debts;
}

/**
 *  @custom:member sigmaWad Stress factor (1.10e18 = ±10% multiplicative: p/σ and p·σ)
 *  @custom:member penaltyWad Liquidation penalty, all of it the liquidator's (1.08e18 = 8%). A position pays the
 *                 highest of its pair's two tokens and its debts outside the pair
 */
struct TokenRisk {
    uint64 sigmaWad;
    uint64 penaltyWad;
    bool collateralEnabled;
    /// @dev May be owed by a position outside its pair (a liquidator can buy it on any DEX). Set-only
    bool liquid;
}

enum DebtTie {
    None,
    Token0,
    Token1
}

/// @notice A position's pair at oracle prices, with the σ its health check stresses each token by
struct CollateralInput {
    address token0;
    address token1;
    uint256 price0Wad; // USD per 1 whole token0
    uint256 price1Wad; // USD per 1 whole token1
    uint8 decimals0;
    uint8 decimals1;
    uint256 sigma0Wad;
    uint256 sigma1Wad;
}

/// @notice What a position holds at each price `HealthMath.sqrtPrices` lists, as its adapter's `amountsAt` reports it:
///         [0] the oracle's, [1 + c] stress corner c's, token0 up when c & 1 and token1 up when c & 2 (1: both down,
///         2: token0 up, 3: token1 up, 4: both up)
struct Holdings {
    uint256[5] amounts0;
    uint256[5] amounts1;
}

struct DebtInput {
    uint256 valueUsdWad;
    uint256 sigmaWad;
    DebtTie tie;
}

/**
 *  @custom:member minSurplusUsdWad Worst corner of (collateral − debt · penalty). Below 0 = liquidatable: the field
 *                 the core checks
 *  @custom:member healthWad min over corners of collateral / (debt · penalty). Below 1e18 = liquidatable
 *  @custom:member collateralUsdWad Collateral value at current (unstressed) prices
 *  @custom:member debtUsdWad Debt value at current (unstressed) prices
 */
struct HealthResult {
    int256 minSurplusUsdWad;
    uint256 healthWad;
    uint256 collateralUsdWad;
    uint256 debtUsdWad;
}

uint256 constant WAD = 1e18;

uint256 constant MIN_INCENTIVE = 1.02e18;

bytes32 constant ACTION_SUPPLY = keccak256("SENZU_SUPPLY");
bytes32 constant ACTION_BORROW = keccak256("SENZU_BORROW");
bytes32 constant ACTION_OPEN = keccak256("SENZU_OPEN");

/// @notice The ERC-6909 id of a lender's shares of `asset` in a borrowable
function lenderId(address asset) pure returns (uint256) {
    return uint256(uint160(asset));
}
