// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {MarketLogic} from "../src/libraries/MarketLogic.sol";
import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice Morpho Blue's AdaptiveCurveIrm (morpho-org/morpho-blue-irm, `src/adaptive-curve-irm/`, MIT, Morpho Labs):
///         `_borrowRate`, `_curve`, `_newRateAtTarget`, `MathLib` and `ExpLib.wExp` as published, with Senzu's
///         constants. `useSoladyExp` swaps `wExp` for the exp Senzu uses. `exactIntegral` is not Morpho's: the
///         closed form of the same rate at target path, for what Senzu charges instead of Morpho's trapezoid.
library MorphoReference {
    int256 internal constant WAD = 1e18;
    int256 internal constant CURVE_STEEPNESS = 4 ether;
    int256 internal constant ADJUSTMENT_SPEED = 100 ether / int256(365 days);
    int256 internal constant TARGET_UTILIZATION = 0.9 ether;
    int256 internal constant MIN_RATE_AT_TARGET = 0.01 ether / int256(365 days);
    int256 internal constant MAX_RATE_AT_TARGET = 0.375 ether / int256(365 days);

    int256 internal constant LN_2_INT = 0.693147180559945309 ether;
    int256 internal constant LN_WEI_INT = -41.446531673892822312 ether;
    int256 internal constant WEXP_UPPER_BOUND = 93.859467695000404319 ether;
    int256 internal constant WEXP_UPPER_VALUE = 57716089161558943949701069502944508345128.422502756744429568 ether;

    function wMulToZero(int256 x, int256 y) internal pure returns (int256) {
        return (x * y) / WAD;
    }

    function wDivToZero(int256 x, int256 y) internal pure returns (int256) {
        return (x * WAD) / y;
    }

    function bound(int256 x, int256 low, int256 high) internal pure returns (int256) {
        return x < low ? low : x > high ? high : x;
    }

    function wExp(int256 x) internal pure returns (int256) {
        unchecked {
            if (x < LN_WEI_INT) return 0;
            if (x >= WEXP_UPPER_BOUND) return WEXP_UPPER_VALUE;
            int256 roundingAdjustment = (x < 0) ? -(LN_2_INT / 2) : (LN_2_INT / 2);
            int256 q = (x + roundingAdjustment) / LN_2_INT;
            int256 r = x - q * LN_2_INT;
            int256 expR = WAD + r + (r * r) / WAD / 2;
            if (q >= 0) return expR << uint256(q);
            else return expR >> uint256(-q);
        }
    }

    function borrowRate(int256 startRateAtTarget, int256 utilization, int256 elapsed, bool useSoladyExp)
        internal
        pure
        returns (uint256, int256)
    {
        int256 errNormFactor = utilization > TARGET_UTILIZATION ? WAD - TARGET_UTILIZATION : TARGET_UTILIZATION;
        int256 err = wDivToZero(utilization - TARGET_UTILIZATION, errNormFactor);

        int256 avgRateAtTarget;
        int256 endRateAtTarget;
        int256 speed = wMulToZero(ADJUSTMENT_SPEED, err);
        int256 linearAdaptation = speed * elapsed;
        if (linearAdaptation == 0) {
            avgRateAtTarget = startRateAtTarget;
            endRateAtTarget = startRateAtTarget;
        } else {
            endRateAtTarget = newRateAtTarget(startRateAtTarget, linearAdaptation, useSoladyExp);
            int256 midRateAtTarget = newRateAtTarget(startRateAtTarget, linearAdaptation / 2, useSoladyExp);
            avgRateAtTarget = (startRateAtTarget + endRateAtTarget + 2 * midRateAtTarget) / 4;
        }
        return (uint256(curve(avgRateAtTarget, err)), endRateAtTarget);
    }

    /// @notice ∫ curve(clamp(s · e^(speed · t)), err) dt over `elapsed`, written from τ = min(T, ln(B / s) / speed):
    ///         s (e^(speed · τ) − 1) / speed + B (T − τ). A tiny exponent takes the series to its third term
    function exactIntegral(int256 startRateAtTarget, int256 utilization, int256 elapsed)
        internal
        pure
        returns (uint256)
    {
        int256 errNormFactor = utilization > TARGET_UTILIZATION ? WAD - TARGET_UTILIZATION : TARGET_UTILIZATION;
        int256 err = wDivToZero(utilization - TARGET_UTILIZATION, errNormFactor);
        int256 speed = wMulToZero(ADJUSTMENT_SPEED, err);
        int256 s = startRateAtTarget;
        if (speed == 0) return uint256(curve(s * elapsed, err));
        int256 b = speed > 0 ? MAX_RATE_AT_TARGET : MIN_RATE_AT_TARGET;
        if (s == b) return uint256(curve(b * elapsed, err));
        int256 tauWad = FixedPointMathLib.lnWad(b * WAD / s) * WAD / speed;
        if (tauWad > elapsed * WAD) tauWad = elapsed * WAD;
        int256 x = speed * tauWad / WAD;
        int256 ramp = x < 1e14 && x > -1e14
            ? s * tauWad / WAD + s * tauWad / WAD * x / WAD / 2 + s * tauWad / WAD * x / WAD * x / WAD / 6
            : s * (FixedPointMathLib.expWad(x) - WAD) / speed;
        return uint256(curve(ramp + b * (elapsed * WAD - tauWad) / WAD, err));
    }

    function curve(int256 rateAtTarget, int256 err) internal pure returns (int256) {
        int256 coeff = err < 0 ? WAD - wDivToZero(WAD, CURVE_STEEPNESS) : CURVE_STEEPNESS - WAD;
        return wMulToZero(wMulToZero(coeff, err) + WAD, rateAtTarget);
    }

    function newRateAtTarget(int256 startRateAtTarget, int256 linearAdaptation, bool useSoladyExp)
        internal
        pure
        returns (int256)
    {
        int256 e = useSoladyExp ? FixedPointMathLib.expWad(linearAdaptation) : wExp(linearAdaptation);
        return bound(wMulToZero(startRateAtTarget, e), MIN_RATE_AT_TARGET, MAX_RATE_AT_TARGET);
    }
}

/// @notice Senzu's rate at target is Morpho's audited AdaptiveCurveIrm with two declared changes, its constants and
///         its exp. What a period charges is not Morpho's: Morpho charges the curve at a trapezoid average of the rate
///         at target (start, middle, end) as simple interest; Senzu integrates the same path exactly and
///         compounds it
contract AdaptiveRateMorphoTest is Test {
    function test_sameConstants() public pure {
        assertEq(int256(MarketLogic.TARGET_UTILIZATION), MorphoReference.TARGET_UTILIZATION);
        assertEq(MarketLogic.CURVE_STEEPNESS, MorphoReference.CURVE_STEEPNESS);
        assertEq(MarketLogic.ADJUSTMENT_SPEED, MorphoReference.ADJUSTMENT_SPEED);
        assertEq(int256(MarketLogic.MIN_RATE_AT_TARGET), MorphoReference.MIN_RATE_AT_TARGET);
        assertEq(int256(MarketLogic.MAX_RATE_AT_TARGET), MorphoReference.MAX_RATE_AT_TARGET);
    }

    /// @dev With the same exp, every new rate at target is Morpho's to the wei, and the period's integral is the
    ///      exact one of that path (to 1e-12, the reference's own precision), where Morpho's trapezoid is not. Up to
    ///      300 days per period, as far as Morpho's math runs with Solady's exp without overflowing (ours clamps its
    ///      exponent)
    function testFuzz_matchesMorphoWithTheSameExp(uint256 rateAtTarget, uint256 util, uint256 elapsed) public pure {
        rateAtTarget = bound(rateAtTarget, MarketLogic.MIN_RATE_AT_TARGET, MarketLogic.MAX_RATE_AT_TARGET);
        util = bound(util, 0, 1e18);
        elapsed = bound(elapsed, 0, 300 days);
        (uint256 integral, uint256 end) = MarketLogic.adaptiveRate(rateAtTarget, util, elapsed);
        (, int256 refEnd) = MorphoReference.borrowRate(int256(rateAtTarget), int256(util), int256(elapsed), true);
        assertEq(int256(end), refEnd, "rate at target");
        uint256 exact = MorphoReference.exactIntegral(int256(rateAtTarget), int256(util), int256(elapsed));
        assertApproxEqAbs(integral, exact, exact / 1e12 + 8, "the exact integral");
    }

    /// @dev Morpho's own exp (a 2nd-order Taylor polynomial) differs from ours by under 1%, never more
    function testFuzz_morphosExpIsWithinOnePercent(uint256 rateAtTarget, uint256 util, uint256 elapsed) public pure {
        rateAtTarget = bound(rateAtTarget, MarketLogic.MIN_RATE_AT_TARGET, MarketLogic.MAX_RATE_AT_TARGET);
        util = bound(util, 0, 1e18);
        elapsed = bound(elapsed, 1, 300 days);
        (, uint256 end) = MarketLogic.adaptiveRate(rateAtTarget, util, elapsed);
        (, int256 refEnd) = MorphoReference.borrowRate(int256(rateAtTarget), int256(util), int256(elapsed), false);
        assertApproxEqRel(end, uint256(refEnd), 0.01e18, "rate at target");
    }

    /// @dev Where the band is reached mid-period Morpho's trapezoid is far off: at 100% from 4% the rate at target
    ///      reaches the ceiling in 8.2 days, so 30 days average 31.4% at target, the trapezoid (4% + 3 · 37.5%) / 4 = 29.1%
    function test_trapezoidIsOffWhereTheExactIsNot() public pure {
        uint256 rateAtTarget = 0.04e18 / uint256(365 days);
        (uint256 integral,) = MarketLogic.adaptiveRate(rateAtTarget, 1e18, 30 days);
        (uint256 morphoRate,) = MorphoReference.borrowRate(int256(rateAtTarget), 1e18, int256(30 days), true);
        uint256 exact = MorphoReference.exactIntegral(int256(rateAtTarget), 1e18, int256(30 days));
        assertApproxEqRel(integral, exact, 1e6);
        assertLt(morphoRate * 30 days, exact * 95 / 100, "the trapezoid undercharges by over 5%");
    }
}
