// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISenzuLens} from "../../src/interfaces/ISenzuLens.sol";
import {ISenzuPreviews} from "../../src/interfaces/ISenzuPreviews.sol";
import {DebtLanes} from "../../src/libraries/DebtLanes.sol";
import {HealthMath} from "../../src/libraries/HealthMath.sol";
import {LiquidationLogic} from "../../src/libraries/LiquidationLogic.sol";
import {MarketLogic} from "../../src/libraries/MarketLogic.sol";
import {
    CollateralInput,
    DebtInput,
    DebtTie,
    FeeCheckpoint,
    HealthResult,
    Holdings,
    Market,
    Rounding,
    Shape
} from "../../src/libraries/Types.sol";
import {SenzuPreviews} from "../../src/periphery/SenzuPreviews.sol";
import {FeeLedgerHarness} from "./FeeLedgerHarness.sol";
import {HarnessRewardToken, RewardLedgerHarness} from "./RewardLedgerHarness.sol";
import {RangeCollateral, SdkWorld} from "./SdkWorld.sol";
import {WriteOffHarness, WriteOffHarnessDeployer} from "./WriteOffHarness.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CommonBase} from "forge-std/Base.sol";

contract SdkPreviews is SenzuPreviews {
    constructor(address collateral_) SenzuPreviews(collateral_) {}

    function liquidationPrices(RangeCollateral memory c, DebtInput[] memory debts, uint256 penalty)
        external
        view
        returns (LiquidationPrices memory)
    {
        CollateralInput memory pair;
        (pair.token0, pair.token1) = (c.shape.token0, c.shape.token1);
        (pair.price0Wad, pair.price1Wad, pair.decimals0, pair.decimals1) =
        (c.price0Wad, c.price1Wad, c.decimals0, c.decimals1);
        (pair.sigma0Wad, pair.sigma1Wad) = (c.sigma0Wad, c.sigma1Wad);
        return
            _liquidationPrices(_ofRange(c.shape.sqrtPaX96, c.shape.sqrtPbX96, c.accountLiquidity), pair, debts, penalty);
    }
}

/**
 *  @title  SdkVectorLines
 *  @notice One SDK vector per call, for `script/SdkVectors.s.sol`: draws inputs, runs them through the contracts
 *          (SdkWorld wraps the libraries; SenzuLens runs against it) and formats the line.
 */
contract SdkVectorLines is CommonBase {
    uint256 internal constant WAD = 1e18;

    SdkWorld internal world;
    SdkPreviews internal lens;
    WriteOffHarness internal writeOffs;
    uint256 internal seed = 0xCA3E1;
    uint256 internal _lastDebtAsset;

    constructor() {
        world = new SdkWorld();
        world.setPosition(TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, 0, 1);
        lens = new SdkPreviews(address(world));
        writeOffs = new WriteOffHarnessDeployer().deploy();
    }

    /*  ================================================
                          Uniswap math
        ================================================  */

    function lineMulDiv() external returns (string memory) {
        (uint256 a, uint256 b, uint256 d) = (_any(), _any(), _any());
        if (_chance(4)) d = _any() >> 128; // more results that fit
        string memory out1;
        string memory out2;
        try world.mulDiv(a, b, d) returns (uint256 r) {
            out1 = vm.toString(r);
        } catch (bytes memory reason) {
            out1 = _err(reason);
        }
        try world.mulDivRoundingUp(a, b, d) returns (uint256 r) {
            out2 = vm.toString(r);
        } catch (bytes memory reason) {
            out2 = _err(reason);
        }
        return string.concat(_u(a), _u(b), _u(d), "=> ", out1, " ", out2);
    }

    function lineSqrt() external returns (string memory) {
        uint256 x = _any();
        return string.concat(_u(x), "=> ", vm.toString(world.sqrt(x)));
    }

    function lineTick() external returns (string memory) {
        int24 tick = _chance(10) ? int24(int256(_between(0, 2_000_000)) - 1_000_000) : _tick();
        uint160 sqrtPrice =
            _chance(10) ? uint160(_any()) : uint160(_between(TickMath.MIN_SQRT_PRICE - 2, TickMath.MAX_SQRT_PRICE + 2));
        if (_chance(3)) sqrtPrice = _sqrtAtTick(_tick());
        string memory out1;
        string memory out2;
        try world.sqrtPriceAtTick(tick) returns (uint160 r) {
            out1 = vm.toString(uint256(r));
        } catch (bytes memory reason) {
            out1 = _err(reason);
        }
        try world.tickAtSqrtPrice(sqrtPrice) returns (int24 r) {
            out2 = vm.toString(int256(r));
        } catch (bytes memory reason) {
            out2 = _err(reason);
        }
        return string.concat(vm.toString(int256(tick)), " ", _u(sqrtPrice), "=> ", out1, " ", out2);
    }

    function lineDelta() external returns (string memory) {
        uint160 a = _chance(10) ? uint160(_any()) : _sqrtAtTick(_tick());
        uint160 b = _chance(10) ? uint160(_any()) : _sqrtAtTick(_tick());
        if (_chance(20)) a = 0;
        uint128 liquidity = uint128(_any());
        bool roundUp = _chance(2);
        string memory out1;
        string memory out2;
        try world.amount0Delta(a, b, liquidity, roundUp) returns (uint256 r) {
            out1 = vm.toString(r);
        } catch (bytes memory reason) {
            out1 = _err(reason);
        }
        try world.amount1Delta(a, b, liquidity, roundUp) returns (uint256 r) {
            out2 = vm.toString(r);
        } catch (bytes memory reason) {
            out2 = _err(reason);
        }
        return string.concat(_u(a), _u(b), _u(liquidity), _b(roundUp), "=> ", out1, " ", out2);
    }

    function lineNext() external returns (string memory) {
        uint160 sqrtPrice = _chance(10) ? uint160(_any()) : _sqrtAtTick(_tick());
        if (_chance(30)) sqrtPrice = 0;
        uint128 liquidity = _chance(30) ? 0 : uint128(_any());
        uint256 amount = _chance(3) ? _any() : _any() >> 128;
        if (_chance(30)) amount = 0;
        (bool zeroForOne, bool input) = (_chance(2), _chance(2));
        string memory out;
        try world.nextSqrtPrice(sqrtPrice, liquidity, amount, zeroForOne, input) returns (uint160 r) {
            out = vm.toString(uint256(r));
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(_u(sqrtPrice), _u(liquidity), _u(amount), _b(zeroForOne), _b(input), "=> ", out);
    }

    function lineLiquidity() external returns (string memory) {
        uint160 p = _chance(10) ? uint160(_any()) : _sqrtAtTick(_tick());
        uint160 a = _chance(10) ? uint160(_any()) : _sqrtAtTick(_tick());
        uint160 b = _chance(10) ? uint160(_any()) : _sqrtAtTick(_tick());
        if (_chance(20)) b = a;
        uint128 liquidity = uint128(_any());
        (uint256 x, uint256 y) = (_chance(2) ? _any() : _any() >> 100, _chance(2) ? _any() : _any() >> 100);
        string memory out1;
        string memory out2;
        try world.amountsForLiquidity(p, a, b, liquidity) returns (uint256 r0, uint256 r1) {
            out1 = string.concat(_u(r0), vm.toString(r1));
        } catch (bytes memory reason) {
            string memory e = _err(reason);
            out1 = string.concat(e, " ", e);
        }
        try world.liquidityForAmounts(p, a, b, x, y) returns (uint128 r) {
            out2 = vm.toString(uint256(r));
        } catch (bytes memory reason) {
            out2 = _err(reason);
        }
        return string.concat(_u(p), _u(a), _u(b), _u(liquidity), _u(x), _u(y), "=> ", out1, " ", out2);
    }

    /*  ================================================
                             Health
        ================================================  */

    function lineSqrtFromUsd() external returns (string memory) {
        (uint256 p0, uint256 p1) = _chance(8) ? (_any(), _any()) : (_price(), _price());
        (uint8 d0, uint8 d1) = (_decimals(), _decimals());
        string memory out;
        try world.sqrtPriceFromUsd(p0, p1, d0, d1) returns (uint160 r) {
            out = vm.toString(uint256(r));
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(_u(p0), _u(p1), _u(d0), _u(d1), "=> ", out);
    }

    function lineEvaluate() external returns (string memory) {
        RangeCollateral memory c = _collateral();
        if (_chance(20)) c.sigma0Wad = _any();
        if (_chance(20)) c.price1Wad = _chance(2) ? 0 : _any();
        uint256 value = _valueOf(c);

        DebtInput[] memory debts = new DebtInput[](_between(0, 3));
        string memory debtText;
        for (uint256 i; i < debts.length; ++i) {
            DebtTie tie = DebtTie(_between(0, 2));
            debts[i] = DebtInput({
                valueUsdWad: _chance(10) ? _any() : value * _between(0, 120) / 100 / debts.length,
                sigmaWad: _chance(10) ? _between(0, 2e18) : _between(1e18, 3e18),
                tie: tie
            });
            debtText = string.concat(debtText, _u(debts[i].valueUsdWad), _u(debts[i].sigmaWad), _u(uint8(tie)));
        }
        uint256 penalty = _chance(10) ? _any() : _between(1e18, 1.3e18);

        string memory out;
        try world.evaluate(c, debts, penalty) returns (HealthResult memory h) {
            out = string.concat(
                vm.toString(h.minSurplusUsdWad), " ", _u(h.healthWad), _u(h.collateralUsdWad), vm.toString(h.debtUsdWad)
            );
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(_collateralText(c), _u(penalty), _u(debts.length), debtText, "=> ", out);
    }

    /// @dev Holdings of any curve, not only a range's: the prices the core asks an adapter about, and its check of the
    ///      answer
    function lineEvaluateHoldings() external returns (string memory) {
        CollateralInput memory pair;
        (pair.price0Wad, pair.decimals0, pair.sigma0Wad) = (_price(), _decimals(), _sigma());
        (pair.price1Wad, pair.decimals1, pair.sigma1Wad) = (_price(), _decimals(), _sigma());
        if (_chance(20)) pair.price1Wad = 0;
        string memory text = string.concat(
            _u(pair.price0Wad), _u(pair.decimals0), _u(pair.sigma0Wad), _u(pair.price1Wad), _u(pair.decimals1)
        );
        text = string.concat(text, _u(pair.sigma1Wad));

        Holdings memory h;
        for (uint256 i; i < HealthMath.PRICES; ++i) {
            (h.amounts0[i], h.amounts1[i]) = (_amount(), _amount());
            text = string.concat(text, _u(h.amounts0[i]), _u(h.amounts1[i]));
        }
        uint256 value;
        try world.evaluateHoldings(pair, h, new DebtInput[](0), WAD) returns (HealthResult memory r) {
            value = r.collateralUsdWad;
        } catch {}
        if (value > type(uint256).max / 2) value = type(uint256).max / 2; // debts up to 120% of it stay in range

        DebtInput[] memory debts = new DebtInput[](_between(0, 2));
        text = string.concat(text, _u(debts.length));
        for (uint256 i; i < debts.length; ++i) {
            debts[i] = DebtInput({
                valueUsdWad: _chance(10) ? _any() : value / 100 * _between(0, 120) / debts.length,
                sigmaWad: _chance(10) ? _between(0, 2e18) : _between(1e18, 3e18),
                tie: DebtTie(_between(0, 2))
            });
            text = string.concat(text, _u(debts[i].valueUsdWad), _u(debts[i].sigmaWad), _u(uint8(debts[i].tie)));
        }
        uint256 penalty = _chance(10) ? _any() : _between(1e18, 1.3e18);
        text = string.concat(text, _u(penalty), "=> ");

        try world.sqrtPrices(pair) returns (uint160[5] memory prices) {
            for (uint256 i; i < prices.length; ++i) {
                text = string.concat(text, _u(prices[i]));
            }
        } catch (bytes memory reason) {
            text = string.concat(text, _err(reason), " ");
        }
        try world.evaluateHoldings(pair, h, debts, penalty) returns (HealthResult memory r) {
            return string.concat(
                text,
                "| ",
                vm.toString(r.minSurplusUsdWad),
                " ",
                _u(r.healthWad),
                _u(r.collateralUsdWad),
                vm.toString(r.debtUsdWad)
            );
        } catch (bytes memory reason) {
            return string.concat(text, "| ", _err(reason));
        }
    }

    /// @dev A token amount an adapter may report: often none, mostly up to 1e30, sometimes anything
    function _amount() internal returns (uint256) {
        if (_chance(5)) return 0;
        return _chance(10) ? _any() : _logBetween(1, 1e30);
    }

    function lineCollateralUsdAt() external returns (string memory) {
        RangeCollateral memory c = _collateral();
        (uint256 q0, uint256 q1) = _chance(10) ? (_any(), _any()) : (_price(), _price());
        if (_chance(20)) q1 = 0;
        string memory out;
        try world.collateralUsdAt(c, q0, q1) returns (uint256 r) {
            out = vm.toString(r);
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(
            _u(c.shape.sqrtPaX96),
            _u(c.shape.sqrtPbX96),
            _u(c.accountLiquidity),
            _u(c.price0Wad),
            _u(c.decimals0),
            _u(c.price1Wad),
            _u(c.decimals1),
            _u(q0),
            _u(q1),
            "=> ",
            out
        );
    }

    /*  ================================================
                            Markets
        ================================================  */

    function lineShares() external returns (string memory) {
        (uint256 amount, uint256 totalAssets, uint256 totalShares) =
            _chance(5) ? (_any(), _any(), _any()) : (_any() >> 128, _any() >> 128, _any() >> 120);
        bool up = _chance(2);
        string memory out1;
        string memory out2;
        try world.toShares(amount, totalAssets, totalShares, up) returns (uint256 r) {
            out1 = vm.toString(r);
        } catch (bytes memory reason) {
            out1 = _err(reason);
        }
        try world.toAssets(amount, totalAssets, totalShares, up) returns (uint256 r) {
            out2 = vm.toString(r);
        } catch (bytes memory reason) {
            out2 = _err(reason);
        }
        return string.concat(_u(amount), _u(totalAssets), _u(totalShares), _b(up), "=> ", out1, " ", out2);
    }

    function lineExp() external returns (string memory) {
        int256 x;
        if (_chance(4)) x = int256(_any());
        else if (_chance(3)) x = int256(_logBetween(1, 5e18)) * (_chance(2) ? int256(1) : -1);
        else x = int256(_between(0, 190e18)) - 50e18;
        string memory out;
        try world.expWad(x) returns (int256 r) {
            out = vm.toString(r);
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(vm.toString(x), " => ", out);
    }

    function lineLn() external returns (string memory) {
        int256 x;
        if (_chance(5)) x = int256(_any());
        else if (_chance(10)) x = -int256(_between(0, 1e30));
        else if (_chance(10)) x = int256(_between(0, 3));
        else if (_chance(4)) x = int256(_between(0.5e18, 2e18));
        else x = int256(_logBetween(1, type(uint256).max >> 1));
        string memory out;
        try world.lnWad(x) returns (int256 r) {
            out = vm.toString(r);
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(vm.toString(x), " => ", out);
    }

    function lineAdaptiveRate() external returns (string memory) {
        uint256 rateAtTarget = _rateAtTarget();
        uint256 util = _chance(10) ? _any() >> 70 : _chance(5) ? _between(0.85e18, 1e18) : _between(0, 1e18);
        if (_chance(20)) util = _any(); // past int256 too: the casts wrap, and the curve can overflow
        uint256 elapsed = _chance(10) ? 0 : _chance(5) ? _between(0, type(uint64).max) : _logBetween(1, 5 * 365 days);
        string memory out;
        try world.adaptiveRate(rateAtTarget, util, elapsed) returns (uint256 integral, uint256 end, int256 growth) {
            out = string.concat(_u(integral), _u(end), vm.toString(growth));
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(_u(rateAtTarget), _u(util), _u(elapsed), "=> ", out);
    }

    function lineAccrue() external returns (string memory) {
        Market memory m = _market();
        uint256 supplyShares = _chance(10) ? _any() : _any() >> 130;
        uint256 nowTs = _chance(10) ? _between(0, type(uint64).max) : m.lastAccrual + _between(0, 5 * 365 days);
        if (nowTs > type(uint64).max) nowTs = type(uint64).max;
        vm.warp(nowTs);

        string memory out;
        try world.accrue(m, supplyShares) returns (uint256 interest, uint256 reserveShares, Market memory next) {
            out = string.concat(
                string.concat(_u(interest), _u(reserveShares), _u(next.totalSupplyAssets)),
                string.concat(_u(next.totalBorrowAssets), _u(next.lastAccrual), _u(next.interestRemainder)),
                vm.toString(uint256(next.rateAtTarget))
            );
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(
            string.concat(_u(m.totalSupplyAssets), _u(m.totalBorrowAssets), _u(m.totalBorrowShares)),
            string.concat(_u(m.lastAccrual), _u(m.reserveFactorWad), _u(m.interestRemainder), _u(m.rateAtTarget)),
            string.concat(_u(supplyShares), _u(nowTs)),
            "=> ",
            out
        );
    }

    function lineRates() external returns (string memory) {
        Market memory m = _market();
        string memory out;
        try world.marketRates(m) returns (uint256 util, uint256 borrowRate, uint256 supplyRate) {
            out = string.concat(_u(util), _u(borrowRate), vm.toString(supplyRate));
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(
            _u(m.totalSupplyAssets), _u(m.totalBorrowAssets), _u(m.reserveFactorWad), _u(m.rateAtTarget), "=> ", out
        );
    }

    function lineBorrow() external returns (string memory) {
        Market memory m = _market();
        uint256 cash = m.totalSupplyAssets - m.totalBorrowAssets;
        uint256 assets = _chance(10) ? _any() : (cash == 0 ? 0 : _between(0, cash + cash / 10));
        uint256 fee = _chance(3) ? 0 : (_chance(10) ? _any() : assets / _between(1, 1000));
        uint256 supplyShares = _chance(10) ? _any() : _any() >> 130;
        if (_chance(20)) {
            // Around a position's share cap (DebtLanes: under 2^119), on an empty market booking 1e6 shares a unit
            (m.totalSupplyAssets, m.totalBorrowAssets, m.totalBorrowShares) = (type(uint128).max, 0, 0);
            assets = _between((DebtLanes.MAX_SHARES >> 1) / 1e6, (DebtLanes.MAX_SHARES << 1) / 1e6);
        }

        string memory out;
        try world.addDebt(m, assets, fee, supplyShares) returns (
            uint256 shares, uint256 feeShares, Market memory next
        ) {
            out = string.concat(
                _u(shares),
                _u(feeShares),
                _u(next.totalSupplyAssets),
                _u(next.totalBorrowAssets),
                vm.toString(uint256(next.totalBorrowShares))
            );
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(
            string.concat(_u(m.totalSupplyAssets), _u(m.totalBorrowAssets), _u(m.totalBorrowShares)),
            string.concat(_u(assets), _u(fee), _u(supplyShares)),
            "=> ",
            out
        );
    }

    function lineRepay() external returns (string memory) {
        Market memory m = _market();
        // A position holds at most 2^119 - 1 shares (DebtLanes)
        uint256 maxShares = m.totalBorrowShares < DebtLanes.MAX_SHARES ? m.totalBorrowShares : DebtLanes.MAX_SHARES - 1;
        uint256 debtShares = _chance(20) ? 0 : _between(0, maxShares);
        uint256 assets = _chance(10) ? _any() : _between(0, uint256(m.totalBorrowAssets) * 2);
        string memory out;
        try world.repayAmounts(m, debtShares, assets) returns (uint256 repaid, uint256 shares) {
            out = string.concat(_u(repaid), vm.toString(shares));
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(_u(m.totalBorrowAssets), _u(m.totalBorrowShares), _u(debtShares), _u(assets), "=> ", out);
    }

    function lineWriteOff() external returns (string memory) {
        Market memory m = _market();
        // A position's lane holds 1 to 2^119 - 1 shares; past the market's total, the write-off reverts
        uint256 maxShares = m.totalBorrowShares < DebtLanes.MAX_SHARES ? m.totalBorrowShares : DebtLanes.MAX_SHARES - 1;
        uint256 debtShares = _chance(10) ? _between(1, DebtLanes.MAX_SHARES - 1) : _between(1, maxShares);
        // The last shares, which take all the debt
        if (_chance(4) && m.totalBorrowShares > 0) debtShares = maxShares;
        string memory out;
        try writeOffs.runWriteOff(m, debtShares) returns (Market memory next, uint256 left) {
            out = string.concat(
                _u(next.totalSupplyAssets), _u(next.totalBorrowAssets), _u(next.totalBorrowShares), vm.toString(left)
            );
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(
            _u(m.totalSupplyAssets), _u(m.totalBorrowAssets), _u(m.totalBorrowShares), _u(debtShares), "=> ", out
        );
    }

    function lineRepayBook() external returns (string memory) {
        Market memory m = _market();
        uint256 maxShares = m.totalBorrowShares < DebtLanes.MAX_SHARES ? m.totalBorrowShares : DebtLanes.MAX_SHARES - 1;
        uint256 debtShares = _chance(10) ? _between(1, DebtLanes.MAX_SHARES - 1) : _between(1, maxShares);
        // The last shares, which take all the debt
        if (_chance(4) && m.totalBorrowShares > 0) debtShares = maxShares;
        uint256 assets = _chance(3) ? _any() : _logBetween(1, uint256(m.totalBorrowAssets) + 2);
        string memory out;
        try writeOffs.runRepay(m, debtShares, assets) returns (uint256 repaid, Market memory next, uint256 left) {
            out = string.concat(
                _u(repaid),
                _u(next.totalSupplyAssets),
                _u(next.totalBorrowAssets),
                _u(next.totalBorrowShares),
                vm.toString(left)
            );
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(
            _u(m.totalSupplyAssets),
            _u(m.totalBorrowAssets),
            _u(m.totalBorrowShares),
            _u(debtShares),
            _u(assets),
            "=> ",
            out
        );
    }

    /// @dev A liquidation from the health check's numbers: mostly sizes a position has, with zeros and extremes
    /// @dev 1 in 4 in one of two bands random draws miss: taking every unit while still repaying the whole offer (a
    ///      debt worth 0, so the penalty is borne whole, and a repayment worth between the collateral / the penalty
    ///      and the collateral / 1.02), or taking exactly every unit of a few for more than the cover (a large debt,
    ///      so the penalty is 1.02)
    function lineSeize() external returns (string memory) {
        uint256[8] memory v = _seizeInputs();
        string memory out;
        try world.seizeFor(v[0], v[1], v[2], v[3], uint8(v[4]), v[5], v[6], v[7]) returns (
            uint256 seized, uint256 repay
        ) {
            out = string.concat(_u(seized), vm.toString(repay));
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(_seizeText(v), "=> ", out);
    }

    /// @dev `lineSeize`'s inputs with the fee's: a fee setting (none, the default, the cap or between) and whether
    ///      another debt remains; 1 in 3 the debts on either side of the collateral / 1.02, where the fee stops, and 1 in
    ///      8 no debt and collateral worth exactly the repayment with the penalty, the least that takes every unit
    function lineSeizeFee() external returns (string memory) {
        uint256[8] memory v = _seizeInputs();
        if (_chance(3) && v[0] <= type(uint256).max / 1e18) v[1] = v[0] * 1e18 / 1.02e18 + _between(0, 1);
        if (_chance(8)) {
            try world.seizeUsd(v) returns (uint256 worth) {
                if (worth > 0) (v[0], v[1]) = (worth, 0);
            } catch {}
        }
        uint256 feeWad = _chance(5) ? 0 : _chance(4) ? 0.1e18 : _chance(4) ? 0.2e18 : _between(0, 0.2e18);
        bool other = _chance(3);
        string memory out;
        try world.seizeForWithFee(v, feeWad, other) returns (uint256 seized, uint256 repay, uint256 fee) {
            out = string.concat(_u(seized), _u(repay), vm.toString(fee));
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(_seizeText(v), _u(feeWad), _u(other ? 1 : 0), "=> ", out);
    }

    function _seizeText(uint256[8] memory v) internal pure returns (string memory) {
        return string.concat(
            string.concat(_u(v[0]), _u(v[1]), _u(v[2]), _u(v[3]), _u(v[4])), string.concat(_u(v[5]), _u(v[6]), _u(v[7]))
        );
    }

    /// @dev collateralUsd debtUsd debt priceWad decimals penaltyWad maxRepay units
    function _seizeInputs() internal returns (uint256[8] memory v) {
        if (_chance(4)) {
            v[0] = _logBetween(1e6, 1e30);
            v[3] = _logBetween(1e10, 1e24);
            v[4] = _between(0, 18);
            v[5] = _between(1.03e18, 1.25e18);
            v[6] = type(uint256).max;
            uint256 cover = v[0] * 1e18 / 1.02e18;
            if (_chance(2)) {
                v[2] = _between(v[0] * 1e18 / v[5] + 1, cover) * 10 ** v[4] / v[3] + 1;
                v[7] = _logBetween(1e3, 1e24);
            } else {
                v[1] = v[0] * 100;
                v[2] = _between(cover, 2 * cover) * 10 ** v[4] / v[3] + 1;
                v[7] = _between(1, 3);
            }
        } else {
            v[0] = _chance(10) ? _any() : _logBetween(1, 1e40);
            v[1] = _chance(10) ? 0 : _chance(10) ? _any() : _logBetween(1, 1e40);
            v[2] = _chance(10) ? _any() : _logBetween(1, 1e36);
            v[3] = _chance(10) ? _any() >> _between(0, 200) : _logBetween(1, 1e30);
            // Past 77 decimals 10 ** decimals overflows
            v[4] = _chance(20) ? _between(37, 80) : _between(0, 36);
            v[5] = _chance(5) ? _any() >> _between(150, 256) : _between(1.02e18, 1.25e18);
            v[6] = _chance(3) ? type(uint256).max : _any() >> _between(0, 256);
            v[7] = _chance(10) ? _any() : _logBetween(1, 1e36);
        }
    }

    /// @dev A random sequence of reward-ledger steps on 2 positions and 3 accounts: each step's result ("-", what a
    ///      payout paid, or "err", which ends it), then the ledger's state
    function lineRewardLedger() external returns (string memory) {
        uint256 n = _between(1, 30);
        uint256[7][] memory acts = new uint256[7][](n);
        uint256[3] memory liquidity = [uint256(0), _logBetween(1, 1e24), _logBetween(1, 1e24)];
        for (uint256 i; i < n; ++i) {
            uint256 kind = _between(0, 21);
            kind = kind < 6 ? 0 : kind < 9 ? 1 : kind < 15 ? 2 : kind < 19 ? 4 : 3;
            uint256 lp = _between(1, 2);
            if (kind == 0) {
                uint256 arrived = _chance(8) ? 0 : _chance(16) ? _any() : _logBetween(1, 1e24);
                acts[i] = [kind, lp, arrived, _chance(20) ? 0 : liquidity[lp], 0, 0, 0];
            } else if (kind == 1) {
                acts[i] = [kind, _chance(16) ? _any() : _logBetween(1, 1e24), 0, 0, 0, 0, 0];
            } else if (kind == 2) {
                uint256 balance = _chance(5) ? 0 : _chance(16) ? _any() : _between(0, liquidity[lp]);
                acts[i] = [kind, _between(1, 3), lp, balance, 0, 0, 0];
            } else if (kind == 4) {
                uint256 fromBalance = _chance(10) ? 0 : _between(1, liquidity[lp] + 1);
                uint256 toBalance = _chance(3) ? 0 : _between(0, liquidity[lp]);
                uint256 units = _chance(10)
                    ? 0
                    : _chance(4)
                        ? fromBalance
                        : _chance(8)
                            ? _between(1, liquidity[lp] + 1)
                            : _between(1, fromBalance > 0 ? fromBalance : liquidity[lp] + 1);
                acts[i] = [kind, _between(1, 3), _between(1, 3), lp, fromBalance, toBalance, units];
            } else {
                acts[i] = [kind, _between(1, 3), lp, 0, 0, 0, 0];
            }
        }

        RewardLedgerHarness h = new RewardLedgerHarness(new HarnessRewardToken());
        string memory inputs = _u(n);
        string memory out;
        bool reverted;
        for (uint256 i; i < n; ++i) {
            uint256[7] memory a = acts[i];
            inputs = string.concat(inputs, _u(a[0]), _u(a[1]), _u(a[2]), _u(a[3]), _u(a[4]), _u(a[5]), _u(a[6]));
            if (reverted) continue;
            bool ok = true;
            uint256 paid;
            string memory errTag;
            if (a[0] == 0) {
                try h.book(a[1], a[2], a[3]) {}
                catch (bytes memory reason) {
                    ok = false;
                    errTag = _err(reason);
                }
            } else if (a[0] == 1) {
                try h.hold(a[1]) {}
                catch (bytes memory reason) {
                    ok = false;
                    errTag = _err(reason);
                }
            } else if (a[0] == 2) {
                try h.checkpoint(address(uint160(a[1])), a[2], a[3]) {}
                catch (bytes memory reason) {
                    ok = false;
                    errTag = _err(reason);
                }
            } else if (a[0] == 4) {
                h.setBalance(address(uint160(a[1])), a[3], a[4]);
                try h.seize(a[3], address(uint160(a[1])), address(uint160(a[2])), a[5], a[6]) {}
                catch (bytes memory reason) {
                    ok = false;
                    errTag = _err(reason);
                }
            } else {
                try h.pay(address(uint160(a[1])), a[2]) returns (uint256 amount) {
                    paid = amount;
                } catch (bytes memory reason) {
                    ok = false;
                    errTag = _err(reason);
                }
            }
            if (!ok) {
                out = string.concat(out, errTag);
                reverted = true;
            } else {
                out = string.concat(out, a[0] == 3 ? _u(paid) : "- ");
            }
        }
        if (!reverted) out = string.concat(out, "| ", _ledgerState(h));
        return string.concat(inputs, "=> ", out);
    }

    function _ledgerState(RewardLedgerHarness h) internal view returns (string memory out) {
        for (uint256 lp = 1; lp <= 2; ++lp) {
            out = string.concat(out, _u(h.rewardGrowthX128(lp)), _u(h.positionRewards(lp)));
        }
        out = string.concat(out, _u(h.rewardsHeld()));
        for (uint256 account = 1; account <= 3; ++account) {
            for (uint256 lp = 1; lp <= 2; ++lp) {
                (uint256 growth, uint256 owed) = h.rewardCheckpoints(address(uint160(account)), lp);
                out = string.concat(out, _u(growth), _u(owed));
            }
        }
    }

    /// @dev A random sequence of fee-ledger steps on one position and 3 accounts, each drawn from the state so far:
    ///      each step's result ("-", what a collect paid, or "err", which ends it), then the ledger's state
    function lineFeeLedger() external returns (string memory) {
        uint256 n = _between(1, 30);
        FeeLedgerHarness h = new FeeLedgerHarness(new HarnessRewardToken());
        string memory inputs = _u(n);
        string memory out;
        bool reverted;
        for (uint256 i; i < n; ++i) {
            uint256[4] memory a = _feeStep(h);
            inputs = string.concat(inputs, _u(a[0]), _u(a[1]), _u(a[2]), _u(a[3]));
            if (reverted) continue;
            (bool ok, string memory result) = _runFeeStep(h, a);
            out = string.concat(out, result);
            reverted = !ok;
        }
        if (!reverted) out = string.concat(out, "| ", _feeLedgerState(h));
        return string.concat(inputs, "=> ", out);
    }

    /// @dev kind a b c: 0 accrue amount, 1 mint account n, 2 burn account n, 3 collect account, 4 seize src dst n
    function _feeStep(FeeLedgerHarness h) internal returns (uint256[4] memory a) {
        uint256 kind = _between(0, 19);
        kind = kind < 5 ? 0 : kind < 10 ? 1 : kind < 13 ? 2 : kind < 16 ? 3 : 4;
        // Mostly what can succeed, so most sequences run to their end: an accrual needs units, a burn or seize of
        // more than the balance reverts
        if (kind == 0 && h.totalUnits() == 0 && !_chance(20)) kind = 1;
        uint256 account = _between(1, 3);
        uint256 balance = h.balances(address(uint160(account)));
        if (kind == 0) {
            uint256 amount = _chance(40) ? _any() >> _between(100, 140) : _chance(8) ? 0 : _logBetween(1, 1e24);
            a = [kind, amount, 0, 0];
        } else if (kind == 1) {
            a = [kind, account, _chance(8) ? 0 : _logBetween(1, 1e18), 0];
        } else if (kind == 2) {
            a = [kind, account, _chance(40) ? balance + 1 : _chance(3) ? balance : _between(0, balance), 0];
        } else if (kind == 3) {
            a = [kind, account, 0, 0];
        } else {
            // From the next account holding units, if any
            for (uint256 j; j < 3 && balance == 0; ++j) {
                account = account % 3 + 1;
                balance = h.balances(address(uint160(account)));
            }
            uint256 dst = _between(1, 3);
            uint256 units = dst == account
                ? _between(0, balance)
                : _chance(40) ? balance + 1 : _chance(3) ? balance : _chance(10) ? 0 : _between(1, balance);
            a = [kind, account, dst, units];
        }
    }

    function _runFeeStep(FeeLedgerHarness h, uint256[4] memory a) internal returns (bool, string memory) {
        address account = address(uint160(a[1]));
        if (a[0] == 0) {
            try h.accrue(a[1]) {}
            catch (bytes memory reason) {
                return (false, _err(reason));
            }
        } else if (a[0] == 1) {
            try h.mint(account, a[2]) {}
            catch (bytes memory reason) {
                return (false, _err(reason));
            }
        } else if (a[0] == 2) {
            try h.burn(account, a[2]) {}
            catch (bytes memory reason) {
                return (false, _err(reason));
            }
        } else if (a[0] == 3) {
            uint256 lp = h.LP();
            vm.prank(account);
            try h.collectFees(account, lp, address(h)) returns (uint256 fee0, uint256) {
                return (true, _u(fee0));
            } catch (bytes memory reason) {
                return (false, _err(reason));
            }
        } else {
            try h.seizeAndMove(account, address(uint160(a[2])), a[3]) {}
            catch (bytes memory reason) {
                return (false, _err(reason));
            }
        }
        return (true, "- ");
    }

    function _feeLedgerState(FeeLedgerHarness h) internal view returns (string memory out) {
        (uint256 growth,, uint128 held,) = h.fees(h.LP());
        out = string.concat(_u(growth), _u(held), _u(h.pending0()));
        for (uint256 account = 1; account <= 3; ++account) {
            (uint256 mark,, uint128 owed,) = h.checkpoints(address(uint160(account)), h.LP());
            out = string.concat(out, _u(h.balances(address(uint160(account)))), _u(mark), _u(owed));
        }
    }

    /// @dev A seize's merged bookmark: marks at or under the growth by any gap (fee growth wraps), units from one to
    ///      huge, now and then a holder so large that `held + units` wraps
    function lineMergeMark() external returns (string memory) {
        uint256 growth = _any();
        uint256 heldGap = _chance(4) ? _between(0, 100) : _chance(3) ? _any() : _any() >> 100;
        uint256 movedGap = _chance(4) ? heldGap : _chance(3) ? _any() : _any() >> 100;
        uint256 heldMark;
        uint256 movedMark;
        unchecked {
            (heldMark, movedMark) = (growth - heldGap, growth - movedGap);
        }
        uint256 held = _chance(4) ? 0 : _chance(20) ? _any() : _logBetween(1, 1 << 128);
        uint256 units = _chance(20) ? _any() : _logBetween(1, 1 << 128);
        string memory out;
        try world.mergeMark(heldMark, movedMark, held, units, growth) returns (uint256 mark) {
            out = vm.toString(mark);
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(_u(heldMark), _u(movedMark), _u(held), _u(units), _u(growth), "=> ", out);
    }

    function lineFees() external returns (string memory) {
        FeeCheckpoint memory cp = FeeCheckpoint(_any(), _any(), uint128(_any()), uint128(_any()));
        uint256 balance = _chance(10) ? _any() : _any() >> 128;
        (uint256 fg0, uint256 fg1) = (_any(), _any());
        if (_chance(3)) {
            (uint256 add0, uint256 add1) = (_any() >> 140, _any() >> 140);
            // Fee growth wraps, as in Uniswap
            unchecked {
                (fg0, fg1) = (cp.feeGrowthInside0X128 + add0, cp.feeGrowthInside1X128 + add1);
            }
        }
        string memory out;
        try world.feesPending(cp, balance, fg0, fg1) returns (uint256 o0, uint256 o1) {
            out = string.concat(_u(o0), vm.toString(o1));
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(
            string.concat(_u(cp.feeGrowthInside0X128), _u(cp.feeGrowthInside1X128), _u(cp.owed0), _u(cp.owed1)),
            string.concat(_u(balance), _u(fg0), _u(fg1)),
            "=> ",
            out
        );
    }

    /// @dev The protocol's cut of fees or rewards: mostly at the 5% cap or under, an amount from dust to huge
    function lineFeeCut() external returns (string memory) {
        uint256 amount = _chance(4) ? _between(0, 100) : _any();
        uint256 cutWad = _chance(5) ? _any() : _between(0, 0.05e18);
        string memory out;
        try world.feeCut(amount, cutWad) returns (uint256 cut) {
            out = cut > amount ? "err:panic:17" : string.concat(_u(cut), vm.toString(amount - cut));
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(_u(amount), _u(cutWad), "=> ", out);
    }

    /*  ================================================
                     Liquidations and lens
        ================================================  */

    function lineLiquidate() external returns (string memory) {
        RangeCollateral memory c = _worldCollateral();
        string memory head = string.concat(_collateralText(c), _otherText(), _penaltiesText());
        uint256 units = _chance(2) ? _between(1, 1e6) : _any() >> 140;
        if (units == 0) units = 1;
        world.setPosition(c.shape.sqrtPaX96, c.shape.sqrtPbX96, c.accountLiquidity, units);
        string memory debtText = _worldDebts(c, 50, 300);

        // Mostly a debt the position has, sometimes one it doesn't
        uint256 repayAsset = _chance(8) ? _between(0, 2) : _lastDebtAsset;
        uint256 maxRepay = _chance(2) ? type(uint256).max : _any() >> _between(100, 256);
        // Derived from `seed` without advancing it, so every generator after `liquidate` keeps its draws
        uint256 feeDraw = uint256(keccak256(abi.encode(seed, "liquidationFee")));
        uint64 feeWad = uint64(
            feeDraw % 5 == 0 ? 0 : feeDraw % 5 == 1 ? 0.1e18 : feeDraw % 5 == 2 ? 0.2e18 : (feeDraw >> 8) % (0.2e18 + 1)
        );
        world.setLiquidationFee(feeWad);
        string memory out;
        try world.liquidate(_asset(repayAsset), maxRepay) returns (
            uint256 seizedUnits, uint256 repayAssets, uint256 feeAssets
        ) {
            out = string.concat(_u(repayAssets), _u(seizedUnits), vm.toString(feeAssets));
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(head, debtText, _u(units), _u(repayAsset), _u(maxRepay), _u(feeWad), "=> ", out);
    }

    function lineSwap() external returns (string memory) {
        uint160 a = _sqrtAtTick(_tick());
        uint160 b = _chance(10) ? a : _sqrtAtTick(_tick());
        (uint256 x, uint256 y) = (_chance(5) ? 0 : _logBetween(1, 1e36), _chance(5) ? 0 : _logBetween(1, 1e36));
        uint160 p = _chance(5) ? 0 : _sqrtAtTick(_tick());
        uint256 fee = _chance(10) ? _any() >> 190 : _between(0, 0.01e18);
        (uint256 p0, uint256 p1) = (_price(), _price());
        (uint8 d0, uint8 d1) = (_decimals(), _decimals());
        world.setToken(world.TOKEN0(), p0, d0, 1e18);
        world.setToken(world.TOKEN1(), p1, d1, 1e18);

        string memory out;
        try lens.swapForRange(world.TOKEN0(), world.TOKEN1(), a, b, x, y, p, fee) returns (
            ISenzuPreviews.SwapQuote memory q
        ) {
            out = string.concat(_b(q.zeroForOne), _u(q.amountIn), vm.toString(q.amountOut));
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(
            string.concat(_u(a), _u(b), _u(x), _u(y), _u(p), _u(fee)),
            string.concat(_u(p0), _u(d0), _u(p1), _u(d1)),
            "=> ",
            out
        );
    }

    function lineMaxLeverage() external returns (string memory) {
        RangeCollateral memory c = _worldCollateral();
        string memory head = string.concat(_collateralText(c), _otherText(), _penaltiesText());
        uint256 mode = _between(0, 3);
        address borrowAsset = mode == 0 ? address(0) : _asset(mode - 1);
        string memory out;
        try lens.maxLeverage(
            world.TOKEN0(), world.TOKEN1(), c.shape.sqrtPaX96, c.shape.sqrtPbX96, borrowAsset
        ) returns (
            uint256 r
        ) {
            out = vm.toString(r);
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(head, _u(world.borrowFeeWad(address(world))), _u(mode), "=> ", out);
    }

    function lineMaxBorrow() external returns (string memory) {
        RangeCollateral memory c = _worldCollateral();
        string memory head =
            string.concat(_collateralText(c), _otherText(), _penaltiesText(), _u(world.borrowFeeWad(address(world))));
        world.setPosition(c.shape.sqrtPaX96, c.shape.sqrtPbX96, c.accountLiquidity, 1);
        string memory debtText = _worldDebts(c, 0, 60);

        uint256 asset = _between(0, 2);
        uint256 supply = _logBetween(1, type(uint128).max); // market totals are uint128
        uint256 borrowed = _between(0, supply);
        // The lens books the new borrow against the market's shares and merges it with the position's own: a share
        // price between 0.5 and 2, and the position's shares worth its debt in `asset` (its debt lines above)
        uint256 shares = borrowed == 0 ? _between(0, 1e6) : borrowed / 100 * _between(50, 200);
        if (shares > type(uint128).max) shares = type(uint128).max;
        uint256 accountShares =
            MarketLogic.toShares(world.debtOf(address(0), 0, _asset(asset)), borrowed, shares, Rounding.Down);
        world.setMarket(supply, borrowed, shares, accountShares);
        string memory out;
        try lens.maxBorrow(address(world), world.POSITION(), _asset(asset)) returns (uint256 r) {
            out = vm.toString(r);
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return
            string.concat(
                head, debtText, _u(asset), _u(supply), _u(borrowed), _u(shares), _u(accountShares), "=> ", out
            );
    }

    function linePreviewOpen() external returns (string memory) {
        RangeCollateral memory c = _worldCollateral();
        string memory head =
            string.concat(_collateralText(c), _otherText(), _penaltiesText(), _u(world.borrowFeeWad(address(world))));

        ISenzuPreviews.OpenParams memory p;
        (p.token0, p.token1, p.sqrtPaX96, p.sqrtPbX96) =
        (world.TOKEN0(), world.TOKEN1(), c.shape.sqrtPaX96, c.shape.sqrtPbX96);
        p.deposit0 = _chance(3) ? 0 : 10 ** c.decimals0 * _between(0, 1e6) * WAD / c.price0Wad;
        p.deposit1 = _chance(3) ? 0 : 10 ** c.decimals1 * _between(0, 1e6) * WAD / c.price1Wad;
        p.swap = _chance(2);
        uint256 n = _between(0, 2);
        p.borrowAssets = new address[](n);
        p.borrowAmounts = new uint256[](n);
        string memory borrowText;
        uint256 margin = p.deposit0 * c.price0Wad / 10 ** c.decimals0 + p.deposit1 * c.price1Wad / 10 ** c.decimals1;
        for (uint256 i; i < n; ++i) {
            uint256 asset = _between(0, 2);
            (uint256 price, uint8 decimals) = world.priceWithDecimals(_asset(asset));
            p.borrowAssets[i] = _asset(asset);
            p.borrowAmounts[i] = FullMath.mulDiv(margin * _between(0, 800) / 100, 10 ** decimals, price);
            borrowText = string.concat(borrowText, _u(asset), _u(p.borrowAmounts[i]));
        }

        // Every borrow is booked against the market's shares (one market for every asset in the world)
        uint256 marketBorrowed = _logBetween(1, type(uint128).max);
        uint256 marketShares = _logBetween(1, type(uint128).max);
        world.setMarket(type(uint128).max, marketBorrowed, marketShares, 0);

        string memory out;
        try lens.previewOpen(p) returns (ISenzuPreviews.OpenPreview memory r) {
            out = string.concat(
                string.concat(_u(r.liquidity), _u(r.amount0), _u(r.amount1), _u(r.collateralUsdWad)),
                string.concat(_u(r.marginUsdWad), _u(r.debtUsdWad), _u(r.leverageWad), _u(r.healthWad), _b(r.allowed)),
                string.concat(
                    _u(r.liquidation.token == world.TOKEN0() ? 0 : 1),
                    _u(r.liquidation.lowerWad),
                    vm.toString(r.liquidation.upperWad)
                )
            );
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(
            head,
            _u(p.deposit0),
            _u(p.deposit1),
            _b(p.swap),
            _u(n),
            borrowText,
            _u(marketBorrowed),
            _u(marketShares),
            "=> ",
            out
        );
    }

    /*  ================================================
                        Input generators
        ================================================  */

    function _rand() internal returns (uint256) {
        seed = uint256(keccak256(abi.encode(seed)));
        return seed;
    }

    function _chance(uint256 oneIn) internal returns (bool) {
        return _rand() % oneIn == 0;
    }

    function _between(uint256 lo, uint256 hi) internal returns (uint256) {
        if (hi <= lo) return lo;
        if (hi - lo == type(uint256).max) return _rand();
        return lo + _rand() % (hi - lo + 1);
    }

    /// @dev Any uint256, log-uniform in magnitude, with the edges showing up often
    function _any() internal returns (uint256) {
        uint256 r = _rand();
        if (r % 16 == 0) {
            uint256[8] memory edges =
                [uint256(0), 1, 2, type(uint256).max, type(uint256).max - 1, 1 << 128, type(uint160).max, 1 << 96];
            return edges[(r >> 8) % 8];
        }
        return _rand() >> (r % 256);
    }

    /// @dev log-uniform in [lo, hi]
    function _logBetween(uint256 lo, uint256 hi) internal returns (uint256 v) {
        uint256 bits = _between(BitMath.mostSignificantBit(lo), BitMath.mostSignificantBit(hi));
        v = (1 << bits) | (_rand() & ((1 << bits) - 1));
        if (v < lo) v = lo;
        if (v > hi) v = hi;
    }

    function _tick() internal returns (int24) {
        return int24(int256(_between(0, uint256(int256(2 * TickMath.MAX_TICK)))) + TickMath.MIN_TICK);
    }

    function _sqrtAtTick(int24 tick) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }

    /// @dev USD per whole token: $1e-6 to $1e6 mostly
    function _price() internal returns (uint256) {
        if (_chance(20)) return _logBetween(1, 1e40);
        return _logBetween(1e12, 1e24);
    }

    function _decimals() internal returns (uint8) {
        uint256 r = _rand() % 20;
        if (r == 0) return uint8(_between(0, 90));
        if (r < 7) return 6;
        if (r < 10) return 8;
        return 18;
    }

    function _sigma() internal returns (uint64) {
        return uint64(_chance(20) ? _between(0, 20e18) : _between(1e18, 3e18));
    }

    /// @dev A range and liquidity: full range, a random range, or a narrow one around the current price
    function _range(uint256 p0, uint256 p1, uint8 d0, uint8 d1) internal returns (uint160 a, uint160 b) {
        uint256 kind = _rand() % 4;
        if (kind == 0) return (TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE);
        if (kind == 1) return (_sqrtAtTick(_tick()), _sqrtAtTick(_tick()));
        int24 current;
        try world.sqrtPriceFromUsd(p0, p1, d0, d1) returns (uint160 s) {
            current = TickMath.getTickAtSqrtPrice(s == TickMath.MAX_SQRT_PRICE ? s - 1 : s);
        } catch {}
        int256 width = int256(_logBetween(1, 200_000));
        int256 lower = int256(current) - int256(_between(0, uint256(width)));
        int256 upper = lower + width;
        if (lower < TickMath.MIN_TICK) lower = TickMath.MIN_TICK;
        if (upper > TickMath.MAX_TICK) upper = TickMath.MAX_TICK;
        return (_sqrtAtTick(int24(lower)), _sqrtAtTick(int24(upper)));
    }

    function _collateral() internal returns (RangeCollateral memory c) {
        (c.price0Wad, c.decimals0, c.sigma0Wad) = (_price(), _decimals(), _sigma());
        (c.price1Wad, c.decimals1, c.sigma1Wad) = (_price(), _decimals(), _sigma());
        (c.shape.sqrtPaX96, c.shape.sqrtPbX96) = _range(c.price0Wad, c.price1Wad, c.decimals0, c.decimals1);
        c.accountLiquidity = uint128(_logBetween(1, type(uint128).max));
        if (_chance(20)) c.accountLiquidity = 0;
        c.shape.liquidity = c.accountLiquidity;
    }

    /// @dev A collateral with realistic parameters, loaded into the world with a random other token, the three
    ///      tokens' penalties and a borrow fee
    function _worldCollateral() internal returns (RangeCollateral memory c) {
        (c.price0Wad, c.decimals0, c.sigma0Wad) = (_price(), _chance(10) ? 18 : _decimals(), _sigma());
        (c.price1Wad, c.decimals1, c.sigma1Wad) = (_price(), _chance(10) ? 6 : _decimals(), _sigma());
        if (c.decimals0 > 30) c.decimals0 = 18;
        if (c.decimals1 > 30) c.decimals1 = 6;
        (c.shape.sqrtPaX96, c.shape.sqrtPbX96) = _range(c.price0Wad, c.price1Wad, c.decimals0, c.decimals1);
        c.accountLiquidity = uint128(_logBetween(1e6, 1e30));
        c.shape.liquidity = c.accountLiquidity;
        world.setToken(world.TOKEN0(), c.price0Wad, c.decimals0, uint64(c.sigma0Wad));
        world.setToken(world.TOKEN1(), c.price1Wad, c.decimals1, uint64(c.sigma1Wad));
        uint8 otherDecimals = _decimals();
        world.setToken(world.OTHER(), _price(), otherDecimals > 30 ? 18 : otherDecimals, _sigma());
        // Three draws, as many as the one penalty per deployment took, so every later draw stays where it was
        world.setPenalty(world.TOKEN0(), uint64(_between(1e18, 1.3e18)));
        world.setPenalty(world.TOKEN1(), uint64(_between(1e18, 1.3e18)));
        world.setPenalty(world.OTHER(), uint64(_between(1e18, 1.3e18)));
        world.setBorrowFee(uint64(_chance(3) ? 0 : _between(0, 0.01e18)));
    }

    /// @dev 0..2 debts worth `minPct`..`maxPct`% of the collateral in total, loaded into the world
    function _worldDebts(RangeCollateral memory c, uint256 minPct, uint256 maxPct)
        internal
        returns (string memory text)
    {
        uint256 value = _valueOf(c);
        uint256 n = _between(0, 2);
        address[] memory assets = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        text = _u(n);
        for (uint256 i; i < n; ++i) {
            uint256 asset = _between(0, 2);
            // The borrowable lists each asset once
            if (i == 1 && assets[0] == _asset(asset)) asset = (asset + 1) % 3;
            (uint256 price, uint8 decimals) = world.priceWithDecimals(_asset(asset));
            assets[i] = _asset(asset);
            amounts[i] =
                price == 0 ? 0 : FullMath.mulDiv(value * _between(minPct, maxPct) / 100 / n, 10 ** decimals, price);
            _lastDebtAsset = asset;
            if (_chance(20)) amounts[i] = 0;
            text = string.concat(text, _u(asset), _u(amounts[i]));
        }
        world.setDebts(assets, amounts);
    }

    function _valueOf(RangeCollateral memory c) internal view returns (uint256 value) {
        try world.collateralUsdAt(c, c.price0Wad, c.price1Wad) returns (uint256 v) {
            value = v > type(uint200).max ? type(uint200).max : v;
        } catch {}
    }

    function _market() internal returns (Market memory m) {
        uint256 supply = _chance(10) ? _any() >> 128 : _logBetween(1, 1e30);
        if (_chance(20)) supply = 0;
        m.totalSupplyAssets = uint128(supply);
        m.totalBorrowAssets = uint128(_between(0, supply));
        m.totalBorrowShares = uint128(_chance(10) ? _any() >> 128 : _between(0, uint256(m.totalBorrowAssets) * 1e6 + 1));
        m.lastAccrual = uint64(_between(0, 2e9));
        m.reserveFactorWad = uint64(_chance(10) ? _between(0, type(uint64).max) : _between(0, 0.5e18));
        m.interestRemainder = uint64(_chance(3) ? 0 : _between(0, 1e18 - 1));
        m.rateAtTarget = uint64(_rateAtTarget());
    }

    /// @dev Mostly within the curve's bounds, sometimes any uint64
    function _rateAtTarget() internal returns (uint256) {
        if (_chance(10)) return _between(0, type(uint64).max);
        return _between(MarketLogic.MIN_RATE_AT_TARGET, MarketLogic.MAX_RATE_AT_TARGET);
    }

    function _asset(uint256 index) internal view returns (address) {
        return index == 0 ? world.TOKEN0() : index == 1 ? world.TOKEN1() : world.OTHER();
    }

    /*  ================================================
                           Formatting
        ================================================  */

    function _err(bytes memory reason) internal pure returns (string memory) {
        if (reason.length < 4) return "err:empty";
        bytes4 sel;
        assembly ("memory-safe") {
            sel := mload(add(reason, 32))
        }
        if (sel == 0x4e487b71 && reason.length >= 36) {
            uint256 code;
            assembly ("memory-safe") {
                code := mload(add(reason, 36))
            }
            return string.concat("err:panic:", vm.toString(code));
        }
        return string.concat("err:", vm.toString(abi.encodePacked(sel)));
    }

    function lineFeeCheckpoint() external returns (string memory) {
        FeeCheckpoint memory cp = FeeCheckpoint(_any(), _any(), uint128(_any()), uint128(_any()));
        uint256 balance = _chance(10) ? 0 : _chance(10) ? _any() : _any() >> 128;
        (uint256 fg0, uint256 fg1) = (_any(), _any());
        if (_chance(3)) {
            (uint256 add0, uint256 add1) = (_any() >> 140, _any() >> 140);
            unchecked {
                (fg0, fg1) = (cp.feeGrowthInside0X128 + add0, cp.feeGrowthInside1X128 + add1);
            }
        }
        string memory out;
        try world.feesCheckpoint(cp, balance, fg0, fg1) returns (FeeCheckpoint memory next) {
            out = string.concat(
                _u(next.feeGrowthInside0X128),
                _u(next.feeGrowthInside1X128),
                _u(next.owed0),
                vm.toString(uint256(next.owed1))
            );
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(
            string.concat(_u(cp.feeGrowthInside0X128), _u(cp.feeGrowthInside1X128), _u(cp.owed0), _u(cp.owed1)),
            string.concat(_u(balance), _u(fg0), _u(fg1)),
            "=> ",
            out
        );
    }

    function _formatLiquidation(RangeCollateral memory c, DebtInput[] memory debts, uint256 penalty)
        internal
        view
        returns (string memory)
    {
        string memory debtText;
        for (uint256 i; i < debts.length; ++i) {
            debtText = string.concat(debtText, _u(debts[i].valueUsdWad), _u(debts[i].sigmaWad), _u(uint8(debts[i].tie)));
        }
        string memory out;
        try lens.liquidationPrices(c, debts, penalty) returns (ISenzuLens.LiquidationPrices memory lp) {
            out = string.concat(_u(lp.token == world.TOKEN0() ? 0 : 1), _u(lp.lowerWad), vm.toString(lp.upperWad));
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(_collateralText(c), _u(penalty), _u(debts.length), debtText, "=> ", out);
    }

    function lineLiquidationPrices() external returns (string memory) {
        RangeCollateral memory c = _worldCollateral();
        c.shape.token0 = world.TOKEN0();
        c.shape.token1 = world.TOKEN1();
        uint256 value = _valueOf(c);
        uint256 n = _between(0, 2);
        DebtInput[] memory debts = new DebtInput[](n);
        for (uint256 i; i < n; ++i) {
            DebtTie tie = DebtTie(_between(0, 2));
            debts[i] =
                DebtInput({valueUsdWad: value * _between(0, 120) / 100 / n, sigmaWad: _between(1e18, 3e18), tie: tie});
        }
        uint256 penalty = _between(1e18, 1.3e18);
        return _formatLiquidation(c, debts, penalty);
    }

    function _stdCollateral(uint256 p0, uint8 d0, uint256 s0, uint256 p1, uint8 d1, uint256 s1, uint128 liq)
        internal
        view
        returns (RangeCollateral memory c)
    {
        c.shape = Shape(world.TOKEN0(), world.TOKEN1(), _sqrtAtTick(-1000), _sqrtAtTick(1000), liq);
        c.accountLiquidity = liq;
        (c.price0Wad, c.decimals0, c.sigma0Wad) = (p0, d0, s0);
        (c.price1Wad, c.decimals1, c.sigma1Wad) = (p1, d1, s1);
    }

    function extremeLiquidationPrices() external view returns (string[] memory lines) {
        lines = new string[](10);
        uint256 maxOverWad = type(uint256).max / WAD;

        // 0: unstressed debtUsdWad overflow while stressed-down fits in I256 (#1a)
        {
            RangeCollateral memory c = _stdCollateral(WAD, 18, 10 * WAD, WAD, 18, WAD, 1_000_000);
            uint256 halfPlus = (type(uint256).max >> 1) + 10;
            DebtInput[] memory debts = new DebtInput[](2);
            debts[0] = DebtInput(halfPlus, 10 * WAD, DebtTie.Token0);
            debts[1] = DebtInput(halfPlus, 10 * WAD, DebtTie.Token0);
            lines[0] = _formatLiquidation(c, debts, WAD);
        }
        // 1: later-corner p0Up * 10^18 overflow hidden if corner 0 short-circuits (#1b)
        {
            RangeCollateral memory c = _stdCollateral(maxOverWad, 18, 2 * WAD, WAD, 18, WAD, 1);
            DebtInput[] memory debts = new DebtInput[](1);
            debts[0] = DebtInput(1_000_000 * WAD, WAD, DebtTie.None);
            lines[1] = _formatLiquidation(c, debts, WAD);
        }
        // 2: healthWad fullMulDiv(collateralUsd, WAD, 1) overflow (#1c)
        {
            RangeCollateral memory c = _stdCollateral(1e32, 0, WAD, 1e32, 0, WAD, 1e30);
            DebtInput[] memory debts = new DebtInput[](1);
            debts[0] = DebtInput(1, WAD, DebtTie.None);
            lines[2] = _formatLiquidation(c, debts, WAD);
        }
        // 3: zero moving price (clamped to 1 wei inside search)
        {
            RangeCollateral memory c = _stdCollateral(0, 18, 2 * WAD, WAD, 18, WAD, 1e18);
            DebtInput[] memory debts = new DebtInput[](1);
            debts[0] = DebtInput(WAD, WAD, DebtTie.Token1);
            lines[3] = _formatLiquidation(c, debts, WAD);
        }
        // 4: zero fixed price -> HealthMath__InvalidPrice
        {
            RangeCollateral memory c = _stdCollateral(WAD, 18, 2 * WAD, 0, 18, WAD, 1e18);
            DebtInput[] memory debts = new DebtInput[](1);
            debts[0] = DebtInput(WAD, WAD, DebtTie.Token0);
            lines[4] = _formatLiquidation(c, debts, WAD);
        }
        // 5: invalid sigma on pair token -> HealthMath__InvalidSigma
        {
            RangeCollateral memory c = _stdCollateral(WAD, 18, WAD / 2, WAD, 18, WAD, 1e18);
            DebtInput[] memory debts = new DebtInput[](1);
            debts[0] = DebtInput(WAD, WAD, DebtTie.Token0);
            lines[5] = _formatLiquidation(c, debts, WAD);
        }
        // 6: invalid sigma on untied debt -> HealthMath__InvalidSigma
        {
            RangeCollateral memory c = _stdCollateral(WAD, 18, 2 * WAD, WAD, 18, WAD, 1e18);
            DebtInput[] memory debts = new DebtInput[](1);
            debts[0] = DebtInput(WAD, WAD / 2, DebtTie.None);
            lines[6] = _formatLiquidation(c, debts, WAD);
        }
        // 7: empty debts -> Ok(None, None)
        {
            RangeCollateral memory c = _stdCollateral(WAD, 18, 2 * WAD, WAD, 18, WAD, 1e18);
            lines[7] = _formatLiquidation(c, new DebtInput[](0), WAD);
        }
        // 8: zero liquidity -> Ok(None, None)
        {
            RangeCollateral memory c = _stdCollateral(WAD, 18, 2 * WAD, WAD, 18, WAD, 0);
            DebtInput[] memory debts = new DebtInput[](1);
            debts[0] = DebtInput(WAD, WAD, DebtTie.Token1);
            lines[8] = _formatLiquidation(c, debts, WAD);
        }
        // 9: moving price overflows at kMax = 1000 * WAD
        {
            RangeCollateral memory c = _stdCollateral(maxOverWad / 500, 18, WAD, WAD, 18, WAD, 1e18);
            c.sigma0Wad = 1.1e18;
            DebtInput[] memory debts = new DebtInput[](1);
            debts[0] = DebtInput(WAD, WAD, DebtTie.Token1);
            lines[9] = _formatLiquidation(c, debts, WAD);
        }
    }

    function _formatMaxBorrowCase(
        RangeCollateral memory c,
        uint256 otherPrice,
        uint8 otherDec,
        uint64 otherSigma,
        uint256[] memory debtAssetsIdx,
        uint256[] memory debtAmounts,
        uint256 asset,
        uint256 supply,
        uint256 borrowed,
        uint256 shares,
        uint256 accountShares
    ) internal returns (string memory) {
        world.setToken(world.TOKEN0(), c.price0Wad, c.decimals0, uint64(c.sigma0Wad));
        world.setToken(world.TOKEN1(), c.price1Wad, c.decimals1, uint64(c.sigma1Wad));
        world.setToken(world.OTHER(), otherPrice, otherDec, otherSigma);
        world.setPenalty(world.TOKEN0(), uint64(1.08e18));
        world.setPenalty(world.TOKEN1(), uint64(1.08e18));
        world.setPenalty(world.OTHER(), uint64(1.08e18));
        world.setBorrowFee(0);
        world.setPosition(c.shape.sqrtPaX96, c.shape.sqrtPbX96, c.accountLiquidity, 1);
        address[] memory addrs = new address[](debtAssetsIdx.length);
        string memory debtText = _u(debtAssetsIdx.length);
        for (uint256 i; i < debtAssetsIdx.length; ++i) {
            addrs[i] = _asset(debtAssetsIdx[i]);
            debtText = string.concat(debtText, _u(debtAssetsIdx[i]), _u(debtAmounts[i]));
        }
        world.setDebts(addrs, debtAmounts);
        world.setMarket(supply, borrowed, shares, accountShares);
        string memory out;
        try lens.maxBorrow(address(world), world.POSITION(), _asset(asset)) returns (uint256 r) {
            out = vm.toString(r);
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        string memory head =
            string.concat(_collateralText(c), _otherText(), _penaltiesText(), _u(world.borrowFeeWad(address(world))));
        return
            string.concat(
                head, debtText, _u(asset), _u(supply), _u(borrowed), _u(shares), _u(accountShares), "=> ", out
            );
    }

    function extremeMaxBorrow() external returns (string[] memory lines) {
        lines = new string[](7);
        uint256[] memory empty = new uint256[](0);
        RangeCollateral memory base = _stdCollateral(2000e18, 18, 1.15e18, WAD, 6, 1.02e18, 1e20);

        // 0: already has 2 other debts -> returns 0
        {
            uint256[] memory idx = new uint256[](2);
            uint256[] memory amt = new uint256[](2);
            (idx[0], idx[1]) = (0, 1);
            (amt[0], amt[1]) = (1e17, 100e6);
            lines[0] = _formatMaxBorrowCase(base, WAD, 18, uint64(1.1e18), idx, amt, 2, 1e24, 1e20, 1e20, 0);
        }
        // 1: borrow > supply -> underflow in borrow_limit
        lines[1] = _formatMaxBorrowCase(base, WAD, 18, uint64(1.1e18), empty, empty, 1, 100, 200, 200, 0);
        // 2: zero price0 -> HealthMath__InvalidPrice
        {
            RangeCollateral memory c = _stdCollateral(0, 18, 1.15e18, WAD, 6, 1.02e18, 1e20);
            lines[2] = _formatMaxBorrowCase(c, WAD, 18, uint64(1.1e18), empty, empty, 1, 1e24, 0, 0, 0);
        }
        // 3: invalid sigma on pair -> HealthMath__InvalidSigma
        {
            RangeCollateral memory c = _stdCollateral(2000e18, 18, 0.5e18, WAD, 6, 1.02e18, 1e20);
            lines[3] = _formatMaxBorrowCase(c, WAD, 18, uint64(1.1e18), empty, empty, 1, 1e24, 0, 0, 0);
        }
        // 4: invalid sigma on other asset being borrowed -> HealthMath__InvalidSigma
        lines[4] = _formatMaxBorrowCase(base, WAD, 18, uint64(0.5e18), empty, empty, 2, 1e24, 0, 0, 0);
        // 5: p0Up * 10^18 overflow -> Panic(0x11)
        {
            RangeCollateral memory c = _stdCollateral(type(uint256).max / WAD, 18, 2 * WAD, WAD, 18, WAD, 1e18);
            lines[5] = _formatMaxBorrowCase(c, WAD, 18, uint64(WAD), empty, empty, 1, 1e24, 0, 0, 0);
        }
        // 6: healthWad overflow inside maxBorrow -> FullMulDivFailed
        {
            RangeCollateral memory c = _stdCollateral(1e32, 0, WAD, 1e32, 0, WAD, 1e30);
            lines[6] = _formatMaxBorrowCase(c, 1, 0, uint64(WAD), empty, empty, 2, 1, 0, 0, 0);
        }
    }

    function _formatMaxLeverageCase(
        RangeCollateral memory c,
        uint256 otherPrice,
        uint8 otherDec,
        uint64 otherSigma,
        uint64 borrowFee,
        uint256 mode
    ) internal returns (string memory) {
        world.setToken(world.TOKEN0(), c.price0Wad, c.decimals0, uint64(c.sigma0Wad));
        world.setToken(world.TOKEN1(), c.price1Wad, c.decimals1, uint64(c.sigma1Wad));
        world.setToken(world.OTHER(), otherPrice, otherDec, otherSigma);
        world.setPenalty(world.TOKEN0(), uint64(1.08e18));
        world.setPenalty(world.TOKEN1(), uint64(1.08e18));
        world.setPenalty(world.OTHER(), uint64(1.08e18));
        world.setBorrowFee(borrowFee);
        address borrowAsset = mode == 0 ? address(0) : _asset(mode - 1);
        string memory out;
        try lens.maxLeverage(
            world.TOKEN0(), world.TOKEN1(), c.shape.sqrtPaX96, c.shape.sqrtPbX96, borrowAsset
        ) returns (
            uint256 r
        ) {
            out = vm.toString(r);
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        string memory head = string.concat(_collateralText(c), _otherText(), _penaltiesText());
        return string.concat(head, _u(borrowFee), _u(mode), "=> ", out);
    }

    function extremeMaxLeverage() external returns (string[] memory lines) {
        lines = new string[](6);
        // 0: zero price0 -> HealthMath__InvalidPrice (or value == 0 -> WAD)
        lines[0] =
            _formatMaxLeverageCase(_stdCollateral(0, 18, 1.15e18, WAD, 6, 1.02e18, 0), WAD, 18, uint64(1.1e18), 0, 0);
        // 1: zero price1
        lines[1] = _formatMaxLeverageCase(
            _stdCollateral(2000e18, 18, 1.15e18, 0, 6, 1.02e18, 0), WAD, 18, uint64(1.1e18), 0, 0
        );
        // 2: invalid sigma on pair
        lines[2] = _formatMaxLeverageCase(
            _stdCollateral(2000e18, 18, 0.5e18, WAD, 6, 1.02e18, 0), WAD, 18, uint64(1.1e18), 0, 0
        );
        // 3: invalid sigma on Single(Other)
        lines[3] = _formatMaxLeverageCase(
            _stdCollateral(2000e18, 18, 1.15e18, WAD, 6, 1.02e18, 0), WAD, 18, uint64(0.5e18), 0, 3
        );
        // 4: p0Up * 10^18 overflow -> Panic(0x11)
        lines[4] = _formatMaxLeverageCase(
            _stdCollateral(type(uint256).max / WAD, 18, 2 * WAD, WAD, 18, WAD, 0), WAD, 18, uint64(WAD), 0, 0
        );
        // 5: tiny value == 0 -> returns WAD
        lines[5] =
            _formatMaxLeverageCase(_stdCollateral(1, 18, 1.15e18, 1, 18, 1.02e18, 0), WAD, 18, uint64(1.1e18), 0, 0);
    }

    function _formatPreviewOpenCase(
        RangeCollateral memory c,
        uint256 otherPrice,
        uint8 otherDec,
        uint64 otherSigma,
        uint256 deposit0,
        uint256 deposit1,
        bool swap,
        uint256[] memory borrowIdx,
        uint256[] memory borrowAmt
    ) internal returns (string memory) {
        world.setToken(world.TOKEN0(), c.price0Wad, c.decimals0, uint64(c.sigma0Wad));
        world.setToken(world.TOKEN1(), c.price1Wad, c.decimals1, uint64(c.sigma1Wad));
        world.setToken(world.OTHER(), otherPrice, otherDec, otherSigma);
        world.setPenalty(world.TOKEN0(), uint64(1.08e18));
        world.setPenalty(world.TOKEN1(), uint64(1.08e18));
        world.setPenalty(world.OTHER(), uint64(1.08e18));
        world.setBorrowFee(0);
        uint256 marketBorrowed = 1e18;
        uint256 marketShares = 1e18;
        world.setMarket(type(uint128).max, marketBorrowed, marketShares, 0);

        ISenzuPreviews.OpenParams memory p;
        (p.token0, p.token1, p.sqrtPaX96, p.sqrtPbX96) =
        (world.TOKEN0(), world.TOKEN1(), c.shape.sqrtPaX96, c.shape.sqrtPbX96);
        (p.deposit0, p.deposit1, p.swap) = (deposit0, deposit1, swap);
        p.borrowAssets = new address[](borrowIdx.length);
        p.borrowAmounts = new uint256[](borrowAmt.length);
        string memory borrowText;
        for (uint256 i; i < borrowIdx.length; ++i) {
            p.borrowAssets[i] = _asset(borrowIdx[i]);
            p.borrowAmounts[i] = borrowAmt[i];
            borrowText = string.concat(borrowText, _u(borrowIdx[i]), _u(borrowAmt[i]));
        }
        string memory out;
        try lens.previewOpen(p) returns (ISenzuPreviews.OpenPreview memory r) {
            out = string.concat(
                string.concat(_u(r.liquidity), _u(r.amount0), _u(r.amount1), _u(r.collateralUsdWad)),
                string.concat(_u(r.marginUsdWad), _u(r.debtUsdWad), _u(r.leverageWad), _u(r.healthWad), _b(r.allowed)),
                string.concat(
                    _u(r.liquidation.token == world.TOKEN0() ? 0 : 1),
                    _u(r.liquidation.lowerWad),
                    vm.toString(r.liquidation.upperWad)
                )
            );
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        string memory head =
            string.concat(_collateralText(c), _otherText(), _penaltiesText(), _u(world.borrowFeeWad(address(world))));
        return string.concat(
            head,
            _u(deposit0),
            _u(deposit1),
            _b(swap),
            _u(borrowIdx.length),
            borrowText,
            _u(marketBorrowed),
            _u(marketShares),
            "=> ",
            out
        );
    }

    function extremePreviewOpen() external returns (string[] memory lines) {
        lines = new string[](7);
        uint256[] memory empty = new uint256[](0);
        RangeCollateral memory base = _stdCollateral(2000e18, 18, 1.15e18, WAD, 6, 1.02e18, 0);

        // 0: empty borrows with p0Up * 10^18 overflow -> previewOpen & openLiquidationPrices must both fail (#1d)
        lines[0] = _formatPreviewOpenCase(
            _stdCollateral(type(uint256).max / WAD, 18, 2 * WAD, WAD, 18, WAD, 0),
            WAD,
            18,
            uint64(WAD),
            1,
            0,
            false,
            empty,
            empty
        );
        // 1: invalid sigma on pair -> HealthMath__InvalidSigma
        lines[1] = _formatPreviewOpenCase(
            _stdCollateral(2000e18, 18, 0.5e18, WAD, 6, 1.02e18, 0),
            WAD,
            18,
            uint64(WAD),
            1e18,
            2000e6,
            true,
            empty,
            empty
        );
        // 2: zero price0 -> HealthMath__InvalidPrice
        lines[2] = _formatPreviewOpenCase(
            _stdCollateral(0, 18, 1.15e18, WAD, 6, 1.02e18, 0), WAD, 18, uint64(WAD), 1e18, 2000e6, false, empty, empty
        );
        // 3: deposit0 + borrow0 overflow -> Panic(0x11)
        {
            uint256[] memory idx = new uint256[](1);
            uint256[] memory amt = new uint256[](1);
            idx[0] = 0;
            amt[0] = 10;
            lines[3] = _formatPreviewOpenCase(base, WAD, 18, uint64(WAD), type(uint256).max, 0, false, idx, amt);
        }
        // 4: 3 borrows (> MAX_DEBTS) -> allowed == false
        {
            uint256[] memory idx = new uint256[](3);
            uint256[] memory amt = new uint256[](3);
            (idx[0], idx[1], idx[2]) = (0, 1, 2);
            (amt[0], amt[1], amt[2]) = (1e16, 10e6, 1e16);
            lines[4] = _formatPreviewOpenCase(base, WAD, 18, uint64(1.1e18), 1e18, 2000e6, true, idx, amt);
        }
        // 5: liquidity > u128::MAX -> SafeCastLib.Overflow
        lines[5] = _formatPreviewOpenCase(base, WAD, 18, uint64(WAD), 1e40, 1e40, true, empty, empty);
        // 6: zero deposit & zero borrow -> Ok with liquidity == 0
        lines[6] = _formatPreviewOpenCase(base, WAD, 18, uint64(WAD), 0, 0, true, empty, empty);
    }

    function _formatSwapCase(
        uint160 a,
        uint160 b,
        uint256 x,
        uint256 y,
        uint160 p,
        uint256 fee,
        uint256 p0,
        uint8 d0,
        uint256 p1,
        uint8 d1
    ) internal returns (string memory) {
        world.setToken(world.TOKEN0(), p0, d0, 1e18);
        world.setToken(world.TOKEN1(), p1, d1, 1e18);
        string memory out;
        try lens.swapForRange(world.TOKEN0(), world.TOKEN1(), a, b, x, y, p, fee) returns (
            ISenzuPreviews.SwapQuote memory q
        ) {
            out = string.concat(_b(q.zeroForOne), _u(q.amountIn), vm.toString(q.amountOut));
        } catch (bytes memory reason) {
            out = _err(reason);
        }
        return string.concat(
            string.concat(_u(a), _u(b), _u(x), _u(y), _u(p), _u(fee)),
            string.concat(_u(p0), _u(d0), _u(p1), _u(d1)),
            "=> ",
            out
        );
    }

    /// @dev Deterministic extreme inputs for `swap_for_range`: low-priced 18-dec tokens against 6-dec USDC,
    ///      symmetric high-price pairs, extreme value ratios, huge amounts, and fee boundaries.
    function extremeSwapForRange() external returns (string[] memory lines) {
        lines = new string[](23);
        uint256 k;

        // 0..6: 18-dec token0 at $1e-3..$1e-9 vs 6-dec USDC ($1), $1,000 USDC into a +-20% range
        uint256 price = 1e15; // $1e-3
        for (uint256 i; i < 7; ++i) {
            uint160 a = HealthMath.sqrtPriceX96FromUsd(price * 8 / 10, 1e18, 18, 6);
            uint160 b = HealthMath.sqrtPriceX96FromUsd(price * 12 / 10, 1e18, 18, 6);
            lines[k++] = _formatSwapCase(a, b, 0, 1_000e6, 0, 0.003e18, price, 18, 1e18, 6);
            price /= 10;
        }

        // 7..9: 18-dec token0 at $1e-3, $1e-6, $1e-9 vs 6-dec USDC, $1,000 of token0 into a +-20% range
        uint256[3] memory lowPrices = [uint256(1e15), 1e12, 1e9];
        for (uint256 i; i < 3; ++i) {
            uint256 p0 = lowPrices[i];
            uint160 a = HealthMath.sqrtPriceX96FromUsd(p0 * 8 / 10, 1e18, 18, 6);
            uint160 b = HealthMath.sqrtPriceX96FromUsd(p0 * 12 / 10, 1e18, 18, 6);
            uint256 x = (1_000e18 * 1e18) / p0;
            lines[k++] = _formatSwapCase(a, b, x, 0, 0, 0.003e18, p0, 18, 1e18, 6);
        }

        // 10..13: mixed deposits at $1e-6 and $1e-9
        {
            uint160 a6 = HealthMath.sqrtPriceX96FromUsd(8e11, 1e18, 18, 6);
            uint160 b6 = HealthMath.sqrtPriceX96FromUsd(12e11, 1e18, 18, 6);
            lines[k++] = _formatSwapCase(a6, b6, 500e24, 1_000e6, 0, 0.003e18, 1e12, 18, 1e18, 6);
            lines[k++] = _formatSwapCase(a6, b6, 1_000e24, 200e6, 0, 0.003e18, 1e12, 18, 1e18, 6);

            uint160 a9 = HealthMath.sqrtPriceX96FromUsd(8e8, 1e18, 18, 6);
            uint160 b9 = HealthMath.sqrtPriceX96FromUsd(12e8, 1e18, 18, 6);
            lines[k++] = _formatSwapCase(a9, b9, 500e27, 1_000e6, 0, 0.003e18, 1e9, 18, 1e18, 6);
            lines[k++] = _formatSwapCase(a9, b9, 1_000e27, 200e6, 0, 0.003e18, 1e9, 18, 1e18, 6);
        }

        // 14..17: symmetric 6-dec USDC (token0) vs 18-dec token1 at $1e-6 and $1e-9 (s >= Q96)
        {
            uint160 a6 = HealthMath.sqrtPriceX96FromUsd(1e18, 12e11, 6, 18);
            uint160 b6 = HealthMath.sqrtPriceX96FromUsd(1e18, 8e11, 6, 18);
            lines[k++] = _formatSwapCase(a6, b6, 1_000e6, 0, 0, 0.003e18, 1e18, 6, 1e12, 18);
            lines[k++] = _formatSwapCase(a6, b6, 200e6, 1_000e24, 0, 0.003e18, 1e18, 6, 1e12, 18);

            uint160 a9 = HealthMath.sqrtPriceX96FromUsd(1e18, 12e8, 6, 18);
            uint160 b9 = HealthMath.sqrtPriceX96FromUsd(1e18, 8e8, 6, 18);
            lines[k++] = _formatSwapCase(a9, b9, 1_000e6, 0, 0, 0.003e18, 1e18, 6, 1e9, 18);
            lines[k++] = _formatSwapCase(a9, b9, 0, 1_000e27, 0, 0.003e18, 1e18, 6, 1e9, 18);
        }

        // 18: r == 0 (s = MAX_SQRT_PRICE - 1) -> sells all amount0
        lines[k++] = _formatSwapCase(
            TickMath.MIN_SQRT_PRICE,
            TickMath.MAX_SQRT_PRICE,
            1e18,
            1e18,
            TickMath.MAX_SQRT_PRICE - 1,
            0.003e18,
            1e18,
            18,
            1e18,
            18
        );
        // 19: huge r (~2^158 * WAD): a = s - 1, b = MAX_SQRT_PRICE, s = b / 2
        {
            uint160 s = TickMath.MAX_SQRT_PRICE / 2;
            lines[k++] = _formatSwapCase(s - 1, TickMath.MAX_SQRT_PRICE, 1e18, 1e18, s, 0.003e18, 1e18, 18, 1e18, 18);
        }
        // 20: 100% fee (keep == 0) -> no division by zero
        lines[k++] = _formatSwapCase(
            TickMath.getSqrtPriceAtTick(-1000),
            TickMath.getSqrtPriceAtTick(1000),
            1e18,
            2e18,
            TickMath.getSqrtPriceAtTick(0),
            1e18,
            1e18,
            18,
            1e18,
            18
        );
        // 21: fee > WAD -> underflow
        lines[k++] = _formatSwapCase(
            TickMath.getSqrtPriceAtTick(-1000),
            TickMath.getSqrtPriceAtTick(1000),
            1e18,
            2e18,
            TickMath.getSqrtPriceAtTick(0),
            1e18 + 1,
            1e18,
            18,
            1e18,
            18
        );
        // 22: huge amounts (~2^254) in range with reversed bounds (a > b)
        lines[k++] = _formatSwapCase(
            TickMath.getSqrtPriceAtTick(1000),
            TickMath.getSqrtPriceAtTick(-1000),
            type(uint256).max >> 2,
            type(uint256).max >> 3,
            TickMath.getSqrtPriceAtTick(0),
            0.003e18,
            1e18,
            18,
            1e18,
            18
        );
    }

    function _u(uint256 x) internal pure returns (string memory) {
        return string.concat(vm.toString(x), " ");
    }

    function _b(bool x) internal pure returns (string memory) {
        return x ? "1 " : "0 ";
    }

    function _collateralText(RangeCollateral memory c) internal pure returns (string memory) {
        return string.concat(
            string.concat(_u(c.shape.sqrtPaX96), _u(c.shape.sqrtPbX96), _u(c.accountLiquidity)),
            string.concat(_u(c.price0Wad), _u(c.decimals0), _u(c.sigma0Wad)),
            string.concat(_u(c.price1Wad), _u(c.decimals1), _u(c.sigma1Wad))
        );
    }

    function _otherText() internal view returns (string memory) {
        (uint256 price, uint8 decimals) = world.priceWithDecimals(world.OTHER());
        return string.concat(_u(price), _u(decimals), _u(world.tokenRisk(address(world), world.OTHER()).sigmaWad));
    }

    function _penaltiesText() internal view returns (string memory) {
        return string.concat(
            _u(world.tokenRisk(address(world), world.TOKEN0()).penaltyWad),
            _u(world.tokenRisk(address(world), world.TOKEN1()).penaltyWad),
            _u(world.tokenRisk(address(world), world.OTHER()).penaltyWad)
        );
    }
}
