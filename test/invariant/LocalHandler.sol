// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {FeeLedger} from "../../src/adapters/FeeLedger.sol";
import {SenzuBorrowable} from "../../src/core/SenzuBorrowable.sol";
import {SenzuCollateral} from "../../src/core/SenzuCollateral.sol";
import {ISenzuAdapter} from "../../src/interfaces/ISenzuAdapter.sol";
import {ISenzuBorrowable} from "../../src/interfaces/ISenzuBorrowable.sol";
import {ISenzuCollateral} from "../../src/interfaces/ISenzuCollateral.sol";
import {ISenzuCore} from "../../src/interfaces/ISenzuCore.sol";
import {ISenzuFactory} from "../../src/interfaces/ISenzuFactory.sol";
import {ISenzuLockCallback} from "../../src/interfaces/ISenzuLockCallback.sol";
import {HealthMath} from "../../src/libraries/HealthMath.sol";
import {MarketLogic} from "../../src/libraries/MarketLogic.sol";
import {ACTION_BORROW, ACTION_OPEN, ACTION_SUPPLY, HealthResult, Market, lenderId} from "../../src/libraries/Types.sol";
import {LiquidityAmounts} from "../../src/libraries/uniswap/LiquidityAmounts.sol";
import {SenzuFactory} from "../../src/modules/SenzuFactory.sol";
import {SenzuOracle} from "../../src/modules/SenzuOracle.sol";
import {SenzuRiskConfig} from "../../src/modules/SenzuRiskConfig.sol";
import {BorrowableDeployer} from "../../src/modules/deployers/BorrowableDeployer.sol";
import {CollateralDeployer} from "../../src/modules/deployers/CollateralDeployer.sol";
import {MockAggregator, MockERC20} from "../mocks/Mocks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Vm} from "forge-std/Vm.sol";

interface IFeeGrowth {
    function feeGrowth(uint256 lpId) external view returns (uint256 growth0X128, uint256 growth1X128);
}

/**
 *  @notice The core and a real adapter against a real pool deployed locally (published bytecode, no fork), driven by
 *          random actions. Builds its whole world in the constructor and uses only cheatcodes Medusa has too, so the
 *          same contract runs under Foundry's invariant runner and under Medusa. Behaviour a call must have is checked
 *          where it happens (`violations`); what must hold between calls is in `checkAll`. Each exchange brings its
 *          pool, its deposits and the checks on its own books.
 */
abstract contract LocalHandler is ISenzuLockCallback {
    using MarketLogic for Market;

    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant DAO = address(0xDA0);
    address internal constant LENDER = address(0x1E4D);
    /// @dev Neither an account nor anyone's operator
    address internal constant OUTSIDER = address(0xBAD);
    /// @dev Dedicated fixed-budget attacker: funded once in `_list`/`_listOthers`, never minted free tokens again
    address internal constant ATTACKER = address(0xA77AC4);
    int24 internal constant SPACING = 60;
    uint256 internal constant MAX_IDS = 8;
    uint256 internal constant RANGES = 5;
    uint256 internal constant Q128 = 1 << 128;
    uint256 internal constant PENALTY_WAD = 1.05e18;
    /// @dev Borrowing rounds the debt's shares up and a partial repayment rounds them down: a wei each, the lenders'
    uint256 internal constant FLASH_TOLERANCE = 2;
    uint256 internal constant FEE_TOLERANCE = 2;

    uint8 internal constant LOCK_LIQUIDATE = 0;
    uint8 internal constant LOCK_LEVERED_OPEN = 1;
    uint8 internal constant LOCK_FLASH = 2;
    uint8 internal constant LOCK_BORROW_NO_OPEN = 3;
    uint8 internal constant LOCK_LIQUIDATE_NO_SETTLE = 4;
    uint8 internal constant LOCK_BORROW_THEN_LIQUIDATE = 5;
    uint8 internal constant LOCK_LEVER_UP = 6;
    uint8 internal constant LOCK_DELEVERAGE = 7;
    uint8 internal constant LOCK_REDEEM_ALL_OWING = 8;
    uint8 internal constant LOCK_ATTACKER_FLASH = 9;
    uint8 internal constant LOCK_ATTACKER_SELF_LIQ = 10;

    SenzuFactory public factory;
    SenzuOracle public oracle;
    SenzuRiskConfig public riskConfig;
    SenzuBorrowable public borrowable;
    SenzuCollateral public collateral;
    ISenzuAdapter public adapter;
    MockERC20 public weth;
    MockERC20 public usdc;
    MockERC20 public token0;
    MockERC20 public token1;
    MockAggregator public ethFeed;
    MockAggregator public usdcFeed;
    /// @dev A third token, liquid: any position may borrow it
    MockERC20 public dai;
    /// @dev Listed but not liquid: borrowable only by a position in its own pair, so never by this one
    MockERC20 public junk;
    MockAggregator public daiFeed;
    MockAggregator public junkFeed;

    address[] public actors;
    /// @dev Everyone who can hold units or lender shares
    address[] public holders;
    /// @dev Positions actions pick from, at most MAX_IDS: a closed one (no units, no debt) gives its slot up
    uint256[] public ids;
    /// @dev Every position ever opened, for the checks
    uint256[] public allIds;
    mapping(uint256 id => uint256) public rangeOf;
    int24[2][RANGES] public ranges;

    struct Snapshot {
        uint256 seen;
        uint256[] units;
        uint256[2][] owed;
        uint256[2][] wallets;
    }

    /// @dev A seize this action made: `units` of the `held` the borrower had went to `to`
    struct Seize {
        address from;
        address to;
        uint256 id;
        uint256 units;
        uint256 held;
    }

    struct Payout {
        address account;
        uint256 id;
        uint256 paid0;
        uint256 paid1;
    }

    /// @dev The shadow ledger: each account's fair fees per position, × 2^128, and each position's growth last read
    mapping(address account => mapping(uint256 id => uint256[2])) internal fairQ;
    /// @dev The part of `fairQ` earned since the account's own last checkpoint: a seize moves the seized units' part
    ///      of it to the liquidator, and the account's next checkpoint makes it its own
    mapping(address account => mapping(uint256 id => uint256[2])) internal openQ;
    /// @dev Each account's fee bookmark when the shadow last looked: one that moved since is a checkpoint
    mapping(address account => mapping(uint256 id => uint256[2])) internal seenMarks;
    Seize[] internal seizes;
    mapping(uint256 id => uint256[2]) internal lastGrowth;
    /// @dev Positions whose slot a newer one took: closed, nothing left to check
    mapping(uint256 id => bool) internal retired;
    Payout[] internal payouts;
    /// @dev The account an action acts for: the one whose wallet and fees it may move
    address internal _actor;
    /// @dev Set by an action that changes units and then swaps in the pool: the swap's fees went to the units after
    bool internal _creditAfter;
    uint256 public maxFeeDrift;

    /// @dev Tokens sent straight to a market (its books ignore them), and to the adapter (the next deposit's)
    mapping(address asset => uint256) public donatedToMarket;
    mapping(address token => uint256) public stray;

    /// @dev Part 1 attacker market conservation: per-asset deposits, withdrawals, and attacker-only share of accrued
    ///      share-price growth (Lean L5 shape: sum over accruals of `ceil(attackerShares * delta(sharePrice))`)
    mapping(address asset => uint256) public attackerMarketIn;
    mapping(address asset => uint256) public attackerMarketOut;
    mapping(address asset => uint256) public attackerYieldBound;
    mapping(address asset => uint256) internal _lastSupplyA;
    mapping(address asset => uint256) internal _lastSupplyS;

    uint256 public violations;
    string public lastViolation;
    uint256 public totalCalls;
    uint256 public maxFeeShortfall;
    uint256 public maxFlashExcess;
    mapping(bytes32 => uint256) public calls;

    constructor() {
        factory = new SenzuFactory(
            address(this), address(0x6A6D), DAO, address(new BorrowableDeployer()), address(new CollateralDeployer())
        );
        oracle = SenzuOracle(factory.oracle());
        riskConfig = SenzuRiskConfig(factory.riskConfig());
    }

    /// @dev After the exchange's set is deployed: feeds, markets, risk settings, lenders and actors
    function _list(ISenzuFactory.Deployment memory d, MockERC20 weth_, MockERC20 usdc_, bool wethIsToken0) internal {
        borrowable = SenzuBorrowable(d.borrowable);
        collateral = SenzuCollateral(d.collateral);
        adapter = ISenzuAdapter(d.adapter);
        (weth, usdc) = (weth_, usdc_);
        (token0, token1) = wethIsToken0 ? (weth, usdc) : (usdc, weth);

        ethFeed = new MockAggregator(8, 2000e8);
        usdcFeed = new MockAggregator(8, 1e8);
        oracle.addFeed(address(weth), address(ethFeed), 1 days);
        oracle.addFeed(address(usdc), address(usdcFeed), 1 days);
        borrowable.createMarket(address(usdc), 0.1e18);
        borrowable.createMarket(address(weth), 0.1e18);
        riskConfig.setBorrowFee(d.adapter, 0.001e18);
        riskConfig.setFeeCut(d.adapter, 0.02e18);
        riskConfig.setTokenRisk(d.adapter, address(weth), 1.15e18, uint64(PENALTY_WAD), true);
        riskConfig.setLiquid(d.adapter, address(weth));
        riskConfig.setTokenRisk(d.adapter, address(usdc), 1.02e18, uint64(PENALTY_WAD), true);
        riskConfig.setLiquid(d.adapter, address(usdc));
        riskConfig.setPairEnabled(d.adapter, address(token0), address(token1), true);
        _listOthers(d.adapter);

        usdc.approve(address(borrowable), type(uint256).max);
        weth.approve(address(borrowable), type(uint256).max);
        if (_seedMarkets()) {
            usdc.mint(address(this), 2_000_000e6);
            weth.mint(address(this), 1_000e18);
            borrowable.supply(address(usdc), 2_000_000e6, LENDER);
            borrowable.supply(address(weth), 1_000e18, LENDER);
        }

        actors = [address(0xA11CE), address(0xB0B), address(0xCA201), address(0xDA7E)];
        for (uint256 i; i < actors.length; ++i) {
            holders.push(actors[i]);
            vm.prank(actors[i]);
            collateral.setOperator(address(this), true);
        }
        holders.push(address(this));
        holders.push(DAO);
        holders.push(LENDER);
        holders.push(ATTACKER);

        // Fixed initial budget for ATTACKER, minted once and never again
        _give(usdc, ATTACKER, 500_000e6);
        _give(weth, ATTACKER, 250e18);
        vm.startPrank(ATTACKER);
        collateral.setOperator(address(this), true);
        usdc.approve(address(borrowable), type(uint256).max);
        weth.approve(address(borrowable), type(uint256).max);
        usdc.approve(address(this), type(uint256).max);
        weth.approve(address(this), type(uint256).max);
        vm.stopPrank();
        _resetAttackerBaseline(usdc);
        _resetAttackerBaseline(weth);
    }

    function _listOthers(address adapter_) internal {
        dai = new MockERC20("DAI", 18);
        junk = new MockERC20("JUNK", 18);
        daiFeed = new MockAggregator(8, 1e8);
        junkFeed = new MockAggregator(8, 5e8);
        oracle.addFeed(address(dai), address(daiFeed), 1 days);
        oracle.addFeed(address(junk), address(junkFeed), 1 days);
        borrowable.createMarket(address(dai), 0.1e18);
        borrowable.createMarket(address(junk), 0.1e18);
        riskConfig.setTokenRisk(adapter_, address(dai), 1.02e18, uint64(PENALTY_WAD), true);
        riskConfig.setLiquid(adapter_, address(dai));
        riskConfig.setTokenRisk(adapter_, address(junk), 1.5e18, uint64(PENALTY_WAD), true);
        dai.approve(address(borrowable), type(uint256).max);
        junk.approve(address(borrowable), type(uint256).max);
        if (_seedMarkets()) {
            dai.mint(address(this), 2_000_000e18);
            junk.mint(address(this), 1_000_000e18);
            borrowable.supply(address(dai), 2_000_000e18, LENDER);
            borrowable.supply(address(junk), 1_000_000e18, LENDER);
        }
        _give(dai, ATTACKER, 500_000e18);
        vm.startPrank(ATTACKER);
        dai.approve(address(borrowable), type(uint256).max);
        dai.approve(address(this), type(uint256).max);
        vm.stopPrank();
        _resetAttackerBaseline(dai);
    }

    /// @dev The pool's price at the oracle's
    function _oracleSqrtPriceX96() internal view returns (uint160) {
        (uint256 price0, uint8 decimals0) = oracle.priceWithDecimals(address(token0));
        (uint256 price1, uint8 decimals1) = oracle.priceWithDecimals(address(token1));
        return HealthMath.sqrtPriceX96FromUsd(price0, price1, decimals0, decimals1);
    }

    /// @dev Full range, wide and narrow around the tick, and one range on each side of it
    function _setRanges(int24 tick) internal {
        int24 base = (tick / SPACING) * SPACING;
        if (tick < 0 && tick % SPACING != 0) base -= SPACING;
        ranges[0] = [int24(-887220), int24(887220)];
        ranges[1] = [base - 1200, base + 1200];
        ranges[2] = [base - 120, base + 120];
        ranges[3] = [base + 600, base + 3000];
        ranges[4] = [base - 3000, base - 600];
    }

    /*  ================================================
                         The exchange's
        ================================================  */

    function _mintData(uint256 r, uint128 liquidity) internal view virtual returns (bytes memory);

    function mintDataFor(uint256 r, uint128 liquidity) external view returns (bytes memory) {
        return _mintData(r, liquidity);
    }

    /// @dev A swap in the pool by someone else; false if the pool refused it
    function _poolSwap(bool zeroForOne, uint256 amount) internal virtual returns (bool);

    /// @dev Neutral actor swaps the pool to `_oracleSqrtPriceX96()`; true iff the pool now sits at that exact price
    function _alignPoolToOracle() internal virtual returns (bool);

    /// @dev A swap in the pool paid strictly from `ATTACKER`'s own wallet (no minting)
    function _attackerPoolSwap(bool zeroForOne, uint256 amount) internal virtual returns (bool);

    /// @dev What someone else gives the pool or the adapter's ranges, from two seeds
    function _donate(uint256 a, uint256 b) internal virtual;

    /// @notice The pool's books against the positions' units
    function checkPool() public view virtual;

    /// @notice What holders are owed in fees is there for them to be paid
    function checkFeesBacked() public view virtual;

    /// @notice The adapter holds nothing but what its books say it holds
    function checkAdapterBalances() public view virtual;

    /// @notice The most any position (or v3 range) holds in fees that nobody is owed: rounding dust, or stuck
    function feeDust() public view virtual returns (uint256 dust0, uint256 dust1);

    /// @dev Adapter-specific checks after `unwindAll` has redeemed every unit and collected every fee
    function _checkUnwoundAdapter() internal view virtual;

    /// @dev Whether the constructor seeds `LENDER` into every market (false = cold-start empty-market mode)
    function _seedMarkets() internal pure virtual returns (bool) {
        return true;
    }

    /// @dev Whether swap fees compound into pool reserves (true on v2: swaps improve health rather than freezing it)
    function _feesCompoundIntoReserves() internal pure virtual returns (bool) {
        return false;
    }

    /// @dev Token amounts needed to deposit `liquidity` into range `r`
    function _quoteDeposit(uint256 r, uint128 liquidity)
        internal
        view
        virtual
        returns (uint256 amount0, uint256 amount1)
    {
        (,, amount0, amount1) = adapter.quoteDeposit(_mintData(r, liquidity));
    }

    /// @dev Fee growth inside `id` (zero for compounding adapters like v2)
    function _feeGrowthOf(uint256 id) internal view virtual returns (uint256, uint256) {
        return IFeeGrowth(address(adapter)).feeGrowth(id);
    }

    /// @dev The adapter's balance of `token` that no position's fees account for
    function _sentIn(MockERC20 token) internal view virtual returns (uint256) {
        return token.balanceOf(address(adapter));
    }

    function _give(MockERC20 token, address to, uint256 amount) internal virtual {
        token.mint(to, amount);
    }

    /*  ================================================
                            Helpers
        ================================================  */

    modifier action(bytes32 name) {
        _freshen();
        ++totalCalls;
        _syncAttackerOnAccrual();
        bool[] memory before = _liquidatable();
        Snapshot memory snapshot = _snapshot();
        _accrue(snapshot);
        _;
        _syncAttackerOnDrop();
        _settleShadow(snapshot);
        _compare(snapshot);
        delete seizes;
        _actor = address(0);
        _creditAfter = false;
        bool[] memory afterwards = _liquidatable();
        for (uint256 i; i < before.length; ++i) {
            if (afterwards[i] && !before[i]) {
                _fail(string.concat(_str(name), ": made a healthy position liquidatable"));
            }
        }
    }

    function _str(bytes32 name) internal pure returns (string memory) {
        return string(abi.encodePacked(name));
    }

    function _fail(string memory reason) internal {
        ++violations;
        lastViolation = reason;
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + x % (hi - lo + 1);
    }

    /// @dev Time moves between calls (warp, or Medusa's block delays): the feeds are republished at the same price
    function _freshen() internal {
        ethFeed.set(ethFeed.answer(), block.timestamp);
        usdcFeed.set(usdcFeed.answer(), block.timestamp);
        daiFeed.set(daiFeed.answer(), block.timestamp);
        junkFeed.set(junkFeed.answer(), block.timestamp);
    }

    /// @dev What a position may borrow: the pair's tokens and the liquid one
    function _asset(uint256 seed) internal view returns (MockERC20) {
        uint256 k = seed % 3;
        return k == 0 ? usdc : k == 1 ? weth : dai;
    }

    /// @dev One of `id`'s debts, from the seed's asset on; the seed's if it owes none
    function _debtAsset(address account, uint256 id, uint256 seed) internal view returns (MockERC20) {
        for (uint256 k; k < 3; ++k) {
            MockERC20 asset = _asset(seed + k);
            if (borrowable.debtOf(account, id, address(asset)) > 0) return asset;
        }
        return _asset(seed);
    }

    function _selector(bytes memory err) internal pure returns (bytes4 s) {
        if (err.length >= 4) {
            assembly ("memory-safe") {
                s := mload(add(err, 32))
            }
        }
    }

    /// @dev A holder of `id`'s units, zero if nobody holds any
    function _holderOf(uint256 id, uint256 seed) internal view returns (address) {
        uint256 n = holders.length;
        for (uint256 i; i < n; ++i) {
            address h = holders[(seed % n + i) % n];
            if (collateral.balanceOf(h, id) > 0) return h;
        }
        return address(0);
    }

    function _debtorOf(uint256 id, uint256 seed) internal view returns (address) {
        uint256 n = holders.length;
        for (uint256 i; i < n; ++i) {
            address h = holders[(seed % n + i) % n];
            if (borrowable.hasDebt(h, id)) return h;
        }
        return address(0);
    }

    function _liquidatable() internal view returns (bool[] memory flags) {
        flags = new bool[](holders.length * ids.length);
        for (uint256 i; i < ids.length; ++i) {
            for (uint256 j; j < holders.length; ++j) {
                if (borrowable.hasDebt(holders[j], ids[i])) {
                    flags[i * holders.length + j] = collateral.health(holders[j], ids[i]).minSurplusUsdWad < 0;
                }
            }
        }
    }

    function _healthHash() internal view returns (bytes32 h) {
        for (uint256 i; i < ids.length; ++i) {
            for (uint256 j; j < holders.length; ++j) {
                h = keccak256(abi.encode(h, collateral.health(holders[j], ids[i])));
            }
        }
    }

    function _fundAdapter(uint256 r, uint128 liquidity) internal {
        (uint256 amount0, uint256 amount1) = _quoteDeposit(r, liquidity);
        _give(token0, address(adapter), amount0);
        _give(token1, address(adapter), amount1);
    }

    function _drainAdapter() internal {
        token0.burn(address(adapter), _sentIn(token0));
        token1.burn(address(adapter), _sentIn(token1));
        _absorbed();
    }

    /// @dev A deposit took whatever lay in the adapter unbooked
    function _absorbed() internal {
        stray[address(token0)] = 0;
        stray[address(token1)] = 0;
    }

    function _usdToAsset(MockERC20 asset, uint256 usdWad) internal view returns (uint256) {
        (uint256 price, uint8 decimals) = oracle.priceWithDecimals(address(asset));
        return usdWad * 10 ** decimals / price;
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    /// @dev Where a new position goes in `ids`: past its end while there's room, else a closed position's slot
    function _freeSlot() internal view returns (uint256) {
        if (ids.length < MAX_IDS) return ids.length;
        for (uint256 i; i < ids.length; ++i) {
            if (_closed(ids[i])) return i;
        }
        return type(uint256).max;
    }

    function _closed(uint256 id) internal view returns (bool) {
        if (collateral.totalSupply(id) > 0) return false;
        for (uint256 j; j < holders.length; ++j) {
            if (borrowable.hasDebt(holders[j], id)) return false;
        }
        return true;
    }

    function _track(uint256 id, uint256 r) internal {
        uint256 slot = _freeSlot();
        if (slot == ids.length) {
            ids.push(id);
        } else {
            retired[ids[slot]] = true;
            ids[slot] = id;
        }
        allIds.push(id);
        rangeOf[id] = r;
    }

    /*  ================================================
                            Lending
        ================================================  */

    function supply(uint256 actorSeed, uint256 assetSeed, uint256 amount) external action("supply") {
        address a = actors[actorSeed % actors.length];
        _actor = a;
        MockERC20 asset = _asset(assetSeed);
        if (!_seedMarkets() && amount % 4 == 0) {
            amount = _bound(amount >> 2, 1, 10);
        } else if (!_seedMarkets() && amount % 4 == 1) {
            amount = _bound(amount >> 2, 11, 10_000);
        } else {
            amount = _bound(amount, 1, asset == usdc ? 500_000e6 : 250e18);
        }
        uint256[] memory claimsBefore = _lenderClaims(asset);
        asset.mint(a, amount);
        vm.prank(a);
        asset.approve(address(borrowable), amount);
        vm.prank(a);
        try borrowable.supply(address(asset), amount, a) returns (uint256 shares) {
            // Donations to the market never cost a depositor more than rounding
            if (borrowable.convertToAssets(address(asset), shares) + 2 < amount) _fail("supply: the claim fell short");
            _checkLenderClaimsDidNotDrop(asset, claimsBefore, a);
            ++calls["supply"];
        } catch (bytes memory err) {
            bytes4 sel = _selector(err);
            if (
                sel != ISenzuBorrowable.SenzuBorrowable__ZeroAmount.selector
                    && sel != ISenzuCore.SenzuCore__Paused.selector
            ) _fail("supply reverted");
            asset.burn(a, amount);
        }
    }

    function withdraw(uint256 holderSeed, uint256 assetSeed, uint256 fraction) external action("withdraw") {
        address a = holders[holderSeed % holders.length];
        if (a == ATTACKER) return;
        _actor = a;
        MockERC20 asset = _asset(assetSeed);
        uint256 bal = borrowable.balanceOf(a, lenderId(address(asset)));
        if (bal == 0) return;
        uint256 shares;
        if (!_seedMarkets() && fraction % 3 == 0) shares = bal;
        else if (!_seedMarkets() && fraction % 6 == 1) shares = 1;
        else shares = bal * _bound(fraction, 1, 1e18) / 1e18;
        if (shares == 0) return;
        uint256[] memory claimsBefore = _lenderClaims(asset);
        uint256 claim = borrowable.convertToAssets(address(asset), shares);
        vm.prank(a);
        try borrowable.withdraw(address(asset), shares, a, a) returns (uint256 assets) {
            if (assets > claim) _fail("withdraw paid more than the shares' claim");
            _checkLenderClaimsDidNotDrop(asset, claimsBefore, a);
            ++calls["withdraw"];
        } catch (bytes memory err) {
            bytes4 s = _selector(err);
            if (
                s != ISenzuBorrowable.SenzuBorrowable__InsufficientCash.selector
                    && s != ISenzuBorrowable.SenzuBorrowable__ZeroAmount.selector
            ) _fail("withdraw reverted");
        }
    }

    function _lenderClaims(MockERC20 asset) private view returns (uint256[] memory claims) {
        uint256 sid = lenderId(address(asset));
        claims = new uint256[](holders.length);
        for (uint256 j; j < holders.length; ++j) {
            claims[j] = borrowable.convertToAssets(address(asset), borrowable.balanceOf(holders[j], sid));
        }
    }

    function _checkLenderClaimsDidNotDrop(MockERC20 asset, uint256[] memory before_, address skip) private {
        uint256 sid = lenderId(address(asset));
        for (uint256 j; j < holders.length; ++j) {
            if (holders[j] == skip) continue;
            uint256 after_ = borrowable.convertToAssets(address(asset), borrowable.balanceOf(holders[j], sid));
            if (after_ + 1 < before_[j]) _fail("lender action lowered another lender's claim");
        }
    }

    /*  ================================================
                           Positions
        ================================================  */

    function open(uint256 actorSeed, uint256 rangeSeed, uint256 liquidity, bool exact) external action("open") {
        if (_freeSlot() == type(uint256).max) return;
        address a = actors[actorSeed % actors.length];
        _actor = a;
        uint256 r = rangeSeed % RANGES;
        uint128 l = uint128(_bound(liquidity, 1e9, 1e14));
        _fundAdapter(r, l);
        vm.prank(a);
        try collateral.open(a, a, _mintData(r, exact ? l : 0)) returns (
            uint256 id, uint256 units, address, address, uint256, uint256
        ) {
            if (units != adapter.units(id)) _fail("open: units differ from the adapter's");
            _track(id, r);
            _absorbed();
            ++calls["open"];
        } catch (bytes memory err) {
            if (_selector(err) != ISenzuCore.SenzuCore__Paused.selector) _fail("open reverted");
            _drainAdapter();
        }
    }

    function increase(uint256 holderSeed, uint256 idSeed, uint256 liquidity, bool skew) external action("increase") {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        address h = _holderOf(id, holderSeed);
        if (h == address(0) || h == ATTACKER) return;
        _actor = h;
        _fundAdapter(rangeOf[id], uint128(_bound(liquidity, 1e8, 1e13)));
        if (skew) _give(token0, address(adapter), _sentIn(token0) + 1);
        uint256 supplyBefore = collateral.totalSupply(id);
        int256 surplusBefore = collateral.health(h, id).minSurplusUsdWad;
        vm.prank(h);
        try collateral.increaseLiquidity(h, id, h, "") returns (uint256 added, uint256, uint256) {
            if (collateral.totalSupply(id) != supplyBefore + added) _fail("increase: supply moved by another amount");
            if (collateral.health(h, id).minSurplusUsdWad < surplusBefore) _fail("an increase lowered the health");
            _absorbed();
            ++calls["increase"];
        } catch {
            _fail("increase reverted");
            _drainAdapter();
        }
    }

    struct Redeem {
        uint256 balance;
        uint256 units;
        bool owing;
        uint256 owed0;
        uint256 owed1;
        uint256 expected0;
        uint256 expected1;
        uint256 before0;
        uint256 before1;
    }

    function redeem(uint256 holderSeed, uint256 idSeed, uint256 fraction) external action("redeem") {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        address h = _holderOf(id, holderSeed);
        if (h == address(0) || h == ATTACKER) return;
        _actor = h;
        Redeem memory r;
        r.balance = collateral.balanceOf(h, id);
        r.owing = borrowable.hasDebt(h, id);
        (r.owed0, r.owed1) = adapter.feesOwed(h, id);
        // A random fraction would almost never be everything: one in four redeems of an account owed fees (or on
        // compounding pools like v2, where no separate fees accrue) take all its units, one in sixteen of the rest
        bool all = fraction % 4 == 0 && (r.owed0 + r.owed1 > 0 || _feesCompoundIntoReserves() || fraction % 16 == 0);
        r.units = all ? r.balance : r.balance * _bound(fraction, 1, 1e18) / 1e18;
        if (r.units == 0) r.units = 1;
        // A close: everything repaid, then every unit redeemed
        if (all && r.owing) {
            _repayAll(h, id, usdc);
            _repayAll(h, id, weth);
            _repayAll(h, id, dai);
            r.owing = borrowable.hasDebt(h, id);
        }
        (r.expected0, r.expected1) = _amountsOf(id, r.units);
        if (!all && (r.expected0 == 0 || r.expected1 == 0)) {
            all = true;
            r.units = r.balance;
            if (r.owing) {
                _repayAll(h, id, usdc);
                _repayAll(h, id, weth);
                _repayAll(h, id, dai);
                r.owing = borrowable.hasDebt(h, id);
            }
            (r.expected0, r.expected1) = _amountsOf(id, r.units);
        }
        (r.before0, r.before1) = (token0.balanceOf(h), token1.balanceOf(h));
        vm.prank(h);
        try collateral.redeem(h, id, r.units, h, "") returns (uint256 amount0, uint256 amount1) {
            if (amount0 != r.expected0 || amount1 != r.expected1) _fail("redeem: amounts differ from the liquidity's");
            _checkRedeemed(h, id, r);
            ++calls["redeem"];
            if (r.units == r.balance && r.owed0 + r.owed1 > 0) ++calls["redeemAllWithFees"];
        } catch (bytes memory err) {
            if (!r.owing) {
                _fail("redeem with no debt reverted");
            } else if (_selector(err) != ISenzuCollateral.SenzuCollateral__InsufficientCollateral.selector) {
                _fail("redeem while owing reverted for another reason");
            }
        }
    }

    /// @dev The account got the liquidity's tokens, plus at most its fees on a full redeem; only that pays them
    function _checkRedeemed(address h, uint256 id, Redeem memory r) internal {
        bool all = r.units == r.balance;
        uint256 got0 = token0.balanceOf(h) - r.before0;
        uint256 got1 = token1.balanceOf(h) - r.before1;
        if (got0 < r.expected0 || got1 < r.expected1) _fail("redeem paid the account less than the liquidity");
        if (got0 > r.expected0 + (all ? r.owed0 : 0) || got1 > r.expected1 + (all ? r.owed1 : 0)) {
            _fail("redeem paid the account more than the liquidity and its fees");
        }
        if (all) {
            payouts.push(
                Payout(h, id, got0 > r.expected0 ? got0 - r.expected0 : 0, got1 > r.expected1 ? got1 - r.expected1 : 0)
            );
        }
        (uint256 left0, uint256 left1) = adapter.feesOwed(h, id);
        if (all && left0 + left1 > 0) _fail("a full redeem left fees unpaid");
        if (!all && (left0 + 1 < r.owed0 || left1 + 1 < r.owed1)) _fail("a partial redeem paid fees");
    }

    /// @dev What `units` of `id` are worth in tokens at the pool's price, rounded down as the pool pays them
    function _amountsOf(uint256 id, uint256 units) internal view virtual returns (uint256, uint256) {
        uint256 r = rangeOf[id];
        return LiquidityAmounts.getAmountsForLiquidity(
            adapter.poolSqrtPriceX96(id),
            TickMath.getSqrtPriceAtTick(ranges[r][0]),
            TickMath.getSqrtPriceAtTick(ranges[r][1]),
            uint128(units)
        );
    }

    function _repayAll(address h, uint256 id, MockERC20 asset) internal {
        uint256 debt = borrowable.debtOf(h, id, address(asset));
        if (debt == 0) return;
        asset.mint(address(this), debt);
        try borrowable.repay(h, id, address(asset), debt) {}
        catch {
            _fail("repaying a whole debt reverted");
        }
        asset.burn(address(this), asset.balanceOf(address(this)));
    }

    function collectFees(uint256 holderSeed, uint256 idSeed) external action("collectFees") {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        address h = holders[holderSeed % holders.length];
        _actor = h;
        (uint256 owed0, uint256 owed1) = adapter.feesOwed(h, id);
        vm.prank(h);
        try adapter.collectFees(h, id, h) returns (uint256 paid0, uint256 paid1) {
            if (paid0 > owed0 || paid1 > owed1) _fail("collectFees paid more than owed");
            payouts.push(Payout(h, id, paid0, paid1));
            uint256 short = (owed0 - paid0) > (owed1 - paid1) ? owed0 - paid0 : owed1 - paid1;
            if (short > maxFeeShortfall) maxFeeShortfall = short;
            if (owed0 + owed1 > 0) ++calls["collectFees"];
        } catch {
            _fail("collectFees reverted");
        }
    }

    function donate(uint256 a, uint256 b) external action("donate") {
        _donate(a, b);
        ++calls["donate"];
    }

    /*  ================================================
                              Debt
        ================================================  */

    function borrow(uint256 holderSeed, uint256 idSeed, uint256 assetSeed, uint256 bps) external action("borrow") {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        address h = _holderOf(id, holderSeed);
        if (h == address(0) || h == ATTACKER) return;
        _actor = h;
        MockERC20 asset = _asset(assetSeed);
        uint256 usd = collateral.health(h, id).collateralUsdWad * _bound(bps, 1, 9500) / 10_000;
        uint256 amount = !_seedMarkets() && bps % 5 == 0 ? 1 : _usdToAsset(asset, usd);
        if (amount == 0) return;
        uint256 debtBefore = borrowable.debtOf(h, id, address(asset));
        vm.prank(h);
        try collateral.borrow(h, id, address(asset), amount, h) {
            if (borrowable.debtOf(h, id, address(asset)) < debtBefore + amount) _fail("borrow: debt grew by less");
            if (collateral.health(h, id).minSurplusUsdWad < 0) _fail("borrow left the position liquidatable");
            ++calls["borrow"];
            if (asset == dai) ++calls["borrowLiquid"];
        } catch {}
    }

    function repay(uint256 holderSeed, uint256 idSeed, uint256 assetSeed, uint256 fraction) external action("repay") {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        address h = _debtorOf(id, holderSeed);
        if (h == address(0) || h == ATTACKER) return;
        MockERC20 asset = _asset(assetSeed);
        uint256 debt = borrowable.debtOf(h, id, address(asset));
        if (debt == 0) return;
        uint256 amount;
        if (!_seedMarkets() && fraction % 4 == 0) amount = 1;
        else if (!_seedMarkets() && fraction % 4 == 1) amount = debt;
        else amount = debt * _bound(fraction, 1, 1.2e18) / 1e18;
        if (amount == 0) amount = 1;
        asset.mint(address(this), amount);
        uint256 balance = asset.balanceOf(address(this));
        try borrowable.repay(h, id, address(asset), amount) returns (uint256 repaid) {
            if (repaid > amount || repaid > debt) _fail("repay took more than asked or owed");
            if (balance - asset.balanceOf(address(this)) != repaid) _fail("repay pulled another amount");
            if (borrowable.debtOf(h, id, address(asset)) > debt - repaid + 1) _fail("repay: debt fell by less");
            ++calls["repay"];
        } catch (bytes memory err) {
            if (_selector(err) != ISenzuBorrowable.SenzuBorrowable__ZeroAmount.selector) _fail("repay reverted");
        }
        asset.burn(address(this), asset.balanceOf(address(this)) - (balance - amount));
    }

    function resolveBadDebt(uint256 holderSeed, uint256 idSeed) external action("resolveBadDebt") {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        address h = _debtorOf(id, holderSeed);
        if (h == address(0)) return;
        uint256 units = collateral.balanceOf(h, id);
        bool noUnits = units == 0;
        try collateral.resolveBadDebt(h, id) {
            if (units > 0) seizes.push(Seize(h, factory.protocolReserves(), id, units, units));
            if (borrowable.hasDebt(h, id)) _fail("resolveBadDebt left debt");
            ++calls["resolveBadDebt"];
            ++calls["writeOff"];
        } catch {
            if (noUnits) _fail("resolveBadDebt reverted for a position with no units");
        }
    }

    /*  ================================================
                           The world
        ================================================  */

    /// @dev The pool price moves and fees accrue; on CL pools no position's health may change at all, and on
    ///      compounding pools (v2) swap fees can only improve (never lower) health
    function swap(bool zeroForOne, uint256 amount) external {
        _freshen();
        ++totalCalls;
        bool sellsWeth = (zeroForOne ? token0 : token1) == weth;
        amount = sellsWeth ? _bound(amount, 1e15, 60e18) : _bound(amount, 1e6, 120_000e6);
        if (_feesCompoundIntoReserves()) {
            bool[] memory liqBefore = _liquidatable();
            int256[] memory surBefore = _surpluses();
            if (_poolSwap(zeroForOne, amount)) ++calls["swap"];
            bool[] memory liqAfter = _liquidatable();
            int256[] memory surAfter = _surpluses();
            for (uint256 i; i < liqBefore.length; ++i) {
                if (liqAfter[i] && !liqBefore[i]) _fail("a swap made a healthy position liquidatable");
                if (surAfter[i] + 1e12 < surBefore[i]) _fail("a v2 swap lowered a position's surplus");
            }
            return;
        }
        bytes32 before = _healthHash();
        if (_poolSwap(zeroForOne, amount)) ++calls["swap"];
        if (_healthHash() != before) _fail("a swap in the pool changed a position's health");
    }

    function _surpluses() internal view returns (int256[] memory s) {
        s = new int256[](holders.length * ids.length);
        for (uint256 i; i < ids.length; ++i) {
            for (uint256 j; j < holders.length; ++j) {
                if (borrowable.hasDebt(holders[j], ids[i])) {
                    s[i * holders.length + j] = collateral.health(holders[j], ids[i]).minSurplusUsdWad;
                }
            }
        }
    }

    function setEthPrice(uint256 price) external {
        ++totalCalls;
        ethFeed.set(int256(_bound(price, 300e8, 12_000e8)), block.timestamp);
        _freshen();
        ++calls["setEthPrice"];
    }

    function setUsdcPrice(uint256 price) external {
        ++totalCalls;
        usdcFeed.set(int256(_bound(price, 0.8e8, 1.2e8)), block.timestamp);
        _freshen();
        ++calls["setUsdcPrice"];
    }

    /// @dev The guardian's switches stop supply, borrow and open only: repay, redeem, withdraw and liquidations go on,
    ///      which every other action checks by failing on any other revert
    function pause(uint256 actionSeed, bool paused) external {
        ++totalCalls;
        bytes32[3] memory switches = [ACTION_SUPPLY, ACTION_BORROW, ACTION_OPEN];
        riskConfig.setPaused(address(adapter), switches[actionSeed % 3], paused);
        ++calls["pause"];
    }

    /// @dev Tokens sent straight to the market, whose books must ignore them, or to the adapter, whose next deposit
    ///      takes them
    function donateTokens(uint256 targetSeed, uint256 assetSeed, uint256 amount) external action("donateTokens") {
        MockERC20 asset = _asset(assetSeed);
        amount = _bound(amount, 1, asset == usdc ? 100_000e6 : 50e18);
        if (targetSeed % 2 == 0) {
            asset.mint(address(borrowable), amount);
            donatedToMarket[address(asset)] += amount;
        } else {
            _give(asset, address(adapter), amount);
            stray[address(asset)] += amount;
        }
        ++calls["donateTokens"];
    }

    /// @dev Borrows a position may never take: an illiquid token outside its pair, or a third debt
    function borrowOutside(uint256 holderSeed, uint256 idSeed, uint256 which) external action("borrowOutside") {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        address h = _holderOf(id, holderSeed);
        if (h == address(0)) return;
        _actor = h;
        MockERC20 asset = junk;
        if (which % 2 == 1) {
            uint256 owed;
            for (uint256 k; k < 3; ++k) {
                if (borrowable.debtOf(h, id, address(_asset(k))) > 0) ++owed;
                else asset = _asset(k);
            }
            if (owed < 2) return;
        }
        vm.prank(h);
        try collateral.borrow(h, id, address(asset), 1e6, h) {
            _fail(
                asset == junk
                    ? "a position borrowed an illiquid token outside its pair"
                    : "a position took a third debt"
            );
        } catch (bytes memory err) {
            bytes4 sel = _selector(err);
            if (sel == ISenzuBorrowable.SenzuBorrowable__InsufficientCash.selector && !_seedMarkets()) return;
            if (
                sel != ISenzuCollateral.SenzuCollateral__IlliquidDebtOutsideItsPair.selector
                    && sel != ISenzuBorrowable.SenzuBorrowable__TooManyDebts.selector
                    && sel != ISenzuCore.SenzuCore__Paused.selector
            ) _fail("a forbidden borrow reverted for another reason");
            ++calls[asset == junk ? bytes32("borrowIlliquid") : bytes32("borrowThird")];
        }
    }

    /// @dev Someone who is neither the account nor its operator: each move on another account's position must revert,
    ///      as must liquidating a healthy position
    function trespass(uint256 kind, uint256 holderSeed, uint256 idSeed, uint256 assetSeed) external action("trespass") {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        address asset = address(_asset(assetSeed));
        kind = kind % 6;
        if (kind == 3 && _feesCompoundIntoReserves()) kind = 0;
        if (kind == 5) {
            address b = _debtorOf(id, holderSeed);
            if (b == address(0) || collateral.health(b, id).minSurplusUsdWad < 0) return;
            asset = address(_debtAsset(b, id, assetSeed));
            try collateral.lock(abi.encode(LOCK_LIQUIDATE, abi.encode(b, id, asset, 1, address(this)))) {
                _fail("a healthy position was liquidated");
            } catch {}
            ++calls["trespass"];
            return;
        }
        address h = _holderOf(id, holderSeed);
        if (h == address(0)) return;
        address target = address(collateral);
        bytes memory data;
        if (kind == 0) {
            data = abi.encodeCall(collateral.redeem, (h, id, 1, OUTSIDER, ""));
        } else if (kind == 1) {
            data = abi.encodeCall(collateral.borrow, (h, id, asset, 1, OUTSIDER));
        } else if (kind == 2) {
            data = abi.encodeCall(collateral.increaseLiquidity, (h, id, OUTSIDER, ""));
        } else if (kind == 3) {
            (target, data) = (address(adapter), abi.encodeCall(adapter.collectFees, (h, id, OUTSIDER)));
        } else {
            // A share is worth under a wei (virtual shares): a withdraw of one reverts for its size, so take 1%
            uint256 shares = borrowable.balanceOf(LENDER, lenderId(asset)) / 100;
            target = address(borrowable);
            data = abi.encodeCall(borrowable.withdraw, (asset, shares, OUTSIDER, LENDER));
        }
        vm.prank(OUTSIDER);
        (bool ok,) = target.call(data);
        if (ok) _fail("an outsider moved another account's position or shares");
        ++calls["trespass"];
    }

    function warp(uint256 secs) external {
        ++totalCalls;
        vm.warp(block.timestamp + _bound(secs, 1, 30 days));
        _freshen();
        ++calls["warp"];
    }

    /*  ================================================
                             Locks
        ================================================  */

    function liquidate(uint256 holderSeed, uint256 idSeed, uint256 assetSeed, uint256 amount)
        external
        action("liquidate")
    {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        address b = _debtorOf(id, holderSeed);
        if (b == address(0) || collateral.health(b, id).minSurplusUsdWad >= 0) return;
        MockERC20 asset = _debtAsset(b, id, assetSeed);
        uint256 debt = borrowable.debtOf(b, id, address(asset));
        amount = _bound(amount, 1, debt * 2);
        HealthResult memory h = collateral.health(b, id);
        uint256 units = collateral.balanceOf(b, id);
        // Seizing to the borrower itself moves nothing, so the handler's own debt is seized to someone else
        address receiver = b == address(this) ? actors[0] : address(this);
        uint256 mine = collateral.balanceOf(receiver, id);

        try collateral.lock(abi.encode(LOCK_LIQUIDATE, abi.encode(b, id, address(asset), amount, receiver))) returns (
            bytes memory out
        ) {
            (uint256 seized, uint256 repaid) = abi.decode(out, (uint256, uint256));
            if (seized > 0) seizes.push(Seize(b, receiver, id, seized, units));
            if (seized > units) _fail("liquidate seized more units than the borrower had");
            if (repaid > debt || repaid > amount) _fail("liquidate repaid more than owed or offered");
            if (collateral.balanceOf(b, id) != units - seized) _fail("liquidate: borrower units off");
            if (collateral.balanceOf(receiver, id) != mine + seized) _fail("liquidate: receiver units off");
            if (borrowable.debtOf(b, id, address(asset)) > debt - repaid + 1) _fail("liquidate: debt fell by less");
            (uint256 price, uint8 decimals) = oracle.priceWithDecimals(address(asset));
            uint256 repaidUsd = FullMath.mulDivRoundingUp(repaid, price, 10 ** decimals);
            uint256 seizedUsd = FullMath.mulDiv(h.collateralUsdWad, seized, units);
            if (seizedUsd > FullMath.mulDivRoundingUp(repaidUsd, PENALTY_WAD, 1e18) + 1e12) {
                _fail("liquidate seized more value than the repayment and its penalty");
            }
            ++calls["liquidate"];
            if (seized == units) {
                if (borrowable.hasDebt(b, id)) _fail("a full seize left bad debt waiting");
                ++calls["writeOff"];
            }
        } catch (bytes memory err) {
            bytes4 s = _selector(err);
            // Dust: a repayment under one debt share, or units worth nothing
            if (
                s != ISenzuBorrowable.SenzuBorrowable__ZeroAmount.selector
                    && s != ISenzuCollateral.SenzuCollateral__ZeroAmount.selector
            ) _fail("liquidating a liquidatable position reverted");
        }
    }

    /// @dev Borrows against the next id, then opens it: the router's leveraged open
    function leveredOpen(uint256 actorSeed, uint256 rangeSeed, uint256 liquidity, uint256 assetSeed, uint256 bps)
        external
        action("leveredOpen")
    {
        if (_freeSlot() == type(uint256).max) return;
        address a = actors[actorSeed % actors.length];
        _actor = a;
        uint256 r = rangeSeed % RANGES;
        uint128 l = uint128(_bound(liquidity, 1e9, 1e14));
        bytes memory data = abi.encode(a, r, l, address(_asset(assetSeed)), _bound(bps, 1, 9500));
        try collateral.lock(abi.encode(LOCK_LEVERED_OPEN, data)) returns (bytes memory out) {
            uint256 id = abi.decode(out, (uint256));
            _track(id, r);
            if (collateral.health(a, id).minSurplusUsdWad < 0) _fail("a leveraged open ended liquidatable");
            _absorbed();
            ++calls["leveredOpen"];
        } catch {}
    }

    /// @dev Borrows and repays inside one lock
    function flash(uint256 holderSeed, uint256 idSeed, uint256 assetSeed, uint256 amount) external action("flash") {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        address h = _holderOf(id, holderSeed);
        if (h == address(0) || h == DAO || h == ATTACKER) return;
        MockERC20 asset = _asset(assetSeed);
        amount = _bound(amount, 1, asset == usdc ? 100_000e6 : 50e18);
        uint256 debt = borrowable.debtOf(h, id, address(asset));
        try collateral.lock(abi.encode(LOCK_FLASH, abi.encode(h, id, address(asset), amount, address(this)))) {
            uint256 left = borrowable.debtOf(h, id, address(asset));
            if (left > debt && left - debt > maxFlashExcess) maxFlashExcess = left - debt;
            if (left > debt + FLASH_TOLERANCE) _fail("a flash borrow left more debt");
            ++calls["flash"];
        } catch {}
    }

    /// @dev Borrows against a position and adds the liquidity the loan buys, in one lock: the router's leverage up
    function leverUp(uint256 holderSeed, uint256 idSeed, uint256 liquidity, uint256 assetSeed, uint256 bps)
        external
        action("leverUp")
    {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        address h = _holderOf(id, holderSeed);
        if (h == address(0) || h == DAO || h == ATTACKER) return;
        _actor = h;
        address asset = address(_asset(assetSeed));
        uint256 units = collateral.balanceOf(h, id);
        uint256 debt = borrowable.debtOf(h, id, asset);
        bytes memory data = abi.encode(h, id, asset, uint128(_bound(liquidity, 1e8, 1e13)), _bound(bps, 1, 9500));
        try collateral.lock(abi.encode(LOCK_LEVER_UP, data)) returns (bytes memory out) {
            (uint256 added, uint256 borrowed) = abi.decode(out, (uint256, uint256));
            if (collateral.balanceOf(h, id) != units + added) _fail("leverUp: units off");
            if (borrowable.debtOf(h, id, asset) < debt + borrowed) _fail("leverUp: debt grew by less");
            // A borrow leaves a check pending; with nothing borrowed, an under-water position may still add liquidity
            if (borrowed > 0 && collateral.health(h, id).minSurplusUsdWad < 0) {
                _fail("a lever-up that borrowed ended liquidatable");
            }
            _absorbed();
            ++calls["leverUp"];
        } catch (bytes memory err) {
            bytes4 sel = _selector(err);
            if (
                sel != ISenzuCollateral.SenzuCollateral__InsufficientCollateral.selector
                    && sel != ISenzuBorrowable.SenzuBorrowable__InsufficientCash.selector
                    && sel != ISenzuCore.SenzuCore__Paused.selector
                    && sel != ISenzuBorrowable.SenzuBorrowable__TooManyDebts.selector
            ) _fail("a lever-up reverted for another reason than health, cash, a pause or a third debt");
        }
    }

    /// @dev Redeems part of a position and repays debt with what came out, in one lock: the router's deleverage
    function deleverage(uint256 holderSeed, uint256 idSeed, uint256 assetSeed, uint256 fraction)
        external
        action("deleverage")
    {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        address h = _debtorOf(id, holderSeed);
        if (h == address(0) || h == ATTACKER) return;
        _actor = h;
        uint256 balance = collateral.balanceOf(h, id);
        uint256 units = balance * _bound(fraction, 1, 9000) / 10_000;
        if (units == 0) return;
        MockERC20 asset = _debtAsset(h, id, assetSeed);
        uint256 debt = borrowable.debtOf(h, id, address(asset));
        try collateral.lock(
            abi.encode(LOCK_DELEVERAGE, abi.encode(h, id, address(asset), units, address(this)))
        ) returns (
            bytes memory out
        ) {
            uint256 repaid = abi.decode(out, (uint256));
            if (collateral.balanceOf(h, id) != balance - units) _fail("deleverage: units off");
            if (borrowable.debtOf(h, id, address(asset)) > debt - repaid + 1) _fail("deleverage: debt fell by less");
            if (collateral.health(h, id).minSurplusUsdWad < 0) _fail("a deleverage ended liquidatable");
            ++calls["deleverage"];
        } catch (bytes memory err) {
            if (_selector(err) != ISenzuCollateral.SenzuCollateral__InsufficientCollateral.selector) {
                _fail("a deleverage reverted for another reason than health");
            }
        }
    }

    /// @dev Four locks that must never end
    function badLock(uint256 kind, uint256 holderSeed, uint256 idSeed, uint256 assetSeed, uint256 amount)
        external
        action("badLock")
    {
        MockERC20 asset = _asset(assetSeed);
        kind = kind % 4;
        if (kind == 0) {
            address a = actors[holderSeed % actors.length];
            amount = _bound(amount, 1, asset == usdc ? 1_000e6 : 1e18);
            try collateral.lock(abi.encode(LOCK_BORROW_NO_OPEN, abi.encode(a, address(asset), amount))) {
                _fail("a lock ended with debt on a position that was never opened");
            } catch {
                ++calls["badLock"];
            }
            return;
        }
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        if (kind == 3) {
            address b = _debtorOf(id, holderSeed);
            if (b == address(0) || collateral.balanceOf(b, id) == 0) return;
            try collateral.lock(abi.encode(LOCK_REDEEM_ALL_OWING, abi.encode(b, id, address(0), 0, address(this)))) {
                _fail("a lock ended with debt and every unit redeemed");
            } catch {
                ++calls["badLock"];
            }
            return;
        }
        if (kind == 1) {
            address b = _debtorOf(id, holderSeed);
            if (b == address(0) || collateral.health(b, id).minSurplusUsdWad >= 0) return;
            uint256 debt = borrowable.debtOf(b, id, address(asset));
            if (debt == 0) return;
            try collateral.lock(
                abi.encode(LOCK_LIQUIDATE_NO_SETTLE, abi.encode(b, id, address(asset), debt, address(this)))
            ) {
                _fail("a lock ended with a liquidation unpaid");
            } catch {
                ++calls["badLock"];
            }
        } else {
            address h = _holderOf(id, holderSeed);
            if (h == address(0) || h == DAO || h == address(this) || h == ATTACKER || borrowable.hasDebt(h, id)) {
                return;
            }
            // Enough to fail the stress test, little enough that repaying it all leaves units and no debt
            uint256 usd = collateral.health(h, id).collateralUsdWad * 93 / 100;
            uint256 want = _usdToAsset(asset, usd);
            if (want == 0) return;
            try collateral.lock(
                abi.encode(LOCK_BORROW_THEN_LIQUIDATE, abi.encode(h, id, address(asset), want, address(this)))
            ) {
                _fail("a position was liquidated on debt taken in the same lock");
            } catch {
                ++calls["badLock"];
            }
        }
    }

    function senzuLockAcquired(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(collateral), "not the collateral");
        (uint8 kind, bytes memory p) = abi.decode(data, (uint8, bytes));

        if (kind == LOCK_LEVERED_OPEN) {
            (address a, uint256 r, uint128 l, address asset, uint256 bps) =
                abi.decode(p, (address, uint256, uint128, address, uint256));
            uint256 id = collateral.nextPositionId();
            (uint256 amount0, uint256 amount1) = _quoteDeposit(r, l);
            uint256 usd = _usd(token0, amount0) + _usd(token1, amount1);
            uint256 amount = _usdToAsset(MockERC20(asset), usd * bps / 10_000);
            if (amount > 0) collateral.borrow(a, id, asset, amount, a);
            _fundAdapter(r, l);
            collateral.open(a, address(this), _mintData(r, l));
            return abi.encode(id);
        }
        if (kind == LOCK_BORROW_NO_OPEN) {
            (address a, address asset, uint256 amount) = abi.decode(p, (address, address, uint256));
            collateral.borrow(a, collateral.nextPositionId(), asset, amount, a);
            return "";
        }

        if (kind == LOCK_LEVER_UP) return _leverUpInLock(p);

        (address account, uint256 positionId, address debtAsset, uint256 assets, address receiver) =
            abi.decode(p, (address, uint256, address, uint256, address));
        if (kind == LOCK_DELEVERAGE) return abi.encode(_deleverageInLock(account, positionId, debtAsset, assets));
        if (kind == LOCK_REDEEM_ALL_OWING) {
            collateral.redeem(account, positionId, collateral.balanceOf(account, positionId), receiver, "");
            return "";
        }
        if (kind == LOCK_FLASH) {
            uint256 debt = borrowable.debtOf(account, positionId, debtAsset);
            collateral.borrow(account, positionId, debtAsset, assets, address(this));
            uint256 owed = borrowable.debtOf(account, positionId, debtAsset) - debt;
            MockERC20(debtAsset).mint(address(this), owed - assets);
            borrowable.repay(account, positionId, debtAsset, owed);
            return "";
        }
        if (kind == LOCK_ATTACKER_FLASH) {
            uint256 debtBefore = borrowable.debtOf(account, positionId, debtAsset);
            collateral.borrow(account, positionId, debtAsset, assets, account);
            uint256 owed = borrowable.debtOf(account, positionId, debtAsset) - debtBefore;
            vm.prank(account);
            borrowable.repay(account, positionId, debtAsset, owed);
            return "";
        }
        if (kind == LOCK_ATTACKER_SELF_LIQ) {
            (uint256 seized, uint256 repaid, uint256 fee) =
                collateral.liquidate(account, positionId, debtAsset, assets, account);
            uint256 due = repaid + fee;
            MockERC20(debtAsset).transferFrom(account, address(this), due);
            collateral.settle(debtAsset, due);
            return abi.encode(seized, repaid);
        }
        if (kind == LOCK_BORROW_THEN_LIQUIDATE) {
            // Everything owed is repaid and settled, so the lock would end with the position debt-free: only the
            // pending check stands between the locker and the borrower's units
            collateral.borrow(account, positionId, debtAsset, assets, address(this));
            (, uint256 paid, uint256 fee) =
                collateral.liquidate(account, positionId, debtAsset, type(uint256).max, receiver);
            uint256 due = paid + fee;
            MockERC20(debtAsset).mint(address(this), due);
            collateral.settle(debtAsset, due);
            return "";
        }
        (uint256 seized, uint256 repaid, uint256 fee) =
            collateral.liquidate(account, positionId, debtAsset, assets, receiver);
        if (kind == LOCK_LIQUIDATE) {
            uint256 due = repaid + fee;
            MockERC20(debtAsset).mint(address(this), due);
            collateral.settle(debtAsset, due);
        }
        return abi.encode(seized, repaid);
    }

    /// @dev The loan buys the liquidity: borrowed at `bps` of the added liquidity's value, spent on it
    function _leverUpInLock(bytes memory p) internal returns (bytes memory) {
        (address a, uint256 id, address asset, uint128 l, uint256 bps) =
            abi.decode(p, (address, uint256, address, uint128, uint256));
        (uint256 amount0, uint256 amount1) = _quoteDeposit(rangeOf[id], l);
        uint256 borrowed = _usdToAsset(MockERC20(asset), (_usd(token0, amount0) + _usd(token1, amount1)) * bps / 10_000);
        if (borrowed > 0) collateral.borrow(a, id, asset, borrowed, address(this));
        MockERC20(asset).burn(address(this), borrowed);
        _fundAdapter(rangeOf[id], l);
        (uint256 added,,) = collateral.increaseLiquidity(a, id, address(this), "");
        return abi.encode(added, borrowed);
    }

    /// @dev The redeemed tokens are sold for the debt asset at the oracle price, and that repays the debt
    function _deleverageInLock(address h, uint256 id, address asset, uint256 units) internal returns (uint256 repaid) {
        (uint256 got0, uint256 got1) = collateral.redeem(h, id, units, address(this), "");
        token0.burn(address(this), got0);
        token1.burn(address(this), got1);
        repaid = _usdToAsset(MockERC20(asset), _usd(token0, got0) + _usd(token1, got1));
        uint256 debt = borrowable.debtOf(h, id, asset);
        if (repaid > debt) repaid = debt;
        if (repaid == 0) return 0;
        MockERC20(asset).mint(address(this), repaid);
        repaid = borrowable.repay(h, id, asset, repaid);
    }

    /*  ================================================
                         Shadow ledger
        ================================================  */

    function _snapshot() internal view returns (Snapshot memory s) {
        uint256 n = holders.length;
        uint256 m = allIds.length;
        s.seen = m;
        s.units = new uint256[](n * m);
        s.owed = new uint256[2][](n * m);
        s.wallets = new uint256[2][](n);
        for (uint256 a; a < n; ++a) {
            s.wallets[a] = [token0.balanceOf(holders[a]), token1.balanceOf(holders[a])];
            for (uint256 i; i < m; ++i) {
                if (retired[allIds[i]]) continue;
                s.units[a * m + i] = collateral.balanceOf(holders[a], allIds[i]);
                (s.owed[a * m + i][0], s.owed[a * m + i][1]) = adapter.feesOwed(holders[a], allIds[i]);
            }
        }
    }

    /// @dev Growth since the last read was earned at the units held before the action: read before it (what swaps
    ///      and donations between actions earned) and after it (what the action itself books, as a seize or a
    ///      collect). A position the action emptied isn't read after: the DEX clears an emptied range's ticks
    function _accrue(Snapshot memory before) internal {
        for (uint256 i; i < allIds.length; ++i) {
            uint256 id = allIds[i];
            if (retired[id]) continue;
            (uint256 g0, uint256 g1) = _feeGrowthOf(id);
            if (i < before.seen && collateral.totalSupply(id) > 0) _credit(before, i, id, g0, g1);
            lastGrowth[id] = [g0, g1];
        }
    }

    /// @dev After the action: its seizes moved, its growth credited, a payout zeroes what it settled, every account
    ///      owed its fair share. An action that swaps after its units change (`_creditAfter`) checkpointed before the
    ///      swap's fees, any other after its growth
    function _settleShadow(Snapshot memory before) internal {
        uint256 m = before.seen;
        _moveSeized();
        if (_creditAfter) _closeCheckpointed();
        _accrue(before);
        if (!_creditAfter) _closeCheckpointed();
        for (uint256 c; c < payouts.length; ++c) {
            Payout memory p = payouts[c];
            uint256[2] storage fair = fairQ[p.account][p.id];
            if (p.paid0 > fair[0] / Q128 + FEE_TOLERANCE || p.paid1 > fair[1] / Q128 + FEE_TOLERANCE) {
                _fail("a payout exceeded its pro-rata share");
            }
            fair[0] = 0;
            fair[1] = 0;
            delete openQ[p.account][p.id];
        }
        delete payouts;
        for (uint256 i; i < m; ++i) {
            if (retired[allIds[i]]) continue;
            for (uint256 a; a < holders.length; ++a) {
                (uint256 owed0, uint256 owed1) = adapter.feesOwed(holders[a], allIds[i]);
                _checkFair(owed0, fairQ[holders[a]][allIds[i]][0] / Q128);
                _checkFair(owed1, fairQ[holders[a]][allIds[i]][1] / Q128);
            }
        }
    }

    function _credit(Snapshot memory before, uint256 i, uint256 id, uint256 g0, uint256 g1) internal {
        uint256 d0;
        uint256 d1;
        // Fee growth wraps, as in Uniswap
        unchecked {
            d0 = g0 - lastGrowth[id][0];
            d1 = g1 - lastGrowth[id][1];
        }
        for (uint256 a; a < holders.length; ++a) {
            uint256 units = _creditAfter ? collateral.balanceOf(holders[a], id) : before.units[a * before.seen + i];
            if (units == 0) continue;
            fairQ[holders[a]][id][0] += units * d0;
            fairQ[holders[a]][id][1] += units * d1;
            openQ[holders[a]][id][0] += units * d0;
            openQ[holders[a]][id][1] += units * d1;
        }
    }

    /// @dev Each seized unit takes its pro-rata share of everything unclaimed (credited and open)
    function _moveSeized() internal {
        for (uint256 s; s < seizes.length; ++s) {
            Seize memory z = seizes[s];
            for (uint256 k; k < 2; ++k) {
                uint256 moved = FullMath.mulDiv(fairQ[z.from][z.id][k], z.units, z.held);
                fairQ[z.from][z.id][k] -= moved;
                fairQ[z.to][z.id][k] += moved;
            }
        }
    }

    /// @dev An account whose bookmark moved checkpointed its own units, unless it only took seized ones
    function _closeCheckpointed() internal {
        for (uint256 i; i < allIds.length; ++i) {
            uint256 id = allIds[i];
            if (retired[id]) continue;
            for (uint256 a; a < holders.length; ++a) {
                uint256[2] memory mark = _feeMarks(holders[a], id);
                uint256[2] storage seen = seenMarks[holders[a]][id];
                if (mark[0] == seen[0] && mark[1] == seen[1]) continue;
                if (!_tookSeizedOnly(holders[a], id)) delete openQ[holders[a]][id];
                (seen[0], seen[1]) = (mark[0], mark[1]);
            }
        }
    }

    function _tookSeizedOnly(address account, uint256 id) internal view returns (bool) {
        for (uint256 s; s < seizes.length; ++s) {
            if (seizes[s].to == account && seizes[s].id == id) return true;
        }
        return false;
    }

    /// @dev An account's fee bookmark in a position (the adapter's `checkpoints`)
    function _feeMarks(address account, uint256 id) internal view virtual returns (uint256[2] memory m) {
        (m[0], m[1],,) = FeeLedger(address(adapter)).checkpoints(account, id);
    }

    /// @dev The adapter floors each checkpoint, the ledger once: owed at most the fair amount, a wei per call under
    /// @dev An amount less the protocol's cut, as the adapter's views and payouts show it: the shadows here count
    ///      fees and rewards before it
    function _lessCut(uint256 amount) internal view returns (uint256) {
        (uint256 cutWad,) = SenzuRiskConfig(collateral.riskConfig()).feeCut(address(adapter));
        return amount - amount * cutWad / 1e18;
    }

    function _checkFair(uint256 owed, uint256 fair) internal {
        fair = _lessCut(fair);
        if (owed > fair + FEE_TOLERANCE) _fail("an account is owed more than its pro-rata share");
        if (owed + totalCalls + FEE_TOLERANCE < fair) _fail("an account is owed less than its pro-rata share");
        uint256 drift = owed > fair ? owed - fair : fair - owed;
        if (drift > maxFeeDrift) maxFeeDrift = drift;
    }

    /// @dev Nobody but the account acted for (and the handler, which pays and is paid for everyone) sees its wallet
    ///      move or its fees owed fall
    function _compare(Snapshot memory before) internal {
        uint256 m = before.seen;
        for (uint256 a; a < holders.length; ++a) {
            address account = holders[a];
            if (account == _actor || account == address(this)) continue;
            // The DAO's wallet takes the protocol's cut of every payout
            bool moved =
                token0.balanceOf(account) != before.wallets[a][0] || token1.balanceOf(account) != before.wallets[a][1];
            if (moved && account != DAO) _fail("an action moved another account's wallet");
            for (uint256 i; i < m; ++i) {
                if (retired[allIds[i]] || _seizedFrom(account, allIds[i])) continue;
                (uint256 owed0, uint256 owed1) = adapter.feesOwed(account, allIds[i]);
                if (
                    owed0 + FEE_TOLERANCE < before.owed[a * m + i][0]
                        || owed1 + FEE_TOLERANCE < before.owed[a * m + i][1]
                ) _fail("an action lowered another account's fees");
            }
        }
    }

    function _seizedFrom(address account, uint256 id) internal view returns (bool) {
        for (uint256 s; s < seizes.length; ++s) {
            if (seizes[s].from == account && seizes[s].id == id) return true;
        }
        return false;
    }

    /*  ================================================
                           Invariants
        ================================================  */

    function checkAll() external view {
        require(violations == 0, lastViolation);
        checkUnits();
        checkPool();
        checkMarket(usdc);
        checkMarket(weth);
        checkMarket(dai);
        checkMarket(junk);
        require(
            borrowable.getMarket(address(junk)).totalBorrowAssets == 0, "an illiquid token was lent outside its pair"
        );
        checkFeesBacked();
        checkHealthAgainstReference();
        checkAdapterBalances();
        checkNoStuckFees();
        checkAttackerMarket(usdc);
        checkAttackerMarket(weth);
        checkAttackerMarket(dai);
    }

    /*  ================================================
                       Attacker-profit
        ================================================  */

    /// @notice Part 1 (continuous): `ATTACKER`'s cumulative market withdrawals plus current lender claim can never
    ///         exceed its cumulative deposits plus its own share of accrued share-price growth (`sum ceil(sh * ΔP)`)
    function checkAttackerMarket(MockERC20 asset) public view {
        address a = address(asset);
        uint256 sh = borrowable.balanceOf(ATTACKER, lenderId(a));
        uint256 claim = borrowable.convertToAssets(a, sh);
        uint256 pending = _pendingAttackerYield(asset, sh);
        require(
            attackerMarketOut[a] + claim <= attackerMarketIn[a] + attackerYieldBound[a] + pending,
            "attacker profited from market"
        );
    }

    function attackerSupply(uint256 assetSeed, uint256 amountSeed) external action("attackerSupply") {
        _actor = ATTACKER;
        if (_attackerSupplyOne(assetSeed, amountSeed)) ++calls["attackerSupply"];
    }

    function attackerWithdraw(uint256 assetSeed, uint256 fractionSeed) external action("attackerWithdraw") {
        _actor = ATTACKER;
        if (_attackerWithdrawOne(assetSeed, fractionSeed)) ++calls["attackerWithdraw"];
    }

    /// @notice Part 2A: frozen-world multi-step burst (same timestamp, frozen oracle and pool prices, zero external
    ///         swaps, no stray tokens in adapter). Per-asset net worth `Net(a) = wallet + lenderClaim + principal +
    ///         feesOwed - debt` must never increase for any asset `a`
    function attackerBurst(uint256 seed) external action("attackerBurst") {
        if (stray[address(token0)] > 0 || stray[address(token1)] > 0) return;
        _actor = ATTACKER;
        _accrueAllMarkets();
        int256[3] memory before = _attackerNet();
        uint256 steps = _bound(seed, 2, 6);
        uint256 cur = seed;
        bool didAny;
        for (uint256 i; i < steps; ++i) {
            cur = uint256(keccak256(abi.encode(cur, i)));
            if (_attackerBurstStep(cur, false)) didAny = true;
        }
        int256[3] memory after_ = _attackerNet();
        // A repayment books what its shares were worth, rounded down: a borrower who is also the market's lender gets
        // back under a wei per step of its own rounding, never a whole wei
        int256 rounding = int256(steps * NET_SCALE);
        for (uint256 k; k < 3; ++k) {
            if (after_[k] > before[k] + rounding) _fail("attackerBurst: attacker net worth increased");
        }
        if (didAny) ++calls["attackerBurst"];
    }

    /// @notice Part 2B: aligns the pool to the oracle price with a neutral actor first, then lets `ATTACKER` mix pool
    ///         swaps (paid from its own wallet) with borrow/redeem/open/repay/supply/withdraw/self-liquidate. Holdings
    ///         after arbitrage are the cheapest point, so total value at the frozen oracle prices must never rise
    function attackerSwapBurst(uint256 seed) external {
        if (stray[address(token0)] > 0 || stray[address(token1)] > 0) return;
        _freshen();
        ++totalCalls;
        _syncAttackerOnAccrual();
        _syncShadowNow();
        if (!_alignPoolToOracle()) return;
        _syncShadowNow();
        _accrueAllMarkets();

        int256 usdBefore = _attackerUsdScaled();
        uint256 steps = _bound(seed, 2, 6);
        uint256 cur = seed;
        bool didSwap;
        for (uint256 i; i < steps; ++i) {
            cur = uint256(keccak256(abi.encode(cur, i)));
            if (cur % 3 == 0) {
                if (_attackerSwapStep(cur >> 8)) didSwap = true;
            } else {
                _attackerBurstStep(cur >> 8, true);
            }
        }
        _syncAttackerOnDrop();
        int256 usdAfter = _attackerUsdScaled();
        if (usdAfter > usdBefore) _fail("attackerSwapBurst: attacker gained oracle USD value");
        _syncShadowNow();
        _checkAllFeesAgainstShadow();
        if (didSwap) ++calls["attackerSwapBurst"];
    }

    function _attackerBurstStep(uint256 s, bool inlineShadow) internal returns (bool) {
        uint256 kind = s % 12;
        uint256 a = uint256(keccak256(abi.encode(s, 1)));
        uint256 b = uint256(keccak256(abi.encode(s, 2)));
        if (kind == 0) return _attackerSupplyOne(a, b);
        if (kind == 1) return _attackerWithdrawOne(a, b);
        if (kind == 2) return _attackerDonateMarketOne(a, b);
        if (kind == 3) return _attackerOpenOne(a, b, inlineShadow);
        if (kind == 4) return _attackerIncreaseOne(a, b);
        if (kind == 5) return _attackerRedeemOne(a, b, inlineShadow);
        if (kind == 6) return _attackerCollectOne(a, inlineShadow);
        if (kind == 7) return _attackerBorrowOne(a, b);
        if (kind == 8) return _attackerRepayOne(a, b);
        if (kind == 9) return _attackerFlashOne(a, b);
        if (kind == 10) return _attackerSelfLiqOne(a, b);
        return _attackerResolveBadDebtOne(a);
    }

    function _attackerSupplyOne(uint256 assetSeed, uint256 amountSeed) internal returns (bool) {
        MockERC20 asset = _asset(assetSeed);
        uint256 bal = asset.balanceOf(ATTACKER);
        if (bal == 0) return false;
        uint256 amount;
        if (amountSeed % 5 == 0) amount = _bound(amountSeed >> 3, 1, bal < 10 ? bal : 10);
        else amount = _bound(amountSeed >> 3, 1, bal / 4 + 1);
        _syncAttackerYield(asset);
        vm.prank(ATTACKER);
        try borrowable.supply(address(asset), amount, ATTACKER) {
            attackerMarketIn[address(asset)] += amount;
            _resetAttackerBaseline(asset);
            return true;
        } catch {
            return false;
        }
    }

    function _attackerWithdrawOne(uint256 assetSeed, uint256 fractionSeed) internal returns (bool) {
        MockERC20 asset = _asset(assetSeed);
        uint256 bal = borrowable.balanceOf(ATTACKER, lenderId(address(asset)));
        if (bal == 0) return false;
        uint256 shares;
        if (fractionSeed % 4 == 0) shares = 1;
        else if (fractionSeed % 4 == 1) shares = bal;
        else shares = bal * _bound(fractionSeed >> 2, 1, 1e18) / 1e18;
        if (shares == 0) shares = 1;
        _syncAttackerYield(asset);
        vm.prank(ATTACKER);
        try borrowable.withdraw(address(asset), shares, ATTACKER, ATTACKER) returns (uint256 assets) {
            attackerMarketOut[address(asset)] += assets;
            _resetAttackerBaseline(asset);
            return true;
        } catch {
            return false;
        }
    }

    function _attackerDonateMarketOne(uint256 assetSeed, uint256 amountSeed) internal returns (bool) {
        MockERC20 asset = _asset(assetSeed);
        uint256 bal = asset.balanceOf(ATTACKER);
        if (bal == 0) return false;
        uint256 cap = bal / 20 + 1;
        uint256 amount = _bound(amountSeed, 1, cap);
        vm.prank(ATTACKER);
        asset.transfer(address(borrowable), amount);
        donatedToMarket[address(asset)] += amount;
        return true;
    }

    function _attackerOpenOne(uint256 rangeSeed, uint256 liqSeed, bool inlineShadow) internal returns (bool) {
        if (_freeSlot() == type(uint256).max) return false;
        if (riskConfig.isPaused(address(adapter), ACTION_OPEN)) return false;
        uint256 r = rangeSeed % RANGES;
        uint128 l = uint128(_bound(liqSeed, 1e8, 1e13));
        bytes memory data = _mintData(r, l);
        (uint256 amount0, uint256 amount1) = _quoteDeposit(r, l);
        if (amount0 == 0 && amount1 == 0) return false;
        if (token0.balanceOf(ATTACKER) < amount0 || token1.balanceOf(ATTACKER) < amount1) return false;
        vm.startPrank(ATTACKER);
        if (amount0 > 0) token0.transfer(address(adapter), amount0);
        if (amount1 > 0) token1.transfer(address(adapter), amount1);
        (uint256 id,,,,,) = collateral.open(ATTACKER, ATTACKER, data);
        vm.stopPrank();
        _track(id, r);
        _absorbed();
        if (inlineShadow) {
            (uint256 g0, uint256 g1) = _feeGrowthOf(id);
            lastGrowth[id] = [g0, g1];
        }
        return true;
    }

    function _attackerIncreaseOne(uint256 idSeed, uint256 liqSeed) internal returns (bool) {
        uint256 id = _attackerPosition(idSeed);
        if (id == 0) return false;
        uint128 l = uint128(_bound(liqSeed, 1e8, 1e12));
        (uint256 amount0, uint256 amount1) = _quoteDeposit(rangeOf[id], l);
        if (amount0 == 0 && amount1 == 0) return false;
        if (token0.balanceOf(ATTACKER) < amount0 || token1.balanceOf(ATTACKER) < amount1) return false;
        vm.startPrank(ATTACKER);
        if (amount0 > 0) token0.transfer(address(adapter), amount0);
        if (amount1 > 0) token1.transfer(address(adapter), amount1);
        collateral.increaseLiquidity(ATTACKER, id, ATTACKER, "");
        vm.stopPrank();
        _absorbed();
        return true;
    }

    function _attackerRedeemOne(uint256 idSeed, uint256 fractionSeed, bool inlineShadow) internal returns (bool) {
        uint256 id = _attackerPosition(idSeed);
        if (id == 0) return false;
        uint256 bal = collateral.balanceOf(ATTACKER, id);
        bool all = fractionSeed % 3 == 0;
        uint256 units = all ? bal : bal * _bound(fractionSeed >> 2, 1, 1e18) / 1e18;
        if (units == 0) units = 1;
        uint256 before0 = token0.balanceOf(ATTACKER);
        uint256 before1 = token1.balanceOf(ATTACKER);
        vm.prank(ATTACKER);
        try collateral.redeem(ATTACKER, id, units, ATTACKER, "") returns (uint256 amount0, uint256 amount1) {
            if (units == bal) {
                uint256 got0 = token0.balanceOf(ATTACKER) - before0;
                uint256 got1 = token1.balanceOf(ATTACKER) - before1;
                uint256 paid0 = got0 > amount0 ? got0 - amount0 : 0;
                uint256 paid1 = got1 > amount1 ? got1 - amount1 : 0;
                _recordAttackerPayout(id, paid0, paid1, inlineShadow);
            }
            return true;
        } catch {
            return false;
        }
    }

    function _attackerCollectOne(uint256 idSeed, bool inlineShadow) internal returns (bool) {
        if (ids.length == 0) return false;
        uint256 id = _attackerPosition(idSeed);
        if (id == 0) id = ids[idSeed % ids.length];
        vm.prank(ATTACKER);
        try adapter.collectFees(ATTACKER, id, ATTACKER) returns (uint256 paid0, uint256 paid1) {
            _recordAttackerPayout(id, paid0, paid1, inlineShadow);
            return paid0 + paid1 > 0;
        } catch {
            return false;
        }
    }

    function _attackerBorrowOne(uint256 idSeed, uint256 paramSeed) internal returns (bool) {
        uint256 id = _attackerPosition(idSeed);
        if (id == 0) return false;
        MockERC20 asset = _asset(paramSeed);
        uint256 bps = _bound(paramSeed >> 4, 1, 8000);
        uint256 usd = collateral.health(ATTACKER, id).collateralUsdWad * bps / 10_000;
        uint256 amount = paramSeed % 7 == 0 ? 1 : _usdToAsset(asset, usd);
        if (amount == 0) return false;
        vm.prank(ATTACKER);
        try collateral.borrow(ATTACKER, id, address(asset), amount, ATTACKER) {
            return true;
        } catch {
            return false;
        }
    }

    function _attackerRepayOne(uint256 idSeed, uint256 paramSeed) internal returns (bool) {
        uint256 id = _attackerDebtorPosition(idSeed);
        if (id == 0) return false;
        MockERC20 asset = _debtAsset(ATTACKER, id, paramSeed);
        uint256 debt = borrowable.debtOf(ATTACKER, id, address(asset));
        uint256 bal = asset.balanceOf(ATTACKER);
        if (debt == 0 || bal == 0) return false;
        uint256 amount;
        if (paramSeed % 4 == 0) amount = 1;
        else if (paramSeed % 4 == 1) amount = debt;
        else amount = debt * _bound(paramSeed >> 4, 1, 1e18) / 1e18;
        if (amount == 0) amount = 1;
        if (amount > bal) amount = bal;
        vm.prank(ATTACKER);
        try borrowable.repay(ATTACKER, id, address(asset), amount) {
            return true;
        } catch {
            return false;
        }
    }

    function _attackerFlashOne(uint256 idSeed, uint256 paramSeed) internal returns (bool) {
        uint256 id = _attackerPosition(idSeed);
        if (id == 0) return false;
        MockERC20 asset = _asset(paramSeed);
        uint256 cap = asset == usdc ? 50_000e6 : 25e18;
        uint256 amount = _bound(paramSeed >> 4, 1, cap);
        try collateral.lock(
            abi.encode(LOCK_ATTACKER_FLASH, abi.encode(ATTACKER, id, address(asset), amount, ATTACKER))
        ) {
            return true;
        } catch {
            return false;
        }
    }

    function _attackerSelfLiqOne(uint256 idSeed, uint256 paramSeed) internal returns (bool) {
        uint256 id = _attackerDebtorPosition(idSeed);
        if (id == 0 || collateral.health(ATTACKER, id).minSurplusUsdWad >= 0) return false;
        MockERC20 asset = _debtAsset(ATTACKER, id, paramSeed);
        uint256 debt = borrowable.debtOf(ATTACKER, id, address(asset));
        if (debt == 0) return false;
        uint256 amount = _bound(paramSeed >> 4, 1, debt * 2);
        try collateral.lock(
            abi.encode(LOCK_ATTACKER_SELF_LIQ, abi.encode(ATTACKER, id, address(asset), amount, ATTACKER))
        ) {
            return true;
        } catch {
            return false;
        }
    }

    function _attackerResolveBadDebtOne(uint256 seed) internal returns (bool) {
        if (ids.length == 0) return false;
        uint256 id = ids[seed % ids.length];
        bool ok;
        // Try resolving bad debt on ATTACKER itself (must revert unless collateral is zero) and on another debtor
        try collateral.resolveBadDebt(ATTACKER, id) {
            ok = true;
        } catch {}
        address other = _debtorOf(id, seed >> 8);
        if (other != address(0) && other != ATTACKER) {
            uint256 units = collateral.balanceOf(other, id);
            try collateral.resolveBadDebt(other, id) {
                ok = true;
                if (units > 0) seizes.push(Seize(other, factory.protocolReserves(), id, units, units));
            } catch {}
        }
        return ok;
    }

    function _attackerSwapStep(uint256 s) internal returns (bool) {
        bool zeroForOne = (s & 1) == 0;
        MockERC20 tokenIn = zeroForOne ? token0 : token1;
        uint256 bal = tokenIn.balanceOf(ATTACKER);
        if (bal == 0) return false;
        uint256 cap = tokenIn == weth ? 50e18 : 100_000e6;
        if (cap > bal) cap = bal;
        uint256 amountIn = _bound(s >> 1, 1, cap);
        if (!_attackerPoolSwap(zeroForOne, amountIn)) return false;
        _syncShadowNow();
        return true;
    }

    function _attackerPosition(uint256 seed) internal view returns (uint256) {
        uint256 n = ids.length;
        for (uint256 i; i < n; ++i) {
            uint256 id = ids[(seed % n + i) % n];
            if (collateral.balanceOf(ATTACKER, id) > 0) return id;
        }
        return 0;
    }

    function _attackerDebtorPosition(uint256 seed) internal view returns (uint256) {
        uint256 n = ids.length;
        for (uint256 i; i < n; ++i) {
            uint256 id = ids[(seed % n + i) % n];
            if (borrowable.hasDebt(ATTACKER, id)) return id;
        }
        return 0;
    }

    function _attackerPositionsValue() internal view virtual returns (uint256 v0, uint256 v1) {
        for (uint256 i; i < allIds.length; ++i) {
            uint256 id = allIds[i];
            if (retired[id]) continue;
            uint256 units = collateral.balanceOf(ATTACKER, id);
            if (units > 0) {
                (uint256 a0, uint256 a1) = _amountsOf(id, units);
                v0 += a0;
                v1 += a1;
            }
        }
    }

    uint256 internal constant NET_SCALE = 1e18;

    /// @dev Per-asset attacker net worth scaled by `1e18`, valuing lender shares and borrow shares directly from
    ///      share/asset ratios without integer-wei floor/ceil skew
    function _attackerNet() internal view returns (int256[3] memory net) {
        MockERC20[3] memory assets = [token0, token1, dai];
        for (uint256 k; k < 3; ++k) {
            address a = address(assets[k]);
            uint256 wallet = assets[k].balanceOf(ATTACKER);
            uint256 sh = borrowable.balanceOf(ATTACKER, lenderId(a));
            Market memory m = borrowable.getMarket(a);
            uint256 totalSh = borrowable.totalSupply(lenderId(a));
            uint256 lenderClaimScaled = sh == 0
                ? 0
                : FullMath.mulDiv(
                    sh,
                    (uint256(m.totalSupplyAssets) + MarketLogic.VIRTUAL_ASSETS) * NET_SCALE,
                    totalSh + MarketLogic.VIRTUAL_SHARES
                );
            net[k] = int256(wallet * NET_SCALE + lenderClaimScaled);
        }
        (uint256 v0, uint256 v1) = _attackerPositionsValue();
        net[0] += int256(v0 * NET_SCALE);
        net[1] += int256(v1 * NET_SCALE);
        for (uint256 i; i < allIds.length; ++i) {
            uint256 id = allIds[i];
            if (retired[id]) continue;
            (uint256 f0, uint256 f1) = adapter.feesOwed(ATTACKER, id);
            net[0] += int256(f0 * NET_SCALE);
            net[1] += int256(f1 * NET_SCALE);
            for (uint256 k; k < 3; ++k) {
                address a = address(assets[k]);
                uint256 dSh = borrowable.borrowSharesOf(ATTACKER, id, a);
                if (dSh == 0) continue;
                Market memory m = borrowable.getMarket(a);
                uint256 debtScaled = FullMath.mulDiv(
                    dSh,
                    (uint256(m.totalBorrowAssets) + MarketLogic.VIRTUAL_ASSETS) * NET_SCALE,
                    uint256(m.totalBorrowShares) + MarketLogic.VIRTUAL_SHARES
                );
                net[k] -= int256(debtScaled);
            }
        }
    }

    /// @dev Exact oracle USD net worth (`net[k]` is `×1e18` per token wei, multiplied by `price * 10**(18 - decimals)`)
    function _attackerUsdScaled() internal view returns (int256 total) {
        int256[3] memory net = _attackerNet();
        MockERC20[3] memory assets = [token0, token1, dai];
        for (uint256 k; k < 3; ++k) {
            (uint256 price, uint8 decimals) = oracle.priceWithDecimals(address(assets[k]));
            total += net[k] * int256(price * 10 ** (18 - decimals));
        }
    }

    function _accrueAllMarkets() internal {
        MockERC20[3] memory assets = [usdc, weth, dai];
        for (uint256 k; k < 3; ++k) {
            borrowable.accrueInterest(address(assets[k]));
            _syncAttackerYield(assets[k]);
        }
    }

    function _syncAttackerOnAccrual() internal {
        MockERC20[3] memory assets = [usdc, weth, dai];
        for (uint256 k; k < 3; ++k) {
            if (borrowable.getMarket(address(assets[k])).lastAccrual < block.timestamp) {
                _syncAttackerYield(assets[k]);
            }
        }
    }

    function _syncAttackerOnDrop() internal {
        MockERC20[3] memory assets = [usdc, weth, dai];
        for (uint256 k; k < 3; ++k) {
            address a = address(assets[k]);
            (uint256 nowA, uint256 nowS) = _expectedSupplyAndShares(assets[k]);
            if (_mulGt(_lastSupplyA[a], nowS, nowA, _lastSupplyS[a])) {
                _lastSupplyA[a] = nowA;
                _lastSupplyS[a] = nowS;
            }
        }
    }

    function _syncAttackerYield(MockERC20 asset) internal {
        address a = address(asset);
        uint256 sh = borrowable.balanceOf(ATTACKER, lenderId(a));
        (uint256 nowA, uint256 nowS) = _expectedSupplyAndShares(asset);
        if (sh > 0 && _lastSupplyS[a] > 0) {
            attackerYieldBound[a] += _ceilSharePriceDelta(sh, _lastSupplyA[a], _lastSupplyS[a], nowA, nowS);
        }
        _lastSupplyA[a] = nowA;
        _lastSupplyS[a] = nowS;
    }

    function _resetAttackerBaseline(MockERC20 asset) internal {
        address a = address(asset);
        (_lastSupplyA[a], _lastSupplyS[a]) = _expectedSupplyAndShares(asset);
    }

    function _pendingAttackerYield(MockERC20 asset, uint256 sh) internal view returns (uint256) {
        address a = address(asset);
        if (sh == 0 || _lastSupplyS[a] == 0) return 0;
        (uint256 nowA, uint256 nowS) = _expectedSupplyAndShares(asset);
        return _ceilSharePriceDelta(sh, _lastSupplyA[a], _lastSupplyS[a], nowA, nowS);
    }

    function _expectedSupplyAndShares(MockERC20 asset) internal view returns (uint256 a, uint256 s) {
        Market memory m = borrowable.getMarket(address(asset));
        uint256 totalShares = borrowable.totalSupply(lenderId(address(asset)));
        (, uint256 reserveAssets) = m.accrue();
        totalShares += m.reserveShares(reserveAssets, totalShares);
        return (uint256(m.totalSupplyAssets) + MarketLogic.VIRTUAL_ASSETS, totalShares + MarketLogic.VIRTUAL_SHARES);
    }

    /// @dev Exact `ceil(sh * (a1/s1 - a0/s0))` when `a1/s1 > a0/s0`, else 0 (512-bit exact, never overflows)
    function _ceilSharePriceDelta(uint256 sh, uint256 a0, uint256 s0, uint256 a1, uint256 s1)
        internal
        pure
        returns (uint256)
    {
        if (sh == 0 || !_mulGt(a1, s0, a0, s1)) return 0;
        uint256 q1 = FullMath.mulDiv(sh, a1, s1);
        uint256 r1 = mulmod(sh, a1, s1);
        uint256 q0 = FullMath.mulDiv(sh, a0, s0);
        uint256 r0 = mulmod(sh, a0, s0);
        uint256 diff = q1 - q0;
        if (_mulGt(r1, s0, r0, s1)) diff += 1;
        return diff;
    }

    function _mulGt(uint256 a, uint256 b, uint256 c, uint256 d) private pure returns (bool) {
        (uint256 hi1, uint256 lo1) = _mul512(a, b);
        (uint256 hi2, uint256 lo2) = _mul512(c, d);
        return hi1 > hi2 || (hi1 == hi2 && lo1 > lo2);
    }

    function _mul512(uint256 a, uint256 b) private pure returns (uint256 hi, uint256 lo) {
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            lo := mul(a, b)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
    }

    function _recordAttackerPayout(uint256 id, uint256 paid0, uint256 paid1, bool inlineShadow) internal {
        if (!inlineShadow) {
            payouts.push(Payout(ATTACKER, id, paid0, paid1));
            return;
        }
        uint256[2] storage fair = fairQ[ATTACKER][id];
        if (paid0 > fair[0] / Q128 + FEE_TOLERANCE || paid1 > fair[1] / Q128 + FEE_TOLERANCE) {
            _fail("a payout exceeded its pro-rata share");
        }
        fair[0] = 0;
        fair[1] = 0;
        delete openQ[ATTACKER][id];
    }

    /// @dev The attacker's bursts outside `action`: the steps since the last sync checkpointed before any swap's
    ///      fees, as each swap is followed by a sync
    function _syncShadowNow() internal {
        _moveSeized();
        _closeCheckpointed();
        delete seizes;
        for (uint256 i; i < allIds.length; ++i) {
            uint256 id = allIds[i];
            if (retired[id]) continue;
            (uint256 g0, uint256 g1) = _feeGrowthOf(id);
            if (collateral.totalSupply(id) > 0) {
                uint256 d0;
                uint256 d1;
                unchecked {
                    d0 = g0 - lastGrowth[id][0];
                    d1 = g1 - lastGrowth[id][1];
                }
                if (d0 != 0 || d1 != 0) {
                    for (uint256 a; a < holders.length; ++a) {
                        uint256 u = collateral.balanceOf(holders[a], id);
                        if (u == 0) continue;
                        fairQ[holders[a]][id][0] += u * d0;
                        fairQ[holders[a]][id][1] += u * d1;
                        openQ[holders[a]][id][0] += u * d0;
                        openQ[holders[a]][id][1] += u * d1;
                    }
                }
            }
            lastGrowth[id] = [g0, g1];
        }
    }

    function _checkAllFeesAgainstShadow() internal {
        for (uint256 i; i < allIds.length; ++i) {
            if (retired[allIds[i]]) continue;
            for (uint256 a; a < holders.length; ++a) {
                (uint256 owed0, uint256 owed1) = adapter.feesOwed(holders[a], allIds[i]);
                _checkFair(owed0, fairQ[holders[a]][allIds[i]][0] / Q128);
                _checkFair(owed1, fairQ[holders[a]][allIds[i]][1] / Q128);
            }
        }
    }

    /// @notice Fees the adapter holds or has accruing that nobody is owed stay rounding dust, a wei per call at most
    ///         (2,500 calls leave about 20 wei)
    function checkNoStuckFees() public view {
        (uint256 dust0, uint256 dust1) = feeDust();
        require(dust0 <= totalCalls && dust1 <= totalCalls, "fees nobody is owed pile up");
    }

    /// @notice Every position's units: the holders' sum, the core's supply and the adapter's liquidity agree
    function checkUnits() public view {
        for (uint256 i; i < allIds.length; ++i) {
            uint256 sum;
            for (uint256 j; j < holders.length; ++j) {
                sum += collateral.balanceOf(holders[j], allIds[i]);
            }
            require(sum == collateral.totalSupply(allIds[i]), "holders' units != totalSupply");
            require(sum == adapter.units(allIds[i]), "totalSupply != adapter units");
        }
    }

    /// @notice A market holds its book cash, its debts and lender shares add up, and it never lends more than it has
    function checkMarket(MockERC20 asset) public view {
        Market memory m = borrowable.getMarket(address(asset));
        require(m.totalBorrowAssets <= m.totalSupplyAssets, "borrowed more than supplied");
        uint256 held = asset.balanceOf(address(borrowable));
        uint256 cash = m.totalSupplyAssets - m.totalBorrowAssets;
        require(held >= cash, "market holds less than its cash");
        // Repayments round up by a wei at most, and nobody donates here
        require(
            held <= cash + totalCalls + donatedToMarket[address(asset)], "market holds tokens its books don't count"
        );
        uint256 debtShares;
        uint256 debt;
        for (uint256 i; i < allIds.length; ++i) {
            for (uint256 j; j < holders.length; ++j) {
                debtShares += borrowable.borrowSharesOf(holders[j], allIds[i], address(asset));
                debt += borrowable.debtOf(holders[j], allIds[i], address(asset));
            }
        }
        require(debtShares == m.totalBorrowShares, "debt shares != totalBorrowShares");
        (, uint256 borrowedNow,,,,) = borrowable.marketState(address(asset));
        // A repayment books what its shares were worth, rounded down: under a wei per call stays owed by the
        // virtual shares
        require(debt + totalCalls >= borrowedNow, "debts sum under the market's borrows");
        uint256 supplyId = lenderId(address(asset));
        uint256 shares = m.pendingReserveShares;
        uint256 claims = borrowable.convertToAssets(address(asset), m.pendingReserveShares);
        for (uint256 j; j < holders.length; ++j) {
            uint256 balance = borrowable.balanceOf(holders[j], supplyId);
            shares += balance;
            claims += borrowable.convertToAssets(address(asset), balance);
        }
        require(shares == borrowable.totalSupply(supplyId), "lender shares != totalSupply");
        (uint256 suppliedNow,,,,,) = borrowable.marketState(address(asset));
        require(claims <= suppliedNow, "lenders' claims exceed the market's supply");
    }

    /// @notice The health check against a valuation done here from the range, the units and the oracle alone: a
    ///         position the core calls healthy holds at least 93% of its debt's value now. (A healthy position passes
    ///         the corner where both prices rise by their σ with the 5% penalty, and its value there is at most 1.15×
    ///         its value now, so value ≥ debt · 1.02 · 1.05 / 1.15.)
    function checkHealthAgainstReference() public view {
        uint160 sqrtPriceX96 = _oracleSqrtPriceX96();
        for (uint256 i; i < allIds.length; ++i) {
            for (uint256 j; j < holders.length; ++j) {
                _checkHealthOf(holders[j], allIds[i], sqrtPriceX96);
            }
        }
    }

    // Split from checkHealthAgainstReference: in one function, solc's via-IR runs out of stack
    function _checkHealthOf(address h, uint256 id, uint160 sqrtPriceX96) internal view virtual {
        if (!borrowable.hasDebt(h, id) || collateral.health(h, id).minSurplusUsdWad < 0) return;
        uint256 r = rangeOf[id];
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(ranges[r][0]),
            TickMath.getSqrtPriceAtTick(ranges[r][1]),
            uint128(collateral.balanceOf(h, id))
        );
        uint256 value = _usd(token0, amount0) + _usd(token1, amount1);
        uint256 debt = _usd(token0, borrowable.debtOf(h, id, address(token0)))
            + _usd(token1, borrowable.debtOf(h, id, address(token1)))
            + _usd(dai, borrowable.debtOf(h, id, address(dai)));
        require(value * 100 + 1e12 >= debt * 93, "a position the core calls healthy is under water");
    }

    function _usd(MockERC20 token, uint256 amount) internal view returns (uint256) {
        (uint256 price, uint8 decimals) = oracle.priceWithDecimals(address(token));
        return amount * price / 10 ** decimals;
    }

    /// @notice End-of-sequence exit liveness: repays every debt, redeems every unit, collects every fee, sweeps
    ///         reserves and withdraws every lender share. Nothing may revert, and only bounded dust may remain:
    ///           - Borrowable book supply: at most the 1e6 virtual offset's share (`virtualWorth`) + 1 wei floor per
    ///             lender withdrawal (`holders.length`)
    ///           - Borrowable balance: book supply + at most 1 wei per repayment round-up (`totalCalls`) + explicit
    ///             direct donations (`donatedToMarket`)
    ///           - Adapter: checked by `_checkUnwoundAdapter()` (zero on v3 + stray; bounded fee floor dust on v4)
    function unwindAll() external {
        require(violations == 0, lastViolation);
        _freshen();
        MockERC20[4] memory markets = [usdc, weth, dai, junk];

        // 1. Repay every remaining debt across all positions, holders and markets
        for (uint256 i; i < allIds.length; ++i) {
            uint256 id = allIds[i];
            for (uint256 j; j < holders.length; ++j) {
                address h = holders[j];
                for (uint256 k; k < markets.length; ++k) {
                    _unwindRepay(h, id, markets[k]);
                }
            }
        }
        for (uint256 k; k < markets.length; ++k) {
            Market memory m = borrowable.getMarket(address(markets[k]));
            require(m.totalBorrowShares == 0 && m.totalBorrowAssets == 0, "unwindAll: borrow remained");
        }

        // 2. Redeem every unit across all positions and holders
        for (uint256 i; i < allIds.length; ++i) {
            uint256 id = allIds[i];
            for (uint256 j; j < holders.length; ++j) {
                address h = holders[j];
                uint256 bal = collateral.balanceOf(h, id);
                if (bal == 0) continue;
                vm.prank(h);
                collateral.redeem(h, id, bal, h, "");
            }
            require(collateral.totalSupply(id) == 0, "unwindAll: collateral supply remained");
            require(adapter.units(id) == 0, "unwindAll: adapter units remained");
        }

        // 3. Collect every remaining fee across all positions and holders
        for (uint256 i; i < allIds.length; ++i) {
            uint256 id = allIds[i];
            for (uint256 j; j < holders.length; ++j) {
                address h = holders[j];
                vm.prank(h);
                adapter.collectFees(h, id, h);
                (uint256 f0, uint256 f1) = adapter.feesOwed(h, id);
                require(f0 == 0 && f1 == 0, "unwindAll: fees remained owed");
            }
        }

        // 4. Sweep reserves and withdraw every withdrawable lender share
        for (uint256 k; k < markets.length; ++k) {
            _unwindMarket(markets[k]);
        }

        // 5. Adapter holds only bounded rounding dust (+ explicit stray transfers)
        _checkUnwoundAdapter();
    }

    function _unwindRepay(address h, uint256 id, MockERC20 asset) private {
        uint256 debt = borrowable.debtOf(h, id, address(asset));
        if (debt == 0) return;
        uint256 fund = debt + 1;
        asset.mint(address(this), fund);
        borrowable.repay(h, id, address(asset), type(uint256).max);
        uint256 left = asset.balanceOf(address(this));
        if (left > 0) asset.burn(address(this), left);
        require(borrowable.debtOf(h, id, address(asset)) == 0, "unwindAll: debt remained after full repay");
    }

    function _unwindMarket(MockERC20 asset) private {
        borrowable.mintReserves(address(asset));
        uint256 virtualWorth = borrowable.convertToAssets(address(asset), 1e6) + 1;
        uint256 sid = lenderId(address(asset));
        // A large lender's floor-rounded withdrawal can bump an earlier sub-wei holder's shares from 0 to 1 wei
        for (uint256 pass; pass < 2; ++pass) {
            for (uint256 j; j < holders.length; ++j) {
                address h = holders[j];
                uint256 shares = borrowable.balanceOf(h, sid);
                if (shares == 0 || borrowable.convertToAssets(address(asset), shares) == 0) continue;
                vm.prank(h);
                borrowable.withdraw(address(asset), shares, h, h);
            }
        }
        Market memory m = borrowable.getMarket(address(asset));
        require(m.pendingReserveShares == 0, "unwindAll: pending reserves remained");
        for (uint256 j; j < holders.length; ++j) {
            uint256 rem = borrowable.balanceOf(holders[j], sid);
            require(
                rem == 0 || borrowable.convertToAssets(address(asset), rem) == 0,
                "unwindAll: withdrawable lender shares remained"
            );
        }
        require(m.totalSupplyAssets <= virtualWorth + holders.length, "unwindAll: excess supply left in borrowable");
        uint256 held = asset.balanceOf(address(borrowable));
        require(
            held <= m.totalSupplyAssets + totalCalls + donatedToMarket[address(asset)],
            "unwindAll: excess tokens stuck in borrowable"
        );
    }

    /// @dev The fees `id`'s holders are owed, summed
    function _owed(uint256 id) internal view returns (uint256 owed0, uint256 owed1) {
        for (uint256 j; j < holders.length; ++j) {
            (uint256 fee0, uint256 fee1) = adapter.feesOwed(holders[j], id);
            owed0 += fee0;
            owed1 += fee1;
        }
    }
}
