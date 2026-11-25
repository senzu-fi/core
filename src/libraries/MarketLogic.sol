// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Market, Rounding, WAD} from "./Types.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

/**
 *  @notice Share math and interest. Borrow rates follow an adaptive curve (Morpho's AdaptiveCurveIrm design): the
 *          rate at the target utilization moves exponentially toward whatever keeps utilization at the target,
 *          from the utilization at the start of each period, and the curve sets the rate around it
 *          (rateAtTarget / 4 at 0%, 4 · rateAtTarget at 100%). Same constants for every market; nobody sets rates.
 *          A period charges the exact integral of that rate, compounded continuously, so what borrowers owe does
 *          not depend on how often anyone accrues.
 */
library MarketLogic {
    using SafeCastLib for uint256;
    using SafeCastLib for int256;

    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    uint256 internal constant TARGET_UTILIZATION = 0.9e18;
    int256 private constant TARGET_UTILIZATION_INT = 0.9e18;
    int256 private constant WAD_INT = 1e18;
    int256 internal constant CURVE_STEEPNESS = 4e18;
    /// @notice Per second: at 100% utilization the rate at target grows e^(100 · years)
    // forge-lint: disable-next-line(unsafe-typecast)
    int256 internal constant ADJUSTMENT_SPEED = int256(100e18 / SECONDS_PER_YEAR);
    uint256 internal constant INITIAL_RATE_AT_TARGET = 0.08e18 / SECONDS_PER_YEAR;
    uint256 internal constant MIN_RATE_AT_TARGET = 0.01e18 / SECONDS_PER_YEAR;
    /// @notice Caps every borrow rate at 4 · 37.5% = 150% a year
    uint256 internal constant MAX_RATE_AT_TARGET = 0.375e18 / SECONDS_PER_YEAR;
    /// @dev e^4 > MAX / MIN, so a larger exponent hits a bound anyway; the clamp keeps expWad far from its revert
    int256 internal constant MAX_EXPONENT = 4e18;
    /// @notice Most one accrual compounds: e^15 ≈ 3.3 million times the debt, ten years at 150%. It keeps an
    ///         accrual after any idle time from reverting; past it, the excess interest is not charged
    uint256 internal constant MAX_GROWTH_EXPONENT = 15e18;
    /// @dev Within ±0.05, e^x − 1 sums its Taylor series at 1e36 (per-block accruals, exact); past it, expWad's unit
    ///      in 1e18 is under 2e-17 of the result
    int256 internal constant SERIES_LIMIT = 0.05e18;

    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    function toShares(uint256 assets, uint256 totalAssets, uint256 totalShares, Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        return rounding == Rounding.Up
            ? FixedPointMathLib.fullMulDivUp(assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS)
            : FixedPointMathLib.fullMulDiv(assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    function toAssets(uint256 shares, uint256 totalAssets, uint256 totalShares, Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        return rounding == Rounding.Up
            ? FixedPointMathLib.fullMulDivUp(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES)
            : FixedPointMathLib.fullMulDiv(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }

    function cash(Market memory market) internal pure returns (uint256) {
        return market.totalSupplyAssets - market.totalBorrowAssets;
    }

    /// @notice 1e18 = 100%
    function utilization(Market memory market) internal pure returns (uint256) {
        if (market.totalSupplyAssets == 0) return 0;
        return FixedPointMathLib.fullMulDiv(market.totalBorrowAssets, WAD, market.totalSupplyAssets);
    }

    /// @notice Borrow rate now, per second (1e18 = 100%), for a market accrued to now
    function borrowRate(Market memory market) internal pure returns (uint256) {
        return curve(market.rateAtTarget, utilizationError(utilization(market)));
    }

    /// @notice Distance from the target, signed WAD: −1e18 at 0% utilization, 0 at the target, 1e18 at 100%
    function utilizationError(uint256 util) internal pure returns (int256) {
        int256 norm = util > TARGET_UTILIZATION ? WAD_INT - TARGET_UTILIZATION_INT : TARGET_UTILIZATION_INT;
        return (util.toInt256() - TARGET_UTILIZATION_INT) * WAD_INT / norm;
    }

    /// @notice The rate the curve gives at `err` around `rateAtTarget`
    function curve(uint256 rateAtTarget, int256 err) internal pure returns (uint256) {
        int256 coefficient = err < 0 ? WAD_INT - WAD_INT * WAD_INT / CURVE_STEEPNESS : CURVE_STEEPNESS - WAD_INT;
        return ((coefficient * err / WAD_INT + WAD_INT) * rateAtTarget.toInt256() / WAD_INT).toUint256();
    }

    /**
     *  @notice The borrow rate integrated over a period of `elapsed` seconds that starts at `util` and `rateAtTarget`
     *  @dev The rate at target follows r(t) = clamp(r₀ · e^(speed · t), MIN, MAX), and the curve is linear in it, so
     *       the period's integral is the curve applied to ∫ r dt, taken exactly (`rateAtTargetArea`)
     *  @return integral ∫ borrow rate dt over the period, WAD (0.04e18 = a year at 4%), rounded down
     *  @return endRateAtTarget The rate at target at the end of the period
     */
    function adaptiveRate(uint256 rateAtTarget, uint256 util, uint256 elapsed)
        internal
        pure
        returns (uint256 integral, uint256 endRateAtTarget)
    {
        int256 err = utilizationError(util);
        int256 speed = ADJUSTMENT_SPEED * err / WAD_INT;
        // forge-lint: disable-next-line(divide-before-multiply)
        int256 linearAdaptation = speed * elapsed.toInt256();
        if (linearAdaptation == 0) return (curve(rateAtTarget * elapsed, err), rateAtTarget);

        endRateAtTarget = adaptedRateAtTarget(rateAtTarget, linearAdaptation);
        integral = curve(rateAtTargetArea(rateAtTarget, speed, linearAdaptation, endRateAtTarget, elapsed), err);
    }

    /// @notice `rateAtTarget · e^linearAdaptation`, within [MIN_RATE_AT_TARGET, MAX_RATE_AT_TARGET]
    function adaptedRateAtTarget(uint256 rateAtTarget, int256 linearAdaptation) internal pure returns (uint256) {
        int256 x = linearAdaptation > MAX_EXPONENT
            ? MAX_EXPONENT
            : linearAdaptation < -MAX_EXPONENT ? -MAX_EXPONENT : linearAdaptation;
        return _clampRateAtTarget(rateAtTarget * FixedPointMathLib.expWad(x).toUint256() / WAD);
    }

    function _clampRateAtTarget(uint256 rate) private pure returns (uint256) {
        if (rate < MIN_RATE_AT_TARGET) return MIN_RATE_AT_TARGET;
        if (rate > MAX_RATE_AT_TARGET) return MAX_RATE_AT_TARGET;
        return rate;
    }

    /**
     *  @notice ∫ r dt over the period, r(t) = clamp(r₀ · e^(speed · t)), in rate · seconds (WAD): rounded down, or
     *          within a wei (lnWad's) when it reaches a bound
     *  @dev Unclamped through the period, r₀ (e^(speed · T) − 1) / speed. Reaching the bound B at
     *       τ = ln(B / r₀) / speed < T, B (T − τ) + (B − r₀) / speed. It reaches B when the end rate at target is at
     *       B or the exponent passes MAX_EXPONENT (> ln(MAX / MIN)). A start outside the bounds (never stored)
     *       integrates from the bound it is past
     */
    function rateAtTargetArea(
        uint256 rateAtTarget,
        int256 speed,
        int256 linearAdaptation,
        uint256 endRateAtTarget,
        uint256 elapsed
    ) internal pure returns (uint256) {
        uint256 start = _clampRateAtTarget(rateAtTarget);
        uint256 bound = speed > 0 ? MAX_RATE_AT_TARGET : MIN_RATE_AT_TARGET;
        if (start == bound) return bound * elapsed;
        if (endRateAtTarget != bound && linearAdaptation <= MAX_EXPONENT && linearAdaptation >= -MAX_EXPONENT) {
            int256 growth = expMinusOne(linearAdaptation);
            return FixedPointMathLib.fullMulDiv(
                start, (growth > 0 ? growth : -growth).toUint256(), (speed > 0 ? speed : -speed).toUint256() * WAD
            );
        }
        // B · T − [B · ln(B / r₀) − (B − r₀)] / speed, the bracket ≥ 0 on either side
        int256 ramp = bound.toInt256() * FixedPointMathLib.lnWad((bound * WAD / start).toInt256())
            - (bound.toInt256() - start.toInt256()) * WAD_INT;
        return ((bound * elapsed).toInt256() - ramp / speed).toUint256();
    }

    /// @notice e^x − 1 in 1e36: a Taylor series within ±SERIES_LIMIT (each term rounded toward zero), expWad past it
    function expMinusOne(int256 x) internal pure returns (int256 sum) {
        if (x > SERIES_LIMIT || x < -SERIES_LIMIT) return (FixedPointMathLib.expWad(x) - WAD_INT) * WAD_INT;
        // |x| ≤ 0.05e18 keeps every term under 5e34 and the sum under 5.2e34: nothing overflows
        unchecked {
            int256 term = x * WAD_INT;
            for (int256 n = 2; term != 0; ++n) {
                sum += term;
                term = term * x / (n * WAD_INT);
            }
        }
    }

    /// @notice Per second
    function supplyRate(Market memory market, uint256 borrowRatePerSecond) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(
            FixedPointMathLib.fullMulDiv(borrowRatePerSecond, utilization(market), WAD),
            WAD - market.reserveFactorWad,
            WAD
        );
    }

    /**
     *  @notice Books the interest since the last accrual: borrows · (e^∫rate − 1), rounded down, the part under one
     *          unit carried in `interestRemainder`. An empty market's rate at target doesn't move (no demand to read).
     *          `reserveAssets` is the reserve's cut of `interest`, minted as shares by `reserveShares`
     */
    /// @dev Writes the accrued state into `market`, a memory copy: callers store it or read from it
    function accrue(Market memory market) internal view returns (uint256 interest, uint256 reserveAssets) {
        uint256 elapsed = block.timestamp - market.lastAccrual;
        if (elapsed == 0) return (0, 0);
        market.lastAccrual = block.timestamp.toUint64();
        if (market.totalSupplyAssets == 0) return (0, 0);
        (uint256 integral, uint256 endRateAtTarget) = adaptiveRate(market.rateAtTarget, utilization(market), elapsed);
        market.rateAtTarget = endRateAtTarget.toUint64();
        if (market.totalBorrowAssets == 0) return (0, 0);

        uint256 exponent = integral < MAX_GROWTH_EXPONENT ? integral : MAX_GROWTH_EXPONENT;
        uint256 scaled = FixedPointMathLib.fullMulDiv(
            market.totalBorrowAssets, expMinusOne(exponent.toInt256()).toUint256(), WAD
        ) + market.interestRemainder;
        interest = scaled / WAD;
        market.interestRemainder = (scaled % WAD).toUint64();
        if (interest == 0) return (0, 0);

        market.totalBorrowAssets = (market.totalBorrowAssets + interest).toUint128();
        market.totalSupplyAssets = (market.totalSupplyAssets + interest).toUint128();

        reserveAssets = FixedPointMathLib.fullMulDiv(interest, market.reserveFactorWad, WAD);
    }

    /// @notice Lender shares for `reserveAssets` of the interest `accrue` just booked into `market`, priced before
    ///         them; rounded down
    function reserveShares(Market memory market, uint256 reserveAssets, uint256 totalSupplyShares)
        internal
        pure
        returns (uint256)
    {
        if (reserveAssets == 0) return 0;
        return toShares(reserveAssets, market.totalSupplyAssets - reserveAssets, totalSupplyShares, Rounding.Down);
    }
}
