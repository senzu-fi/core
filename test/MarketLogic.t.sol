// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {MarketLogic} from "../src/libraries/MarketLogic.sol";
import {Market, Rounding} from "../src/libraries/Types.sol";
import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract MarketLogicTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant YEAR = 365 days;
    /// @dev The example rate at target, 4% (the numbers below are worked out for it); a new market's is checked in
    ///      test_constants
    uint256 constant RATE = 0.04e18 / YEAR;
    uint256 constant MIN = MarketLogic.MIN_RATE_AT_TARGET;
    uint256 constant MAX = MarketLogic.MAX_RATE_AT_TARGET;
    /// @dev ln 2 / 100 years: how long the rate at target takes to double at 100% utilization, or halve at 0%
    uint256 constant DOUBLING = 218_591;

    function setUp() public {
        vm.warp(1_000_000);
    }

    /// @dev External, so each call reads the warped block.timestamp (via-IR can reuse one read inside a loop)
    function accrueAt(Market memory m) external view returns (uint256, Market memory) {
        (uint256 interest,) = MarketLogic.accrue(m);
        return (interest, m);
    }

    function _market(uint256 supplyAssets, uint256 borrowAssets) internal view returns (Market memory m) {
        m.exists = true;
        m.totalSupplyAssets = uint128(supplyAssets);
        m.totalBorrowAssets = uint128(borrowAssets);
        m.lastAccrual = uint64(block.timestamp);
        m.reserveFactorWad = 0.1e18;
        m.rateAtTarget = uint64(RATE);
    }

    function _rateAt(uint256 rateAtTarget, uint256 util) internal pure returns (uint256 perYear) {
        return MarketLogic.curve(rateAtTarget, MarketLogic.utilizationError(util)) * YEAR;
    }

    function _endRateAtTarget(uint256 rateAtTarget, uint256 util, uint256 elapsed) internal pure returns (uint256 end) {
        (, end) = MarketLogic.adaptiveRate(rateAtTarget, util, elapsed);
    }

    /*  ================================================
                             Curve
        ================================================  */

    function test_constants() public pure {
        assertEq(MarketLogic.TARGET_UTILIZATION, 0.9e18);
        assertEq(uint256(MarketLogic.ADJUSTMENT_SPEED), 3_170_979_198_376, "100 a year, per second");
        assertApproxEqRel(MarketLogic.INITIAL_RATE_AT_TARGET * YEAR, 0.08e18, 1e10);
        assertApproxEqRel(MIN * YEAR, 0.01e18, 1e10);
        assertApproxEqRel(MAX * YEAR, 0.375e18, 1e10);
    }

    /// @dev Around a 4% rate at target: 1% at 0%, 4% at the 90% target, 16% at 100%, linear in between on each side
    function test_curve_points() public pure {
        assertApproxEqRel(_rateAt(RATE, 0), 0.01e18, 1e10, "0%");
        assertApproxEqRel(_rateAt(RATE, 0.5e18), uint256(0.08e18) / 3, 1e10, "50%: 2.67%");
        assertApproxEqRel(_rateAt(RATE, 0.8e18), uint256(0.11e18) / 3, 1e10, "80%: 3.67%");
        assertEq(_rateAt(RATE, 0.9e18), RATE * YEAR, "90%: the rate at target");
        assertApproxEqRel(_rateAt(RATE, 0.95e18), 0.1e18, 1e10, "95%");
        assertApproxEqRel(_rateAt(RATE, 1e18), 0.16e18, 1e10, "100%");
    }

    /// @dev Solady's expWad, against known values and its domain edges
    function test_expWad() public pure {
        assertEq(FixedPointMathLib.expWad(0), 1e18);
        assertApproxEqRel(uint256(FixedPointMathLib.expWad(1e18)), 2_718281828459045235, 1);
        assertApproxEqRel(uint256(FixedPointMathLib.expWad(-1e18)), 367879441171442321, 1);
        assertApproxEqRel(uint256(FixedPointMathLib.expWad(4e18)), 54_598150033144239078, 1);
        assertEq(FixedPointMathLib.expWad(-41446531673892822313), 0);
    }

    /*  ================================================
                           Adaptation
        ================================================  */

    /// @dev At 100% utilization the rate at target doubles in ln 2 / 100 years (2.53 days); idle, it halves as fast
    function test_adapt_doublesAtFullAndHalvesIdle() public pure {
        assertApproxEqRel(_endRateAtTarget(RATE, WAD, DOUBLING), 2 * RATE, 1e12, "doubles");
        assertApproxEqRel(_endRateAtTarget(RATE, 0, DOUBLING), RATE / 2, 1e12, "halves");
        assertEq(_endRateAtTarget(RATE, 0.9e18, 365 days), RATE, "at the target it stays");
        // An hour at 100% moves it 1.15%: no one can spike rates without holding utilization for days
        assertApproxEqRel(_endRateAtTarget(RATE, WAD, 1 hours), RATE * 10115 / 10000, 1e14);
    }

    /// @dev A doubling period at 100% integrates the rate at target exactly: ∫ s · e^(kt) dt = s (2 − 1) / k, a
    ///      year at 4% over 100, and the curve at 100% is four times it: 0.16% of the debt over 2.53 days
    function test_adapt_integratesTheRate() public pure {
        (uint256 integral, uint256 end) = MarketLogic.adaptiveRate(RATE, WAD, DOUBLING);
        assertApproxEqRel(end, 2 * RATE, 1e12);
        assertApproxEqAbs(integral, 1_600_001_066_413_410, 2, "4 x 4% / 100");
    }

    function test_adapt_floorAndCeiling() public pure {
        assertEq(_endRateAtTarget(RATE, WAD, 30 days), MAX, "37.5% ceiling");
        assertEq(_endRateAtTarget(RATE, 0, 30 days), MIN, "1% floor");
        assertApproxEqRel(_rateAt(MAX, WAD), 1.5e18, 1e10, "no rate above 150% a year");
        assertApproxEqRel(_rateAt(MIN, 0), 0.0025e18, 1e11, "nor below 0.25%");
        // A rate at target past a bound comes back within it on the next period
        assertEq(_endRateAtTarget(MAX, WAD, type(uint64).max), MAX);
        assertEq(_endRateAtTarget(MIN, 0, type(uint64).max), MIN);
    }

    /// @dev Whatever the state and however long the period, the period charges at most 150% a year and at least
    ///      0.25%, and the rate at target stays within its bounds
    function testFuzz_adapt_staysBounded(uint256 rateAtTarget, uint256 util, uint256 elapsed) public pure {
        rateAtTarget = bound(rateAtTarget, MIN, MAX);
        util = bound(util, 0, WAD);
        elapsed = bound(elapsed, 0, type(uint64).max);
        (uint256 integral, uint256 end) = MarketLogic.adaptiveRate(rateAtTarget, util, elapsed);
        // lnWad's unit, times the curve's 4, when the period reaches a bound
        assertLe(integral, MarketLogic.curve(MAX, 1e18) * elapsed + 4, "at most 150% a year");
        assertGe(integral + 4, MarketLogic.curve(MIN, -1e18) * elapsed, "at least 0.25% a year");
        assertGe(end, MIN);
        assertLe(end, MAX);
    }

    /// @dev Splitting a period into many accruals lands on the same rate at target, up to a unit of rounding per
    ///      accrual (the exponential composes; a Taylor approximation would not)
    function testFuzz_adapt_splittingPeriodsMatchesOne(uint256 rateAtTarget, uint256 util, uint256 elapsed, uint8 n)
        public
        pure
    {
        rateAtTarget = bound(rateAtTarget, MIN, MAX);
        util = bound(util, 0, WAD);
        uint256 steps = bound(n, 2, 50);
        elapsed = bound(elapsed, steps, 60 days);

        uint256 split = rateAtTarget;
        uint256 step = elapsed / steps;
        for (uint256 i; i < steps; ++i) {
            split = _endRateAtTarget(split, util, i == steps - 1 ? elapsed - step * (steps - 1) : step);
        }
        uint256 once = _endRateAtTarget(rateAtTarget, util, elapsed);
        // Each step rounds the product down, a unit in at least MIN (3.2e8), which the later steps then scale
        assertApproxEqRel(split, once, steps * 3.2e9, "split periods compose");
    }

    /*  ================================================
                         Exact integral
        ================================================  */

    /// @dev ∫ curve(clamp(s · e^(kt)), err) dt by the midpoint rule over `steps` slices, the rate at target at 1e36
    function _numericIntegral(uint256 rateAtTarget, uint256 util, uint256 elapsed, uint256 steps)
        internal
        pure
        returns (uint256)
    {
        int256 err = MarketLogic.utilizationError(util);
        int256 speed = MarketLogic.ADJUSTMENT_SPEED * err / int256(WAD);
        uint256 sum;
        for (uint256 i; i < steps; ++i) {
            int256 t = int256((2 * i + 1) * elapsed * WAD / (2 * steps));
            int256 x = speed * t / int256(WAD);
            uint256 r = x > 40e18 ? type(uint128).max : rateAtTarget * uint256(FixedPointMathLib.expWad(x));
            r = r < MIN * WAD ? MIN * WAD : r > MAX * WAD ? MAX * WAD : r;
            sum += r;
        }
        return MarketLogic.curve(sum * elapsed / steps / WAD, err);
    }

    function _assertExact(uint256 rateAtTarget, uint256 util, uint256 elapsed) internal pure {
        (uint256 integral,) = MarketLogic.adaptiveRate(rateAtTarget, util, elapsed);
        // The midpoint rule's own error at the bound's kink is a few 1e-10
        assertApproxEqRel(integral, _numericIntegral(rateAtTarget, util, elapsed, 50_000), 1e9, "1e-9 of it");
    }

    function test_exact_unclamped() public pure {
        _assertExact(RATE, WAD, 1 days); // 4% -> 5.26%
        _assertExact(RATE, 0.5e18, 3 days);
        _assertExact(MAX / 2, 0.95e18, 1 hours);
    }

    /// @dev The narrow band (1% to 37.5%) at 100 a year: the bound comes within days, where a trapezoid on start,
    ///      middle and end is far off
    function test_exact_reachesTheCeiling() public pure {
        _assertExact(RATE, WAD, 30 days);
        _assertExact(RATE, 0.95e18, 20 days);
        _assertExact(MAX / 2, WAD, 2 days);
    }

    function test_exact_reachesTheFloor() public pure {
        (uint256 integral,) = MarketLogic.adaptiveRate(RATE, 0, 30 days);
        assertEq(integral, 245_822_092_554_829, "the exact value (mpmath), rounded down");
        _assertExact(RATE, 0, 30 days);
        _assertExact(RATE, 0.3e18, 10 days);
        _assertExact(MIN * 2, 0, 2 days);
    }

    /// @dev Already at the bound it moves toward: the bound for the whole period, exactly
    function test_exact_startsAtTheBound() public pure {
        (uint256 integral,) = MarketLogic.adaptiveRate(MAX, WAD, 10 days);
        assertEq(integral, MarketLogic.curve(MAX * 10 days, 1e18));
        (integral,) = MarketLogic.adaptiveRate(MIN, 0.2e18, 10 days);
        assertEq(integral, MarketLogic.curve(MIN * 10 days, MarketLogic.utilizationError(0.2e18)));
        _assertExact(MAX, 0.97e18, 5 days);
        _assertExact(MIN, 0.1e18, 5 days);
    }

    /// @dev The headline: however a period is split into accruals, at one utilization, the integrals add up to the
    ///      one accrual's. What's left is the rate at target's own rounding (a unit in 3.2e8 per step, as Morpho),
    ///      and each accrual's two roundings down: the area (a wei), then the curve (times at most 4, plus a wei)
    function testFuzz_exact_splitIntegralsAddUp(uint256 rateAtTarget, uint256 util, uint256 elapsed, uint256 seed)
        public
        pure
    {
        rateAtTarget = bound(rateAtTarget, MIN, MAX);
        util = bound(util, 0, WAD);
        uint256 steps = bound(seed, 2, 50);
        elapsed = bound(elapsed, steps, 120 days);

        uint256 total;
        uint256 split = rateAtTarget;
        uint256 left = elapsed;
        for (uint256 i; i < steps; ++i) {
            // Uneven: each step takes a random share of what's left
            uint256 step =
                i == steps - 1 ? left : bound(uint256(keccak256(abi.encode(seed, i))), 1, left - (steps - 1 - i));
            left -= step;
            uint256 integral;
            (integral, split) = MarketLogic.adaptiveRate(split, util, step);
            total += integral;
        }
        (uint256 once, uint256 end) = MarketLogic.adaptiveRate(rateAtTarget, util, elapsed);
        uint256 gap = total > once ? total - once : once - total;
        assertLe(gap, once * (steps * 3.2e9 + 1e6) / 1e18 + 5 * (steps + 1), "the integral");
        assertApproxEqRel(split, end, steps * 3.2e9, "the rate at target");
    }

    /*  ================================================
                             Shares
        ================================================  */

    function testFuzz_shares_roundTripNeverGainsAssets(uint256 assets, uint256 totalAssets, uint256 totalShares)
        public
        pure
    {
        totalAssets = bound(totalAssets, 0, 1e30);
        totalShares = bound(totalShares, 0, 1e36);
        assets = bound(assets, 0, 1e30);

        uint256 shares = MarketLogic.toShares(assets, totalAssets, totalShares, Rounding.Down);
        uint256 back = MarketLogic.toAssets(shares, totalAssets + assets, totalShares + shares, Rounding.Down);
        assertLe(back, assets, "supplying then withdrawing must not create assets");
    }

    function testFuzz_shares_roundingDirection(uint256 assets, uint256 totalAssets, uint256 totalShares) public pure {
        totalAssets = bound(totalAssets, 0, 1e30);
        totalShares = bound(totalShares, 0, 1e36);
        assets = bound(assets, 0, 1e30);
        assertGe(
            MarketLogic.toShares(assets, totalAssets, totalShares, Rounding.Up),
            MarketLogic.toShares(assets, totalAssets, totalShares, Rounding.Down)
        );
        assertGe(
            MarketLogic.toAssets(assets, totalAssets, totalShares, Rounding.Up),
            MarketLogic.toAssets(assets, totalAssets, totalShares, Rounding.Down)
        );
    }

    /*  ================================================
                            Accrual
        ================================================  */

    /// @dev At the target the rate at target never moves, so a year at 4% compounds to 900 · (e^0.04 − 1)
    function test_accrue_compoundsOverOneYear() public {
        Market memory m = _market(1_000e18, 900e18);
        vm.warp(block.timestamp + 365 days);

        (uint256 interest, uint256 reserveAssets) = MarketLogic.accrue(m);
        uint256 reserveShares = MarketLogic.reserveShares(m, reserveAssets, 1_000e18 * 1e6);

        assertApproxEqAbs(interest, 36_729696762792920553, 1); // 900 · (e^0.04 − 1)
        assertEq(m.totalBorrowAssets, 900e18 + interest);
        assertEq(m.totalSupplyAssets, 1_000e18 + interest);
        assertEq(m.lastAccrual, block.timestamp);
        assertEq(m.rateAtTarget, RATE);

        // Reserve shares are worth 10% of the interest
        uint256 reserveValue =
            MarketLogic.toAssets(reserveShares, m.totalSupplyAssets, 1_000e18 * 1e6 + reserveShares, Rounding.Down);
        assertApproxEqRel(reserveValue, interest / 10, 1e12);
    }

    /// @dev Away from the target the rate at target moves within the period, and the accrual compounds its integral
    function test_accrue_chargesTheAdaptedRate() public {
        Market memory m = _market(1_000e18, 1_000e18);
        vm.warp(block.timestamp + DOUBLING);
        (uint256 integral, uint256 end) = MarketLogic.adaptiveRate(RATE, WAD, DOUBLING);

        (uint256 interest,) = MarketLogic.accrue(m);

        assertEq(integral, 1_600_001_066_413_408);
        assertEq(interest, 1_601281751060856497, "1000 (e^integral - 1), to the unit (mpmath)");
        assertEq(m.rateAtTarget, end);
        assertApproxEqRel(m.rateAtTarget, 2 * RATE, 1e12);
    }

    /// @dev Audit 2026-10-15: accruing every second floored each second's interest, and a 400 USDC book at 6% earns
    ///      under one unit a second, so lenders got nothing while lastAccrual moved on. The remainder carries now:
    ///      accruing every second books what one accrual over the whole hour books
    function test_accrue_everySecondLosesNothing() public {
        uint256 start = vm.getBlockTimestamp();
        Market memory stepped = _market(1_000e6, 400e6);
        Market memory once = _market(1_000e6, 400e6);
        (stepped.lastAccrual, once.lastAccrual) = (uint64(start), uint64(start));

        uint256 total;
        for (uint256 i = 1; i <= 1 hours; ++i) {
            vm.warp(start + i);
            uint256 interest;
            (interest, stepped) = this.accrueAt(stepped);
            total += interest;
        }
        (uint256 interestOnce,) = this.accrueAt(once);

        assertGt(interestOnce, 1_000, "an hour of 2.33% (40% on a 4% rate at target) on 400 USDC is 0.00106 USDC");
        assertApproxEqAbs(total, interestOnce, 1, "every second books the same as once");
        assertLt(stepped.interestRemainder, WAD);
    }

    Market internal stored;

    function accrueStored() external returns (uint256 interest) {
        Market memory m = stored;
        (interest,) = MarketLogic.accrue(m);
        stored = m;
    }

    /// @dev Accrues `m` every `step` seconds for `elapsed`, then once over the same time from the same start. In
    ///      storage, as memory would grow with every call
    function _steppedAndOnce(Market memory m, uint256 elapsed, uint256 step)
        internal
        returns (uint256 total, uint256 once, Market memory stepped, Market memory single)
    {
        uint256 start = vm.getBlockTimestamp();
        stored = m;
        vm.pauseGasMetering();
        for (uint256 t = step; t <= elapsed; t += step) {
            vm.warp(start + t);
            total += this.accrueStored();
        }
        vm.resumeGasMetering();
        stepped = stored;
        (once, single) = this.accrueAt(m);
    }

    /// @dev A day accrued every second books what one accrual books, to the unit: the integral is exact, the
    ///      compounding continuous, the remainder carried. 1M tokens (18 decimals) at 150% a year (100% utilization
    ///      at the ceiling stays there)
    function test_accrue_everySecondForADayBooksTheSame() public {
        Market memory m = _market(1_000_000e18, 1_000_000e18);
        m.rateAtTarget = uint64(MAX);
        (uint256 total, uint256 once, Market memory stepped, Market memory single) = _steppedAndOnce(m, 1 days, 1);
        assertApproxEqRel(once, 1_000_000e18 * 0.004118044981335031e18 / WAD, 1e9, "a day at 150%");
        assertApproxEqAbs(total, once, 1, "every second books the same as once");
        assertEq(stepped.rateAtTarget, single.rateAtTarget);
    }

    /// @dev The same while the rate at target moves (100%, from 4%): what's left is the stored rate at target's own
    ///      rounding, a unit down per accrual, which charges a hair less (Morpho's rate at target rounds the same)
    function test_accrue_everySecondWhileAdaptingDriftsOnlyByTheRateAtTargetsUnit() public {
        Market memory m = _market(1_000_000e18, 1_000_000e18);
        (uint256 total, uint256 once, Market memory stepped, Market memory single) = _steppedAndOnce(m, 1 days, 1);
        assertLe(total, once, "never more than once");
        assertLe(single.rateAtTarget - stepped.rateAtTarget, 1 days, "a unit per second at most");
        // Half a unit in 1.3e9 per second on average, over a day: under 3.4e-5 of the rate, half that of the interest
        assertApproxEqRel(total, once, 2e13);
    }

    /// @dev A year at a constant 150% books e^1.5 − 1 = 348.2% of the debt, accrued once or every hour
    function test_accrue_compoundsAYearAt150Percent() public {
        Market memory m = _market(1_000e18, 1_000e18);
        m.rateAtTarget = uint64(MAX);
        (uint256 total, uint256 once,,) = _steppedAndOnce(m, 365 days, 1 hours);
        assertApproxEqRel(once, 3_481_689069822634726030, 1e9, "1000 (e^1.5 - 1)"); // 4 · MAX · year = 1.4999999999
        // The one accrual compounds through expWad (past the series): its unit in 1e18
        assertApproxEqRel(total, once, 10, "hourly books the same");
    }

    /// @dev A month at a constant 10% (the target, rate at target 10%) books e^(0.1 / 12) − 1 = 0.837%
    function test_accrue_compoundsAMonthAt10Percent() public {
        Market memory m = _market(1_000e18, 900e18);
        m.rateAtTarget = uint64(0.1e18 / YEAR);
        vm.warp(block.timestamp + YEAR / 12);
        (uint256 interest,) = MarketLogic.accrue(m);
        assertApproxEqAbs(interest, 7_531336985804439261, 1e3, "900 (e^(0.1 / 12) - 1)");
    }

    /// @dev Splitting a period into up to 50 uneven accruals books the same interest and lands on the same rate at
    ///      target as one accrual. At 100% utilization (it stays there) the rate at target moves the whole time
    function testFuzz_accrue_splittingBooksTheSame(uint256 rateAtTarget, uint256 borrows, uint256 elapsed, uint256 seed)
        public
    {
        rateAtTarget = bound(rateAtTarget, MIN, MAX);
        borrows = bound(borrows, 1e6, 1e30);
        uint256 steps = bound(seed, 2, 50);
        elapsed = bound(elapsed, steps, 120 days);
        Market memory m = _market(borrows, borrows);
        m.rateAtTarget = uint64(rateAtTarget);
        uint256 start = vm.getBlockTimestamp();

        Market memory stepped = m;
        uint256 total;
        uint256 at;
        for (uint256 i; i < steps; ++i) {
            at = i == steps - 1
                ? elapsed
                : bound(uint256(keccak256(abi.encode(seed, i))), at + 1, elapsed - (steps - 1 - i));
            vm.warp(start + at);
            uint256 interest;
            (interest, stepped) = this.accrueAt(stepped);
            total += interest;
        }
        (uint256 once, Market memory single) = this.accrueAt(m);

        assertApproxEqRel(stepped.rateAtTarget, single.rateAtTarget, steps * 3.2e9, "the rate at target");
        // The stored rate at target's unit per step, on the interest; and a unit of the asset per step
        assertApproxEqAbs(total, once, steps + once * steps * 3.2e9 / WAD, "the interest");
    }

    /// @dev No borrows, no interest, but the rate at target still adapts: an idle market drifts down to the floor.
    ///      An empty one doesn't move (nothing to read demand from), so a market starts where it is at its first supply
    function test_accrue_noBorrowsStillAdapts() public {
        Market memory m = _market(1_000e18, 0);
        vm.warp(block.timestamp + DOUBLING);
        (uint256 interest, uint256 reserveAssets) = MarketLogic.accrue(m);
        uint256 reserveShares = MarketLogic.reserveShares(m, reserveAssets, 1_000e18);
        assertEq(interest, 0);
        assertEq(reserveShares, 0);
        assertEq(m.lastAccrual, block.timestamp);
        assertApproxEqRel(m.rateAtTarget, RATE / 2, 1e12, "halved");

        Market memory empty = _market(0, 0);
        vm.warp(block.timestamp + 30 days);
        MarketLogic.accrue(empty);
        assertEq(empty.rateAtTarget, RATE, "an empty market stays");
        assertEq(empty.lastAccrual, block.timestamp, "and moves on");
    }

    /// @dev A century without a touch, at full utilization: the accrual doesn't revert, the rate at target ends at
    ///      the ceiling, and the integral (≈ 150) is past what an accrual compounds: e^15 − 1 at most
    function test_accrue_untouchedForDecades() public {
        Market memory m = _market(1_000e18, 1_000e18);
        vm.warp(block.timestamp + 100 * 365 days);
        (uint256 integral,) = MarketLogic.adaptiveRate(RATE, WAD, 100 * 365 days);
        assertApproxEqRel(integral, 149.979829e18, 1e12, "a century, ramp included");
        (uint256 interest,) = MarketLogic.accrue(m);
        assertEq(m.rateAtTarget, MAX);
        assertApproxEqRel(interest, 1_000e18 * 3_269_016.372472e18 / WAD, 1e12, "e^15 - 1");

        m = _market(1_000e18, 1_000e18);
        vm.warp(type(uint64).max);
        MarketLogic.accrue(m);
        assertEq(m.lastAccrual, type(uint64).max, "nor at the end of time");
    }

    function test_accrue_sameBlockIsNoop() public view {
        Market memory m = _market(1_000e18, 500e18);
        (uint256 interest,) = MarketLogic.accrue(m);
        assertEq(interest, 0);
        assertEq(m.totalBorrowAssets, 500e18);
        assertEq(m.rateAtTarget, RATE);
    }

    function test_supplyRate() public view {
        Market memory m = _market(1_000e18, 500e18);
        uint256 borrowRate = MarketLogic.borrowRate(m);
        // borrowRate · 50% · 90%
        assertApproxEqAbs(MarketLogic.supplyRate(m, borrowRate), borrowRate * 45 / 100, 1);
    }
}
