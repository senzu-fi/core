// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SenzuBorrowable} from "../../src/core/SenzuBorrowable.sol";
import {SenzuCollateral} from "../../src/core/SenzuCollateral.sol";
import {ISenzuBorrowable} from "../../src/interfaces/ISenzuBorrowable.sol";
import {ISenzuLockCallback} from "../../src/interfaces/ISenzuLockCallback.sol";
import {ISenzuPreviews} from "../../src/interfaces/ISenzuPreviews.sol";
import {HealthMath} from "../../src/libraries/HealthMath.sol";
import {MockAdapter, MockAggregator, MockERC20} from "../mocks/Mocks.sol";
import {badDebtIn} from "../utils/Logs.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

bytes32 constant BAD_DEBT = keccak256("BadDebt(address,uint256,address,uint256)");

/// @notice A contract that opens a lock and runs a script of collateral calls inside it, as an attacker's contract
///         would: each step may fail on its own (skipped), and only the end-of-lock check decides the outcome. It is
///         one of the handler's actors, so ordinary actions also give it positions, units and debt.
contract LockScript is ISenzuLockCallback {
    /// @custom:member kind 0 borrow · 1 borrow with the loan sent to `to` · 2 redeem everything · 3 transfer units · 4 resolveBadDebt
    ///                   · 5 liquidate `to` (seize first, settled from this contract's tokens after the last step)
    ///                   · 6 borrow `amount` of `asset` against the next id, before it exists · 7 open that id: a
    ///                   WETH/USDC position of `amount` (as liquidity, bounded) for this contract
    struct Step {
        uint8 kind;
        uint256 id;
        address asset;
        uint256 amount;
        address to;
    }

    SenzuCollateral public immutable collateral;

    /// @notice The (account, id) pairs the last run flash-liquidated
    address[] public liquidatedAccounts;
    uint256[] public liquidatedIds;
    address[] internal liquidatedAssets;
    uint256[] internal liquidatedRepaid;

    /// @notice What `open` creates: the pair's adapter and tokens
    address public adapter;
    address public token0;
    address public token1;

    /// @notice The id the last run borrowed against before it existed, and the id it opened (0: none)
    uint256 public borrowedAgainst;
    uint256 public openedId;

    constructor(SenzuCollateral collateral_) {
        collateral = collateral_;
    }

    function setPair(address adapter_, address token0_, address token1_) external {
        (adapter, token0, token1) = (adapter_, token0_, token1_);
    }

    function run(Step[] calldata steps) external {
        delete liquidatedAccounts;
        delete liquidatedIds;
        delete liquidatedAssets;
        delete liquidatedRepaid;
        (borrowedAgainst, openedId) = (0, 0);
        collateral.lock(abi.encode(steps));
    }

    function liquidatedLength() external view returns (uint256) {
        return liquidatedAccounts.length;
    }

    /// @dev Lets the borrowable pull the settled liquidation repayments from this contract
    function approve(address token, address spender) external {
        MockERC20(token).approve(spender, type(uint256).max);
    }

    function senzuLockAcquired(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(collateral), "not collateral");
        Step[] memory steps = abi.decode(data, (Step[]));
        for (uint256 i; i < steps.length; ++i) {
            Step memory s = steps[i];
            if (s.kind == 0) {
                try collateral.borrow(address(this), s.id, s.asset, s.amount, address(this)) {} catch {}
            } else if (s.kind == 1) {
                try collateral.borrow(address(this), s.id, s.asset, s.amount, s.to) {} catch {}
            } else if (s.kind == 2) {
                uint256 units = collateral.balanceOf(address(this), s.id);
                if (units > 0) {
                    try collateral.redeem(address(this), s.id, units, address(this), "") {} catch {}
                }
            } else if (s.kind == 3) {
                // Units don't transfer, inside a lock as anywhere
                uint256 units = collateral.balanceOf(address(this), s.id);
                if (units > 0) {
                    try collateral.transfer(s.to, s.id, units) {
                        revert("units moved inside a lock");
                    } catch {}
                }
            } else if (s.kind == 4) {
                try collateral.resolveBadDebt(s.to, s.id) {} catch {}
            } else if (s.kind == 6) {
                if (borrowedAgainst != 0) continue;
                uint256 next = collateral.nextPositionId();
                try collateral.borrow(address(this), next, s.asset, s.amount, address(this)) {
                    borrowedAgainst = next;
                } catch {}
            } else if (s.kind == 7) {
                // Only the id it borrowed against (plain opens are the handler's own, capped action)
                if (borrowedAgainst == 0 || openedId != 0) continue;
                bytes memory mint = abi.encode(
                    token0, token1, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, uint128(1e12 + s.amount % 1e15)
                );
                try collateral.open(address(this), address(this), mint) returns (
                    uint256 newId, uint256, address, address, uint256, uint256
                ) {
                    openedId = newId;
                } catch {}
            } else {
                try collateral.liquidate(s.to, s.id, s.asset, s.amount, address(this)) returns (
                    uint256, uint256 repaid, uint256 fee
                ) {
                    liquidatedAccounts.push(s.to);
                    liquidatedIds.push(s.id);
                    liquidatedAssets.push(s.asset);
                    liquidatedRepaid.push(repaid + fee);
                } catch {}
            }
        }
        for (uint256 i; i < liquidatedAssets.length; ++i) {
            collateral.settle(liquidatedAssets[i], liquidatedRepaid[i]);
        }
        return "";
    }
}

/// @notice Drives random sequences of Senzu actions for the invariant tests. Calls that revert for legitimate
///         reasons (unhealthy, no cash, paused, …) are swallowed; behavior that must never happen is recorded in
///         `violation` and checked by the invariant suite.
contract HubHandler is Test {
    SenzuBorrowable public immutable borrowable;
    SenzuCollateral public immutable collateral;
    MockAdapter public immutable adapter;
    MockERC20 public immutable weth;
    MockERC20 public immutable usdc;
    MockAggregator public immutable ethFeed;
    MockAggregator public immutable usdcFeed;
    address public immutable dao;

    address[] public actors;
    uint256[] public ids;
    uint256 internal constant MAX_POSITIONS = 8;

    string public violation;
    mapping(bytes32 => uint256) public calls;

    /// @dev For borrowing right up to the limit (set by the test; the handler can't carry the lens's code)
    ISenzuPreviews public lens;

    constructor(
        SenzuBorrowable borrowable_,
        SenzuCollateral collateral_,
        MockAdapter adapter_,
        MockERC20 weth_,
        MockERC20 usdc_,
        MockAggregator ethFeed_,
        MockAggregator usdcFeed_,
        address dao_,
        address[] memory actors_,
        uint256 firstId
    ) {
        require(BAD_DEBT == ISenzuBorrowable.BadDebt.selector, "BAD_DEBT is not the BadDebt event");
        borrowable = borrowable_;
        collateral = collateral_;
        adapter = adapter_;
        weth = weth_;
        usdc = usdc_;
        ethFeed = ethFeed_;
        usdcFeed = usdcFeed_;
        dao = dao_;
        actors = actors_;
        ids.push(firstId);
    }

    /// @dev Each market's highest value of 1e36 lender shares so far (invariant 12), reset only by a write-off
    mapping(address asset => uint256) public sharePrice;
    /// @dev Set by an action that wrote off bad debt it was allowed to (a full seize of a position liquidatable before)
    bool internal wroteOff;

    /**
     *  @dev After every action: a lender share never loses value, except to a bad-debt write-off. Supply, withdraw,
     *       borrow, repay, liquidations, reserve and fee mints and interest can only keep or raise it (rounding favors
     *       the market). The one wobble allowed is worth under one wei across the market's whole supply: the price
     *       view mints the pending reserve shares in one batch rounded down, and that leftover share fraction moves
     *       as time passes, around a rising price. Real losses add up instead, so the price is held to its highest
     *       so far: falling a whole wei (across every share) below it fails, even when each step lost less
     */
    modifier sharePriceKept(bool writesOff_) {
        _;
        bool writesOff = writesOff_ || wroteOff;
        wroteOff = false;
        address[2] memory assets = [address(weth), address(usdc)];
        for (uint256 a; a < 2; ++a) {
            uint256 price = borrowable.convertToAssets(assets[a], 1e36);
            uint256 lenderShares = borrowable.totalSupply(lenderId(assets[a]));
            uint256 subWei = lenderShares == 0 ? type(uint256).max : 1e36 / lenderShares; // one wei across every share
            if (!writesOff && price + subWei <= sharePrice[assets[a]]) {
                _fail("a lender share lost value without a write-off");
            }
            if (writesOff || price > sharePrice[assets[a]]) sharePrice[assets[a]] = price;
        }
    }

    /*  ================================================
                    Views for the invariants
        ================================================  */

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    /*  ================================================
                            Helpers
        ================================================  */

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _id(uint256 seed) internal view returns (uint256) {
        return ids[seed % ids.length];
    }

    function _asset(uint256 seed) internal view returns (MockERC20) {
        return seed % 2 == 0 ? usdc : weth;
    }

    function _unit(MockERC20 asset) internal view returns (uint256) {
        return 10 ** asset.decimals();
    }

    function _price(MockERC20 asset) internal view returns (uint256) {
        (, int256 answer,,,) = (asset == weth ? ethFeed : usdcFeed).latestRoundData();
        return uint256(answer) * 1e10;
    }

    /// @dev An actor holding liquidity in `id`, starting from `seed` (address(0) if none)
    function _holder(uint256 id, uint256 seed) internal view returns (address) {
        for (uint256 i; i < actors.length; ++i) {
            address a = actors[(seed + i) % actors.length];
            if (collateral.balanceOf(a, id) > 0) return a;
        }
        return address(0);
    }

    /// @dev An actor with debt in `id`, starting from `seed` (address(0) if none)
    function _debtor(uint256 id, uint256 seed) internal view returns (address) {
        for (uint256 i; i < actors.length; ++i) {
            address a = actors[(seed + i) % actors.length];
            if (borrowable.hasDebt(a, id)) return a;
        }
        return address(0);
    }

    /// @dev A market `account` owes in `id`, preferring `seed`'s choice
    function _owedAsset(address account, uint256 id, uint256 seed) internal view returns (MockERC20) {
        MockERC20 preferred = _asset(seed);
        MockERC20 other = preferred == usdc ? weth : usdc;
        return borrowable.borrowSharesOf(account, id, address(preferred)) > 0 ? preferred : other;
    }

    function _fail(string memory reason) internal {
        if (bytes(violation).length == 0) violation = reason;
    }

    /// @dev After a successful risk-increasing action the account must not be liquidatable
    function _assertNotLiquidatable(address account, uint256 id, string memory reason) internal {
        if (!borrowable.hasDebt(account, id)) return;
        try collateral.health(account, id) returns (HealthResultView memory h) {
            if (h.minSurplusUsdWad < 0) _fail(reason);
        } catch {}
    }

    /*  ================================================
                            Lenders
        ================================================  */

    /// @dev Anyone may mint the protocol's pending shares, at any moment: no share price or supply moves
    function mintReserves(uint256 assetSeed) external sharePriceKept(false) {
        address asset = address(_asset(assetSeed));
        uint256 price = borrowable.convertToAssets(asset, 1e36);
        uint256 supply_ = borrowable.totalSupply(lenderId(asset));
        borrowable.mintReserves(asset);
        if (borrowable.convertToAssets(asset, 1e36) != price) _fail("mintReserves moved the share price");
        if (borrowable.totalSupply(lenderId(asset)) != supply_) _fail("mintReserves changed the lender supply");
        calls["mintReserves"]++;
    }

    function supply(uint256 actorSeed, uint256 assetSeed, uint256 amount) external sharePriceKept(false) {
        address actor = _actor(actorSeed);
        MockERC20 asset = _asset(assetSeed);
        amount = bound(amount, _unit(asset), 1_000_000 * _unit(asset) / (asset == weth ? 2000 : 1));
        asset.mint(actor, amount);
        vm.startPrank(actor);
        asset.approve(address(borrowable), amount);
        try borrowable.supply(address(asset), amount, actor) {
            calls["supply"]++;
        } catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 actorSeed, uint256 assetSeed, uint256 fraction) external sharePriceKept(false) {
        address actor = _actor(actorSeed);
        MockERC20 asset = _asset(assetSeed);
        uint256 shares = borrowable.balanceOf(actor, lenderId(address(asset))) * bound(fraction, 1, 1e18) / 1e18;
        if (shares == 0) return;
        vm.prank(actor);
        try borrowable.withdraw(address(asset), shares, actor, actor) {
            calls["withdraw"]++;
        } catch {}
    }

    /*  ================================================
                           Positions
        ================================================  */

    function open(uint256 actorSeed, uint256 liquidity, bool narrow) external sharePriceKept(false) {
        if (ids.length >= MAX_POSITIONS) return;
        address actor = _actor(actorSeed);
        liquidity = bound(liquidity, 1e12, 1e15);

        uint160 a = TickMath.MIN_SQRT_PRICE;
        uint160 b = TickMath.MAX_SQRT_PRICE;
        if (narrow) {
            uint256 sqrtP = HealthMath.sqrtPriceX96FromUsd(_price(weth), _price(usdc), 18, 6);
            a = uint160(sqrtP * 975 / 1000); // ≈ ±5% price range
            b = uint160(sqrtP * 1025 / 1000);
        }

        vm.prank(actor);
        try collateral.open(actor, actor, abi.encode(address(weth), address(usdc), a, b, uint128(liquidity))) returns (
            uint256 id, uint256, address, address, uint256, uint256
        ) {
            ids.push(id);
            calls["open"]++;
        } catch {}
    }

    function increase(uint256 actorSeed, uint256 idSeed, uint256 liquidity) external sharePriceKept(false) {
        address actor = _actor(actorSeed);
        adapter.setNextIncrease(uint128(bound(liquidity, 1, 1e14)));
        vm.prank(actor);
        try collateral.increaseLiquidity(actor, _id(idSeed), actor, "") {
            calls["increase"]++;
        } catch {}
    }

    function redeem(uint256 actorSeed, uint256 idSeed, uint256 fraction) external sharePriceKept(false) {
        uint256 id = _id(idSeed);
        address actor = _holder(id, actorSeed);
        if (actor == address(0)) return;
        uint256 liquidity = collateral.balanceOf(actor, id) * bound(fraction, 1, 1e18) / 1e18;
        if (liquidity == 0) return;
        vm.prank(actor);
        try collateral.redeem(actor, id, liquidity, actor, "") {
            calls["redeem"]++;
            _assertNotLiquidatable(actor, id, "redeem left the account liquidatable");
        } catch {}
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 idSeed, uint256 fraction)
        external
        sharePriceKept(false)
    {
        uint256 id = _id(idSeed);
        address from = _holder(id, fromSeed);
        if (from == address(0)) return;
        address to = _actor(toSeed);
        uint256 liquidity = collateral.balanceOf(from, id) * bound(fraction, 1, 1e18) / 1e18;
        if (liquidity == 0) return;
        // Units don't transfer: every attempt must revert, and nothing moves
        uint256 before = collateral.balanceOf(from, id);
        vm.prank(from);
        try collateral.transfer(to, id, liquidity) {
            revert("units moved");
        } catch {
            calls["transfer"]++;
        }
        assertEq(collateral.balanceOf(from, id), before, "a transfer moved units");
    }

    /*  ================================================
                              Fees
        ================================================  */

    function accrueFees(uint256 idSeed, uint256 amount0, uint256 amount1) external sharePriceKept(false) {
        uint256 lpId = _id(idSeed);
        (,,,, uint128 liquidity,,,,) = adapter.positions(lpId);
        if (liquidity == 0) return;
        adapter.accrueFees(lpId, bound(amount0, 0, 10e18), bound(amount1, 0, 10_000e6));
        calls["accrueFees"]++;
    }

    function collectFees(uint256 actorSeed, uint256 idSeed) external sharePriceKept(false) {
        address actor = _actor(actorSeed);
        vm.prank(actor);
        try adapter.collectFees(actor, _id(idSeed), actor) {
            calls["collectFees"]++;
        } catch {}
    }

    /// @dev Compounding as the router does it (no core compound since 2026-10-15): collect, then add as a holder
    function compound(uint256 actorSeed, uint256 idSeed, uint256 liquidity) external sharePriceKept(false) {
        uint256 id = _id(idSeed);
        address actor = _holder(id, actorSeed);
        if (actor == address(0)) return;
        adapter.setNextIncrease(uint128(bound(liquidity, 1, 1e13)));
        vm.startPrank(actor);
        try adapter.collectFees(actor, id, actor) {
            try collateral.increaseLiquidity(actor, id, actor, "") {
                calls["compound"]++;
            } catch {}
        } catch {}
        vm.stopPrank();
    }

    /*  ================================================
                              Debt
        ================================================  */

    function setLens(ISenzuPreviews lens_) external {
        lens = lens_;
    }

    /// @dev No buffer: the borrow check is the liquidation check, so borrowing the lens's maximum must pass and leave
    ///      the position not liquidatable, and anything past the lens's 1e-6 tolerance must be refused
    function borrowToTheLimit(uint256 actorSeed, uint256 idSeed, uint256 assetSeed) external sharePriceKept(false) {
        uint256 id = _id(idSeed);
        address actor = _holder(id, actorSeed);
        if (actor == address(0)) return;
        MockERC20 asset = _asset(assetSeed);

        uint256 max;
        try lens.maxBorrow(actor, id, address(asset)) returns (uint256 m) {
            max = m;
        } catch {
            return;
        }
        if (max == 0) return;
        (uint256 supplied, uint256 borrowed) = _marketTotals(asset);
        bool cashBound = max >= supplied - borrowed; // the market's cash, not the position, set the maximum

        uint256 snap = vm.snapshotState();
        vm.prank(actor);
        try collateral.borrow(actor, id, address(asset), max + max / 1e6 + 1, actor) {
            if (!cashBound) _fail("a borrow past the lens's maximum passed");
        } catch {}
        vm.revertToState(snap);

        vm.prank(actor);
        try collateral.borrow(actor, id, address(asset), max, actor) {
            calls["borrowToTheLimit"]++;
            _assertNotLiquidatable(actor, id, "a borrow to the limit left the account liquidatable");
        } catch (bytes memory reason) {
            _fail(string.concat("the lens's maximum borrow was refused: ", vm.toString(reason)));
        }
    }

    function borrow(uint256 actorSeed, uint256 idSeed, uint256 assetSeed, uint256 fraction)
        external
        sharePriceKept(false)
    {
        uint256 id = _id(idSeed);
        address actor = _holder(id, actorSeed);
        if (actor == address(0)) return;
        MockERC20 asset = _asset(assetSeed);

        uint256 collateralUsd;
        try collateral.health(actor, id) returns (HealthResultView memory h) {
            collateralUsd = h.collateralUsdWad;
        } catch {
            return;
        }
        uint256 amount = collateralUsd * bound(fraction, 0.01e18, 0.9e18) / 1e18 * _unit(asset) / _price(asset);
        if (amount == 0) return;

        vm.prank(actor);
        try collateral.borrow(actor, id, address(asset), amount, actor) {
            calls["borrow"]++;
            _assertNotLiquidatable(actor, id, "borrow left the account liquidatable");
        } catch {}
    }

    function repay(uint256 payerSeed, uint256 borrowerSeed, uint256 idSeed, uint256 assetSeed, uint256 amount)
        external
        sharePriceKept(false)
    {
        address payer = _actor(payerSeed);
        uint256 id = _id(idSeed);
        address borrower = _debtor(id, borrowerSeed);
        if (borrower == address(0)) return;
        MockERC20 asset = _owedAsset(borrower, id, assetSeed);
        uint256 debt = borrowable.debtOf(borrower, id, address(asset));
        if (debt == 0) return;
        amount = bound(amount, 1, debt * 2);

        asset.mint(payer, amount);
        vm.startPrank(payer);
        asset.approve(address(borrowable), amount);
        try borrowable.repay(borrower, id, address(asset), amount) {
            calls["repay"]++;
        } catch {}
        vm.stopPrank();
    }

    function liquidate(uint256 liquidatorSeed, uint256 borrowerSeed, uint256 idSeed, uint256 assetSeed, uint256 amount)
        external
        sharePriceKept(false)
    {
        address liquidator = _actor(liquidatorSeed);
        uint256 id = _id(idSeed);
        address borrower = _debtor(id, borrowerSeed);
        if (borrower == address(0)) return;
        MockERC20 asset = _owedAsset(borrower, id, assetSeed);

        bool wasLiquidatable;
        try collateral.health(borrower, id) returns (HealthResultView memory h) {
            wasLiquidatable = h.minSurplusUsdWad < 0;
        } catch {}
        (uint256 collateralBefore, uint256 debtBefore) = _values(borrower, id);

        uint256 debt = borrowable.debtOf(borrower, id, address(asset));
        // Half the time go for the whole debt (the only way an underwater position gets fully seized)
        amount = amount % 2 == 0 ? debt + 1 : bound(amount, debt / 100 + 1, debt + 1);
        asset.mint(liquidator, amount);
        vm.startPrank(liquidator);
        asset.approve(address(borrowable), amount);
        vm.recordLogs();
        try lockLiquidator().liquidate(collateral, borrower, id, address(asset), amount, liquidator) {
            calls["liquidate"]++;
            if (!wasLiquidatable) _fail("liquidated a healthy position");
            // Taking the last unit writes off the rest in the same call: no bad debt waits on the lenders' books
            if (collateral.balanceOf(borrower, id) == 0) {
                if (borrowable.hasDebt(borrower, id)) _fail("a full seize left bad debt waiting");
                if (debtBefore != 0 && collateralBefore >= debtBefore * 102 / 100 && _wroteOffIn(vm.getRecordedLogs()))
                {
                    _fail("a liquidation wrote off a covered position's debt");
                }
                wroteOff = true;
                calls["writeOff"]++;
            }
            // Covered at 1.02x the debt, a liquidation of any size and debt keeps collateral / debt (all debts) where
            // it was or better, so lenders lose nothing. Tolerance: the valuation's whole-unit rounding of each token
            // (collateral down, debt up: under one USDC unit plus one wei of ETH each side, < 2e12 in USD wad)
            if (debtBefore != 0 && collateralBefore >= debtBefore * 102 / 100) {
                (uint256 collateralAfter, uint256 debtAfter) = _values(borrower, id);
                debtAfter = debtAfter > 2e12 ? debtAfter - 2e12 : 0;
                if ((collateralAfter + 2e12) * debtBefore < collateralBefore * debtAfter) {
                    _fail("a liquidation lowered a covered position's collateral / debt");
                }
            }
        } catch {}
        vm.stopPrank();
    }

    /// @dev The position's collateral and debt in USD at current prices (0, 0 if unpriced)
    function _values(address account, uint256 id) internal view returns (uint256 collateralUsd, uint256 debtUsd) {
        try collateral.health(account, id) returns (HealthResultView memory h) {
            (collateralUsd, debtUsd) = (h.collateralUsdWad, h.debtUsdWad);
        } catch {}
    }

    function resolveBadDebt(uint256 borrowerSeed, uint256 idSeed) external sharePriceKept(true) {
        uint256 id = _id(idSeed);
        address borrower = _debtor(id, borrowerSeed);
        if (borrower == address(0)) return;
        try collateral.resolveBadDebt(borrower, id) {
            calls["resolveBadDebt"]++;
            calls["writeOff"]++;
        } catch {}
    }

    /*  ================================================
                             Locks
        ================================================  */

    /**
     *  @notice A random script inside one lock, run by the LockScript actor: borrows of up to a market's whole cash
     *          (also against positions it holds no units in), moves of whole positions, redeems, unit transfers and
     *          write-offs, to any actor. Whatever it does, a lock that succeeds must leave no position with debt
     *          liquidatable that wasn't before, and must write off nothing (the 2026-10-05 audit's drain did both)
     */
    function lockScript(uint256 seed) external sharePriceKept(false) {
        LockScript script = LockScript(actors[actors.length - 1]);
        uint256 n = 1 + seed % 4;
        LockScript.Step[] memory steps = new LockScript.Step[](n);
        // Liquidations aim at a position that is liquidatable now, when there is one (a random actor and id almost
        // never is, so flash liquidations inside a lock went untested whenever the sequence didn't line one up)
        bool[] memory liquidatable = _liquidatableNow();
        uint256 targets;
        for (uint256 k; k < liquidatable.length; ++k) {
            if (liquidatable[k]) ++targets;
        }
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            MockERC20 asset = _asset(r >> 8);
            (uint256 supplied, uint256 borrowed) = _marketTotals(asset);
            uint256 cash = supplied > borrowed ? supplied - borrowed : 0;
            steps[i] = LockScript.Step({
                // A quarter of the steps borrow before an open or open, the rest are the other kinds
                kind: (r >> 200) % 4 == 0 ? uint8(6 + (r >> 208) % 2) : uint8((r >> 16) % 6),
                id: _id(r >> 24),
                asset: address(asset),
                // Half the time the whole cash, otherwise a slice of it
                amount: (r >> 32) % 2 == 0 ? cash : bound(r >> 40, 1, cash + 1),
                to: (r >> 48) % 4 == 0 ? address(script) : _actor(r >> 56)
            });
            if (steps[i].kind == 5 && targets > 0) {
                uint256 pick = (r >> 64) % targets;
                for (uint256 k; k < liquidatable.length; ++k) {
                    if (!liquidatable[k]) continue;
                    if (pick == 0) {
                        (steps[i].to, steps[i].id) = (actors[k / ids.length], ids[k % ids.length]);
                        steps[i].amount = type(uint256).max;
                        break;
                    }
                    --pick;
                }
            }
        }
        // Half the scripts that borrow before an open also open last, with a loan small enough to pass, so the whole
        // flow succeeds often too (a borrow with no open, or one that borrows all the cash, only ever reverts)
        if ((seed >> 128) % 2 == 0) {
            for (uint256 i; i + 1 < n; ++i) {
                if (steps[i].kind != 6) continue;
                steps[i].amount = steps[i].amount / 1000;
                steps[n - 1].kind = 7;
                // Opens L = 1e12 + 99e12 = 1e14, a full-range position worth ~$8.9k: enough for a thousandth of a
                // market's cash, so the flow passes its end-of-lock check (a $89 position almost never did)
                steps[n - 1].amount = 99e12;
                break;
            }
        }

        // Tokens to pay for any flash liquidation in the script
        weth.mint(address(script), 1_000e18);
        usdc.mint(address(script), 10_000_000e6);
        script.approve(address(weth), address(borrowable));
        script.approve(address(usdc), address(borrowable));

        bool[] memory wasLiquidatable = _liquidatableNow();
        vm.recordLogs();

        try script.run(steps) {
            calls["lockScript"]++;
            // The only write-off a lock may make: a flash liquidation taking the last unit of a position that was
            // liquidatable before the lock (never the script's own debt: the 2026-10-05 drain)
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 l; l < logs.length; ++l) {
                if (logs[l].emitter != address(borrowable) || logs[l].topics[0] != BAD_DEBT) continue;
                address victim = address(uint160(uint256(logs[l].topics[1])));
                uint256 vid = uint256(logs[l].topics[2]);
                uint256 a = _actorIndex(victim);
                uint256 i = _idIndex(vid);
                if (victim == address(script) || a == type(uint256).max || ids[i] != vid) {
                    _fail("a lock wrote off its own debt");
                } else if (!wasLiquidatable[a * ids.length + i] || collateral.balanceOf(victim, vid) != 0) {
                    _fail("a lock wrote off debt that wasn't bad before it");
                } else {
                    wroteOff = true;
                    calls["lockWriteOff"]++;
                }
            }
            bool[] memory nowLiquidatable = _liquidatableNow();
            for (uint256 k; k < nowLiquidatable.length; ++k) {
                if (nowLiquidatable[k] && !wasLiquidatable[k]) _fail("a lock left new debt unchecked");
            }
            // A lock that succeeded opened every id it borrowed against before it existed, and that position passed
            // its end-of-lock check (the new id joins `ids` only after the liquidation check below, which indexes the
            // pre-lock flags by the pre-lock number of ids)
            uint256 borrowedAgainst = script.borrowedAgainst();
            if (borrowedAgainst != 0) {
                if (script.openedId() != borrowedAgainst) _fail("a lock kept debt on an id it never opened");
                if (collateral.health(address(script), borrowedAgainst).minSurplusUsdWad < 0) {
                    _fail("a position borrowed against before its open ended liquidatable");
                }
                calls["lockBorrowBeforeOpen"]++;
            }
            // A flash liquidation inside the lock only ever hit a position that was liquidatable before the lock (the
            // script's own borrows can make it liquidatable mid-lock; those are its own positions)
            for (uint256 j; j < script.liquidatedLength(); ++j) {
                address victim = script.liquidatedAccounts(j);
                if (victim == address(script)) continue;
                uint256 a = _actorIndex(victim);
                uint256 k = a * ids.length + _idIndex(script.liquidatedIds(j));
                if (!wasLiquidatable[k]) _fail("a lock liquidated a healthy position");
                calls["lockFlashLiquidation"]++;
            }
            if (script.openedId() != 0) ids.push(script.openedId());
        } catch {}
    }

    function _wroteOffIn(Vm.Log[] memory logs) internal view returns (bool) {
        return badDebtIn(logs, address(borrowable), address(usdc)) != 0
            || badDebtIn(logs, address(borrowable), address(weth)) != 0;
    }

    function _actorIndex(address account) internal view returns (uint256) {
        for (uint256 a; a < actors.length; ++a) {
            if (actors[a] == account) return a;
        }
        return type(uint256).max;
    }

    function _idIndex(uint256 id) internal view returns (uint256) {
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == id) return i;
        }
        return 0;
    }

    function _marketTotals(MockERC20 asset) internal view returns (uint256 supplied, uint256 borrowed) {
        supplied = borrowable.getMarket(address(asset)).totalSupplyAssets;
        borrowed = borrowable.getMarket(address(asset)).totalBorrowAssets;
    }

    /// @dev For every (actor, id): holds debt and is liquidatable right now
    function _liquidatableNow() internal view returns (bool[] memory flags) {
        flags = new bool[](actors.length * ids.length);
        for (uint256 a; a < actors.length; ++a) {
            for (uint256 i; i < ids.length; ++i) {
                if (!borrowable.hasDebt(actors[a], ids[i])) continue;
                try collateral.health(actors[a], ids[i]) returns (HealthResultView memory h) {
                    flags[a * ids.length + i] = h.minSurplusUsdWad < 0;
                } catch {}
            }
        }
    }

    /*  ================================================
                          Environment
        ================================================  */

    /// @dev ETH moves; arbitrage keeps the pool near the oracle, as it would on a real DEX
    function setEthPrice(uint256 price) external sharePriceKept(false) {
        price = bound(price, 800e8, 5000e8);
        ethFeed.set(int256(price), block.timestamp);
        adapter.setPoolSqrtPrice(HealthMath.sqrtPriceX96FromUsd(price * 1e10, _price(usdc), 18, 6));
        calls["setEthPrice"]++;
    }

    function warp(uint256 seconds_) external sharePriceKept(false) {
        vm.warp(block.timestamp + bound(seconds_, 1, 3 days));
        (, int256 eth,,,) = ethFeed.latestRoundData();
        (, int256 usd,,,) = usdcFeed.latestRoundData();
        ethFeed.set(eth, block.timestamp);
        usdcFeed.set(usd, block.timestamp);
        calls["warp"]++;
    }
}

import {HealthResult as HealthResultView, lenderId} from "../../src/libraries/Types.sol";
import {lockLiquidator} from "../utils/LockLiquidator.sol";
