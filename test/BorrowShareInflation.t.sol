// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SenzuBorrowable} from "../src/core/SenzuBorrowable.sol";
import {SenzuCollateral} from "../src/core/SenzuCollateral.sol";
import {ISenzuFactory} from "../src/interfaces/ISenzuFactory.sol";
import {ISenzuLockCallback} from "../src/interfaces/ISenzuLockCallback.sol";
import {Market, lenderId} from "../src/libraries/Types.sol";
import {MockERC20} from "./mocks/Mocks.sol";
import {HubFixture} from "./utils/HubFixture.sol";

/**
 *  @dev Audit H-01's attack, in one lock: 400 debts of one share on ids not opened, each repaid for its rounded-up wei
 *       to empty the market's debt while shares are left; then rounds of a 3-wei borrow (which minted 3 × every share
 *       while the market's debt was 0) each followed by repaying 3 dust debts to empty it again
 */
contract Inflater is ISenzuLockCallback {
    SenzuCollateral c;
    SenzuBorrowable b;
    address asset;
    uint256 id1;
    uint256 id2;
    uint256 public dustDebts;
    uint256 public rounds;

    constructor(SenzuCollateral c_, SenzuBorrowable b_, address asset_) {
        (c, b, asset) = (c_, b_, asset_);
        MockERC20(asset_).approve(address(b_), type(uint256).max);
    }

    function setIds(uint256 a, uint256 z) external {
        (id1, id2) = (a, z);
    }

    function seed() external {
        c.borrow(address(this), id1, asset, 1e6, address(this));
    }

    function attack() external {
        c.lock("");
    }

    function _borrow(uint256 id, uint256 amount) internal {
        c.borrow(address(this), id, asset, amount, address(this));
    }

    function _repay(uint256 id, uint256 amount) internal {
        b.repay(address(this), id, asset, amount);
    }

    function senzuLockAcquired(bytes calldata) external returns (bytes memory) {
        uint256 lanes;
        uint256 f = 1_000_000;
        // Dust lanes: borrow 2, repay 2, one share left owing 1 wei
        for (uint256 i; i < 400; ++i) {
            _borrow(f + i, 2);
            if (b.debtOf(address(this), f + i, asset) > 2) _repay(f + i, 2);
            if (b.borrowSharesOf(address(this), f + i, asset) == 1) ++lanes;
        }
        dustDebts = lanes;
        _repay(id1, type(uint256).max);

        uint256 next = f;
        while (true) {
            uint256 target = b.borrowSharesOf(address(this), id1, asset) < (1 << 117) ? id1 : id2;
            try c.borrow(address(this), target, asset, 3, address(this)) {}
            catch {
                break;
            }
            ++rounds;
            // Close dust lanes at 1 wei each until A is back to 0
            while (b.getMarket(asset).totalBorrowAssets > 0 && next < f + 400) {
                if (b.borrowSharesOf(address(this), next, asset) > 0) _repay(next, type(uint256).max);
                ++next;
            }
            if (next >= f + 400) break;
        }
        for (; next < f + 400; ++next) {
            if (b.borrowSharesOf(address(this), next, asset) > 0) _repay(next, type(uint256).max);
        }
        return "";
    }
}

contract BorrowShareInflationTest is HubFixture {
    /// @notice The attack can't make its dust debts (since 2026-11-21 a partial repayment burns only the shares worth
    ///         the whole wei it clears, so "borrow 2, repay 2" leaves a wei's worth of shares, not one share), and its
    ///         rounds never empty the market's debt. Before the H-01 fix it ran 49 rounds, left 3.2e35 shares on a
    ///         debt of 0, and every later borrow reverted until someone repaid the attacker's 1 wei
    function test_dustDebtsCantEmptyTheMarketsDebt() public {
        Inflater x = new Inflater(collateral, borrowable, address(weth));
        weth.mint(address(x), 1e18);
        uint256 a = _open(address(x), L / 1000);
        uint256 z = _open(address(x), L / 1000);
        x.setIds(a, z);
        x.seed();
        vm.warp(block.timestamp + 1 days);
        x.attack();

        assertEq(x.dustDebts(), 0, "no one-share debts");
        assertLe(x.rounds(), 1, "no round after the first");
        Market memory m = borrowable.getMarket(address(weth));
        assertGt(m.totalBorrowAssets, 0, "the market's debt never emptied");
        assertLe(m.totalBorrowShares, (m.totalBorrowAssets + 1) * 1e6, "about a million shares per wei");

        vm.prank(ALICE);
        collateral.borrow(ALICE, id, address(weth), 1e15, ALICE);
    }

    /// @notice Repaying 2 of a debt of 3 (worth just over 2) clears 1 wei and leaves over a wei's worth of shares, not
    ///         one share; the rest of the payment goes to lenders. The final repayment books what its shares were
    ///         worth, and lenders get the rounded-up rest
    function test_repay_booksWhatTheSharesWereWorth_lendersGetTheRest() public {
        _borrow(ALICE, address(weth), 1e18);
        vm.warp(block.timestamp + 1 days);
        uint256 dust = _open(ALICE, L / 1000);
        weth.mint(ALICE, 1e18);
        vm.startPrank(ALICE);
        weth.approve(address(borrowable), type(uint256).max);
        collateral.borrow(ALICE, dust, address(weth), 2, ALICE);
        assertEq(borrowable.debtOf(ALICE, dust, address(weth)), 3, "2 wei, owed rounded up");

        Market memory before = borrowable.getMarket(address(weth));
        borrowable.repay(ALICE, dust, address(weth), 2);
        Market memory m = borrowable.getMarket(address(weth));
        assertEq(m.totalBorrowAssets, before.totalBorrowAssets - 1, "clears 1 wei");
        assertEq(m.totalSupplyAssets, before.totalSupplyAssets + 1, "the other wei is the lenders'");
        assertGt(borrowable.borrowSharesOf(ALICE, dust, address(weth)), 1, "not a one-share debt");
        assertEq(borrowable.debtOf(ALICE, dust, address(weth)), 2);

        before = m;
        uint256 paid = borrowable.repay(ALICE, dust, address(weth), type(uint256).max);
        vm.stopPrank();
        m = borrowable.getMarket(address(weth));
        assertEq(paid, 2);
        assertEq(m.totalBorrowAssets, before.totalBorrowAssets - 1, "its shares were worth just over a wei");
        assertEq(m.totalSupplyAssets, before.totalSupplyAssets + 1, "the rounded-up wei is the lenders'");
    }

    /// @notice A partial repayment clears whole wei: the sole lender, also a borrower, repaying 1 wei 100 times can't
    ///         move debt onto Alice (before 2026-11-21 each call burned under a wei of shares, booked 0 and moved the rest
    ///         onto every other borrower: Alice +100 wei, the attacker's net +100; now each wei burns nothing and goes
    ///         to lenders, the attacker's own lender share at most). A larger payment's rounding stays with the
    ///         repayer and goes to lenders; other borrowers take under a share's price
    function test_repay_partialRoundingStaysWithTheRepayer() public {
        _borrow(ALICE, address(usdc), 100e6);
        uint256 dust = _open(BOB, L / 1000);
        vm.prank(BOB);
        collateral.borrow(BOB, dust, address(usdc), 200, BOB);
        vm.warp(block.timestamp + 1 days);
        borrowable.accrueInterest(address(usdc));

        usdc.mint(BOB, 1e9);
        vm.startPrank(BOB);
        usdc.approve(address(borrowable), type(uint256).max);
        uint256 aliceDebt = borrowable.debtOf(ALICE, id, address(usdc));
        uint256 bobShares = borrowable.borrowSharesOf(BOB, dust, address(usdc));
        uint256 supplied = borrowable.getMarket(address(usdc)).totalSupplyAssets;
        for (uint256 i; i < 100; ++i) {
            borrowable.repay(BOB, dust, address(usdc), 1);
        }
        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), aliceDebt, "repay(1) moves nothing onto Alice");
        assertEq(borrowable.borrowSharesOf(BOB, dust, address(usdc)), bobShares, "a wei clears nothing, burns nothing");
        assertEq(borrowable.getMarket(address(usdc)).totalSupplyAssets, supplied + 100, "the wei are the lenders'");

        Market memory before = borrowable.getMarket(address(usdc));
        uint256 bobDebt = borrowable.debtOf(BOB, dust, address(usdc));
        borrowable.repay(BOB, dust, address(usdc), 77);
        vm.stopPrank();
        Market memory m = borrowable.getMarket(address(usdc));

        uint256 cleared = before.totalBorrowAssets - m.totalBorrowAssets;
        assertGe(cleared, 76, "clears the payment's whole wei");
        assertEq(m.totalSupplyAssets, before.totalSupplyAssets + 77 - cleared, "the rest is the lenders'");
        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), aliceDebt, "Alice's debt doesn't move");
        assertGe(borrowable.debtOf(BOB, dust, address(usdc)) + cleared, bobDebt, "the repayer pays the rounding");
    }

    /// @notice The last borrower's repayment takes all the debt: none is left that no one owes (it was the virtual
    ///         shares' wei), and every lender, the reserve included, withdraws everything
    function test_repay_theLastSharesLeaveNoDebt() public {
        _borrow(ALICE, address(usdc), 1000e6);
        vm.warp(block.timestamp + 1 hours);
        usdc.mint(ALICE, 1e9);
        vm.startPrank(ALICE);
        usdc.approve(address(borrowable), type(uint256).max);
        borrowable.repay(ALICE, id, address(usdc), type(uint256).max);
        vm.stopPrank();

        Market memory m = borrowable.getMarket(address(usdc));
        assertEq(m.totalBorrowShares, 0);
        assertEq(m.totalBorrowAssets, 0, "no debt without shares");

        uint256 lid = lenderId(address(usdc));
        address dao = ISenzuFactory(borrowable.factory()).protocolReserves();
        uint256 lent = borrowable.balanceOf(BOB, lid);
        vm.prank(BOB);
        borrowable.withdraw(address(usdc), lent, BOB, BOB);
        borrowable.mintReserves(address(usdc));
        uint256 reserve = borrowable.balanceOf(dao, lid);
        assertGt(reserve, 0, "the reserve earned a cut");
        vm.prank(dao);
        borrowable.withdraw(address(usdc), reserve, dao, dao);
        assertEq(usdc.balanceOf(address(borrowable)), borrowable.getMarket(address(usdc)).totalSupplyAssets);
    }
}
