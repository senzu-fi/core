// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ISenzuBorrowable} from "../interfaces/ISenzuBorrowable.sol";
import {ISenzuCollateral} from "../interfaces/ISenzuCollateral.sol";
import {SenzuCore} from "./SenzuCore.sol";

import {BorrowLogic} from "../libraries/BorrowLogic.sol";
import {DebtLanes} from "../libraries/DebtLanes.sol";
import {MarketLogic} from "../libraries/MarketLogic.sol";
import {
    ACTION_BORROW,
    ACTION_SUPPLY,
    BorrowableState,
    MAX_MARKETS,
    Market,
    Rounding,
    lenderId
} from "../libraries/Types.sol";
import {DebtLane} from "../types/DebtLane.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {ISenzuFactory} from "../interfaces/ISenzuFactory.sol";
import {ISenzuOracle} from "../interfaces/ISenzuOracle.sol";
import {ISenzuRiskConfig} from "../interfaces/ISenzuRiskConfig.sol";
import {IERC6909TokenSupply} from "@openzeppelin/contracts/interfaces/IERC6909.sol";
import {ERC6909TokenSupply} from "@openzeppelin/contracts/token/ERC6909/extensions/ERC6909TokenSupply.sol";

/**
 *  @title  SenzuBorrowable
 *  @author Senzu
 *  @notice The lenders' side of one Senzu deployment: one lending market per asset (lender share id =
 *          uint160(asset)) and the debt of the paired SenzuCollateral's positions. Only the paired collateral can
 *          borrow, repay for a liquidator or write off.
 */
contract SenzuBorrowable is ISenzuBorrowable, SenzuCore {
    using MarketLogic for Market;
    using SafeCastLib for uint256;
    using SafeTransferLib for address;

    /*  ================================================
                             STATE
        ================================================  */

    uint256 internal constant MAX_RESERVE_FACTOR = 0.5e18;

    BorrowableState internal $;

    /*  ================================================
                          CONSTRUCTOR
        ================================================  */

    constructor() SenzuCore("Senzu Borrowable") {}

    /*  ================================================
                           MODIFIERS
        ================================================  */

    modifier onlyAdmin() {
        if (msg.sender != ISenzuFactory(factory).admin()) revert SenzuCore__NotAdmin();
        _;
    }

    modifier onlyCollateral() {
        if (msg.sender != address(collateral())) revert SenzuBorrowable__NotCollateral();
        _;
    }

    /*  ================================================
                            DEPOSITS
        ================================================  */

    /// @inheritdoc ISenzuBorrowable
    function supply(address asset, uint256 assets, address to)
        external
        override
        nonReentrant
        whenNotPaused(ACTION_SUPPLY)
        returns (uint256 shares)
    {
        if (assets == 0) revert SenzuBorrowable__ZeroAmount();

        Market storage market = _accrue(asset);

        uint256 id = lenderId(asset);
        shares = MarketLogic.toShares(assets, market.totalSupplyAssets, totalSupply(id), Rounding.Down);
        if (shares == 0) revert SenzuBorrowable__ZeroAmount();

        _pullExact(asset, msg.sender, assets);

        market.totalSupplyAssets += assets.toUint128();
        _mint(to, id, shares);

        emit Supply(to, asset, assets, shares);
    }

    /// @inheritdoc ISenzuBorrowable
    function withdraw(address asset, uint256 shares, address receiver, address owner)
        external
        override
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) revert SenzuBorrowable__ZeroAmount();

        uint256 id = lenderId(asset);
        if (msg.sender != owner && !isOperator(owner, msg.sender)) _spendAllowance(owner, msg.sender, id, shares);

        Market storage market = _accrue(asset);
        assets = MarketLogic.toAssets(shares, market.totalSupplyAssets, totalSupply(id), Rounding.Down);
        if (assets == 0) revert SenzuBorrowable__ZeroAmount();
        if (assets > market.totalSupplyAssets - market.totalBorrowAssets) {
            revert SenzuBorrowable__InsufficientCash(asset);
        }

        _burn(owner, id, shares);

        market.totalSupplyAssets -= assets.toUint128();

        asset.safeTransfer(receiver, assets);

        emit Withdraw(receiver, owner, asset, assets, shares);
    }

    /*  ================================================
                              DEBT
        ================================================  */

    /// @inheritdoc ISenzuBorrowable
    function accrueInterest(address asset) external override nonReentrant {
        _accrue(asset);
    }

    /// @inheritdoc ISenzuBorrowable
    function mintReserves(address asset) external override nonReentrant returns (uint256 shares) {
        Market storage market = $.markets[asset];
        if (!market.exists) return 0;
        shares = market.pendingReserveShares;
        if (shares == 0) return 0;
        market.pendingReserveShares = 0;
        _mintReserves(lenderId(asset), shares);
    }

    /// @inheritdoc ISenzuBorrowable
    function repay(address account, uint256 id, address asset, uint256 assets)
        external
        override
        nonReentrant
        returns (uint256 repaid)
    {
        (, repaid) = _bookRepay(account, id, asset, assets);
        _pullExact(asset, msg.sender, repaid);
    }

    /// @inheritdoc ISenzuBorrowable
    function borrow(address account, uint256 id, address asset, uint256 assets, address to)
        external
        override
        nonReentrant
        onlyCollateral
        returns (uint256 shares)
    {
        (bool paused, uint256 feeWad) = ISenzuRiskConfig(riskConfig).borrowTerms(adapter);
        if (paused) revert SenzuCore__Paused(ACTION_BORROW);
        if (assets == 0) revert SenzuBorrowable__ZeroAmount();
        Market storage market = _accrue(asset);

        uint256 fee = BorrowLogic.borrowFee(assets, feeWad);
        uint256 lender = lenderId(asset);
        uint256 feeShares;
        (shares, feeShares) = BorrowLogic.addDebt($, market, asset, account, id, assets, fee, totalSupply(lender));
        if (feeShares > 0) _bookReserves(market, lender, feeShares);

        asset.safeTransfer(to, assets);

        emit Borrow(account, id, asset, to, assets, shares, fee, feeShares);
    }

    /*  ================================================
                     LOCK AND LIQUIDATIONS
        ================================================  */

    /// @inheritdoc ISenzuBorrowable
    function repayFor(address account, uint256 id, address asset, uint256 assets, uint256 fee)
        external
        override
        nonReentrant
        onlyCollateral
        returns (uint256 repaid)
    {
        Market storage market;
        (market, repaid) = _bookRepay(account, id, asset, assets);
        if (fee > 0) {
            uint256 lender = lenderId(asset);
            uint256 feeShares = MarketLogic.toShares(fee, market.totalSupplyAssets, totalSupply(lender), Rounding.Down);
            market.totalSupplyAssets += fee.toUint128();
            if (feeShares > 0) _bookReserves(market, lender, feeShares);
        }
    }

    /// @inheritdoc ISenzuBorrowable
    function collectRepayment(address payer, address asset, uint256 assets)
        external
        override
        nonReentrant
        onlyCollateral
    {
        _pullExact(asset, payer, assets);
    }

    /// @inheritdoc ISenzuBorrowable
    function writeOff(address account, uint256 id) external override nonReentrant onlyCollateral {
        (DebtLane l0, DebtLane l1) = DebtLanes.parse($.debts[account][id]);
        if (l0.isEmpty()) revert SenzuBorrowable__NoDebt();
        // Lane 1 first: clearing lane 0 moves lane 1 into its place
        if (!l1.isEmpty()) _writeOff($.marketList[l1.marketIndex()], account, id);
        _writeOff($.marketList[l0.marketIndex()], account, id);
    }

    /*  ================================================
                             ADMIN
        ================================================  */

    /// @inheritdoc ISenzuBorrowable
    function createMarket(address asset, uint64 reserveFactorWad) external override onlyAdmin {
        if ($.markets[asset].exists) revert SenzuBorrowable__MarketAlreadyExists(asset);
        if ($.marketCount == MAX_MARKETS) revert SenzuBorrowable__TooManyMarkets();
        if (reserveFactorWad > MAX_RESERVE_FACTOR) revert SenzuBorrowable__InvalidReserveFactor();

        (address aggregator,,) = ISenzuOracle(oracle).feedOf(asset);
        if (aggregator == address(0)) revert SenzuBorrowable__NoOracleFeed(asset);

        uint8 index = $.marketCount.toUint8();
        $.markets[asset] = Market({
            exists: true,
            index: index,
            totalSupplyAssets: 0,
            pendingReserveShares: 0,
            totalBorrowAssets: 0,
            totalBorrowShares: 0,
            lastAccrual: block.timestamp.toUint64(),
            reserveFactorWad: reserveFactorWad,
            interestRemainder: 0,
            rateAtTarget: MarketLogic.INITIAL_RATE_AT_TARGET.toUint64()
        });
        $.marketList[index] = asset;
        ++$.marketCount;

        emit MarketCreated(asset, index, reserveFactorWad);
    }

    /// @inheritdoc ISenzuBorrowable
    function setReserveFactor(address asset, uint64 reserveFactorWad) external override nonReentrant onlyAdmin {
        if (reserveFactorWad > MAX_RESERVE_FACTOR) revert SenzuBorrowable__InvalidReserveFactor();
        Market storage market = _accrue(asset);
        market.reserveFactorWad = reserveFactorWad;
        emit MarketReserveFactorSet(asset, reserveFactorWad);
    }

    /*  ================================================
                             VIEWS
        ================================================  */

    /// @inheritdoc IERC6909TokenSupply
    /// @dev A lender id's supply counts the protocol's shares not minted yet (`Market.pendingReserveShares`): every
    ///      share price reads this, never the minted supply alone
    function totalSupply(uint256 id) public view override(ERC6909TokenSupply, IERC6909TokenSupply) returns (uint256) {
        if (id > type(uint160).max) return 0;
        return super.totalSupply(id) + $.markets[address(id.toUint160())].pendingReserveShares;
    }

    /// @inheritdoc ISenzuBorrowable
    function collateral() public view override returns (ISenzuCollateral) {
        return ISenzuCollateral(_counterpart);
    }

    /// @inheritdoc ISenzuBorrowable
    function getMarket(address asset) external view override returns (Market memory) {
        return $.markets[asset];
    }

    /// @inheritdoc ISenzuBorrowable
    function marketAt(uint256 index) external view override returns (address) {
        if (index >= $.marketCount) revert SenzuBorrowable__IndexOutOfBounds(index);
        return $.marketList[index];
    }

    /// @inheritdoc ISenzuBorrowable
    function marketsLength() external view override returns (uint256) {
        return $.marketCount;
    }

    /// @inheritdoc ISenzuBorrowable
    function convertToAssets(address asset, uint256 shares) external view override returns (uint256) {
        (Market memory market, uint256 totalShares) = _expectedMarket(asset);
        return MarketLogic.toAssets(shares, market.totalSupplyAssets, totalShares, Rounding.Down);
    }

    /// @inheritdoc ISenzuBorrowable
    function convertToShares(address asset, uint256 assets) external view override returns (uint256) {
        (Market memory market, uint256 totalShares) = _expectedMarket(asset);
        return MarketLogic.toShares(assets, market.totalSupplyAssets, totalShares, Rounding.Down);
    }

    /// @inheritdoc ISenzuBorrowable
    function maxWithdraw(address asset, address owner) external view override returns (uint256) {
        (Market memory market, uint256 totalShares) = _expectedMarket(asset);
        uint256 assets = MarketLogic.toAssets(
            balanceOf(owner, lenderId(asset)), market.totalSupplyAssets, totalShares, Rounding.Down
        );
        uint256 available = market.cash();
        return assets < available ? assets : available;
    }

    /// @inheritdoc ISenzuBorrowable
    function marketState(address asset)
        external
        view
        override
        returns (
            uint256 supplyAssets,
            uint256 borrowAssets,
            uint256 utilizationWad,
            uint256 borrowRateWad,
            uint256 supplyRateWad,
            uint256 rateAtTargetWad
        )
    {
        (Market memory market,) = _expectedMarket(asset);
        supplyAssets = market.totalSupplyAssets;
        borrowAssets = market.totalBorrowAssets;
        utilizationWad = market.utilization();
        borrowRateWad = market.borrowRate();
        supplyRateWad = market.supplyRate(borrowRateWad);
        rateAtTargetWad = market.rateAtTarget;
    }

    /// @inheritdoc ISenzuBorrowable
    function debts(address account, uint256 id)
        external
        view
        override
        returns (address asset0, uint256 amount0, address asset1, uint256 amount1)
    {
        (DebtLane l0, DebtLane l1) = DebtLanes.parse($.debts[account][id]);
        if (l0.isEmpty()) return (address(0), 0, address(0), 0);

        asset0 = $.marketList[l0.marketIndex()];
        amount0 = _debtAssets(asset0, l0.shares());

        if (!l1.isEmpty()) {
            asset1 = $.marketList[l1.marketIndex()];
            amount1 = _debtAssets(asset1, l1.shares());
        }
    }

    /// @inheritdoc ISenzuBorrowable
    function debtOf(address account, uint256 id, address asset) external view override returns (uint256) {
        Market storage market = $.markets[asset];
        if (!market.exists) return 0;

        return _debtAssets(asset, BorrowLogic.sharesOf($, market, account, id));
    }

    /// @inheritdoc ISenzuBorrowable
    function borrowSharesOf(address account, uint256 id, address asset) external view override returns (uint256) {
        Market storage market = $.markets[asset];
        if (!market.exists) return 0;

        return BorrowLogic.sharesOf($, market, account, id);
    }

    /// @inheritdoc ISenzuBorrowable
    function hasDebt(address account, uint256 id) external view override returns (bool) {
        return DebtLanes.hasDebt($.debts[account][id]);
    }

    /*  ================================================
                            INTERNAL
        ================================================  */

    /**
     *  @dev `MarketLogic.accrue` takes a `Market memory` because the views run the same function,
     *        no other state-changing path holds a `Market memory`
     */
    function _accrue(address asset) internal returns (Market storage market) {
        market = $.markets[asset];
        if (!market.exists) revert SenzuBorrowable__MarketNotFound(asset);
        if (market.lastAccrual == block.timestamp) return market;

        Market memory accrued = market;
        (uint256 interest, uint256 reserveAssets) = accrued.accrue();
        $.markets[asset] = accrued;
        if (interest == 0) return market;

        uint256 id = lenderId(asset);
        uint256 reserveShares = accrued.reserveShares(reserveAssets, totalSupply(id));
        if (reserveShares > 0) _bookReserves(market, id, reserveShares);

        emit AccrueInterest(asset, interest, reserveShares, accrued.totalBorrowAssets, accrued.rateAtTarget);
    }

    function _bookRepay(address account, uint256 id, address asset, uint256 assets)
        internal
        returns (Market storage market, uint256 repaid)
    {
        market = _accrue(asset);
        uint256 shares;
        (repaid, shares) = BorrowLogic.repayAmounts($, market, account, id, assets);
        BorrowLogic.repay($, market, account, id, repaid, shares);

        emit Repay(account, id, asset, repaid, shares);
    }

    function _writeOff(address asset, address account, uint256 id) internal {
        Market storage market = _accrue(asset);
        uint256 debtShares = BorrowLogic.sharesOf($, market, account, id);
        uint256 loss = MarketLogic.toAssets(debtShares, market.totalBorrowAssets, market.totalBorrowShares, Rounding.Up);
        // The last shares take all the debt (none left that no one owes); rounded up, a debt can pass the
        // market's, and lenders lose only what was lent
        if (debtShares == market.totalBorrowShares || loss > market.totalBorrowAssets) loss = market.totalBorrowAssets;

        BorrowLogic.reduceDebt($, market, account, id, loss, debtShares);
        market.totalSupplyAssets = loss > market.totalSupplyAssets ? 0 : market.totalSupplyAssets - loss.toUint128();

        emit BadDebt(account, id, asset, loss);
    }

    /// @dev What `shares` of `asset`'s debt owe now, interest to this block included; rounded up
    function _debtAssets(address asset, uint256 shares) internal view returns (uint256) {
        if (shares == 0) return 0;
        Market storage market = $.markets[asset];
        if (market.lastAccrual == block.timestamp) {
            return MarketLogic.toAssets(shares, market.totalBorrowAssets, market.totalBorrowShares, Rounding.Up);
        }
        Market memory accrued = market;
        accrued.accrue();
        return MarketLogic.toAssets(shares, accrued.totalBorrowAssets, accrued.totalBorrowShares, Rounding.Up);
    }

    function _expectedMarket(address asset) internal view returns (Market memory market, uint256 totalShares) {
        market = $.markets[asset];
        if (!market.exists) revert SenzuBorrowable__MarketNotFound(asset);

        totalShares = totalSupply(lenderId(asset));
        (, uint256 reserveAssets) = market.accrue();
        totalShares += market.reserveShares(reserveAssets, totalShares);
    }

    /// @dev Adds the protocol's `shares` to the market's pending ones, minted on `mintReserves` (or here, in the
    ///      unlikely case they would no longer fit)
    function _bookReserves(Market storage market, uint256 id, uint256 shares) internal {
        uint256 pending = market.pendingReserveShares + shares;
        if (pending > type(uint112).max) {
            market.pendingReserveShares = 0;
            _mintReserves(id, pending);
            return;
        }
        market.pendingReserveShares = pending.toUint112();
    }

    function _mintReserves(uint256 id, uint256 shares) internal {
        _mint(ISenzuFactory(factory).protocolReserves(), id, shares);
    }

    function _pullExact(address asset, address from, uint256 assets) internal {
        uint256 before = asset.balanceOf(address(this));
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        asset.safeTransferFrom(from, address(this), assets);
        if (asset.balanceOf(address(this)) - before < assets) revert SenzuBorrowable__UnsupportedToken(asset);
    }
}
