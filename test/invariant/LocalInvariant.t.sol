// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Market, lenderId} from "../../src/libraries/Types.sol";
import {MockERC20} from "../mocks/Mocks.sol";
import {LocalHandler} from "./LocalHandler.sol";
import {LocalRouterHandler} from "./LocalRouterHandler.sol";
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/// @notice The core and a real adapter on a real pool deployed locally, after any sequence of actions
abstract contract LocalInvariantTest is Test {
    LocalRouterHandler handler;

    function setUp() public virtual {
        vm.warp(1_000_000);
        handler = _newHandler();
        targetContract(address(handler));
        bytes4[] memory views = new bytes4[](13);
        views[0] = LocalHandler.checkAll.selector;
        views[1] = LocalHandler.checkUnits.selector;
        views[2] = LocalHandler.checkPool.selector;
        views[3] = LocalHandler.checkMarket.selector;
        views[4] = LocalHandler.checkFeesBacked.selector;
        views[5] = LocalHandler.checkHealthAgainstReference.selector;
        views[6] = LocalHandler.checkAdapterBalances.selector;
        views[7] = LocalHandler.senzuLockAcquired.selector;
        views[8] = LocalHandler.feeDust.selector;
        views[9] = LocalHandler.checkNoStuckFees.selector;
        views[10] = LocalHandler.unwindAll.selector;
        views[11] = LocalHandler.checkAttackerMarket.selector;
        views[12] = LocalHandler.mintDataFor.selector;
        excludeSelector(FuzzSelector({addr: address(handler), selectors: views}));
    }

    function _newHandler() internal virtual returns (LocalRouterHandler);

    function invariant_coreAndAdapterHold() public view {
        handler.checkAll();
    }

    /// @notice A long pseudo-random run must reach every action, or a green invariant means little
    function test_handlerReachesEveryAction() public {
        uint256 seed = 0xC0FFEE;
        for (uint256 i; i < 6000; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            _step(seed);
            if (i % 50 == 0) handler.checkAll();
        }
        handler.checkAll();
        afterInvariant();
        string[38] memory names = _names();
        for (uint256 i; i < names.length; ++i) {
            assertGt(handler.calls(bytes32(bytes(names[i]))), 0, names[i]);
        }
    }

    function _step(uint256 s) internal {
        uint256 a = uint256(keccak256(abi.encode(s, 1)));
        uint256 b = uint256(keccak256(abi.encode(s, 2)));
        uint256 c = uint256(keccak256(abi.encode(s, 3)));
        uint256 d = uint256(keccak256(abi.encode(s, 4)));
        uint256 k = s % 166;
        if (k < 8) handler.supply(a, b, c);
        else if (k < 12) handler.withdraw(a, b, c);
        else if (k < 21) handler.open(a, b, c, d % 2 == 0);
        else if (k < 26) handler.increase(a, b, c, d % 2 == 0);
        else if (k < 32) handler.redeem(a, b, c);
        else if (k < 38) handler.collectFees(a, b);
        else if (k < 41) handler.donate(a, b);
        else if (k < 52) handler.borrow(a, b, c, d);
        else if (k < 55) handler.leverUp(a, b, c, d, uint256(keccak256(abi.encode(s, 5))));
        else if (k < 59) handler.deleverage(a, b, c, d);
        else if (k < 63) handler.repay(a, b, c, d);
        else if (k < 65) handler.resolveBadDebt(a, b);
        else if (k < 72) handler.swap(a % 2 == 0, b);
        else if (k < 76) handler.liquidate(a, b, c, d);
        else if (k < 82) handler.setEthPrice(a);
        else if (k < 85) handler.warp(a);
        else if (k < 91) handler.liquidate(a, b, c, d);
        else if (k < 95) handler.leveredOpen(a, b, c, d, uint256(keccak256(abi.encode(s, 5))));
        else if (k < 97) handler.flash(a, b, c, d);
        else if (k < 100) handler.badLock(a, b, c, d, uint256(keccak256(abi.encode(s, 5))));
        else if (k < 104) handler.trespass(a, b, c, d);
        else if (k < 107) handler.pause(a, b % 2 == 0);
        else if (k < 111) handler.setUsdcPrice(a);
        else if (k < 116) handler.donateTokens(a, b, c);
        else if (k < 120) handler.borrowOutside(a, b, c);
        else if (k < 126) handler.routerOpen(a, b, c, d, uint256(keccak256(abi.encode(s, 5))));
        else if (k < 131) handler.routerLeverUp(a, b, c, d);
        else if (k < 136) handler.routerDeleverage(a, b, c, d);
        else if (k < 140) handler.routerClose(a, b);
        else if (k < 145) handler.routerLiquidate(a, b, c, d);
        else if (k < 147) handler.routerSlippage(a, b, c);
        else if (k < 150) handler.routerAttack(a, b, c, d);
        else if (k < 154) handler.attackerSupply(a, b);
        else if (k < 158) handler.attackerWithdraw(a, b);
        else if (k < 162) handler.attackerBurst(a);
        else handler.attackerSwapBurst(a);
    }

    function _names() internal pure returns (string[38] memory) {
        return [
            "supply",
            "withdraw",
            "open",
            "increase",
            "redeem",
            "redeemAllWithFees",
            "collectFees",
            "donate",
            "borrow",
            "repay",
            "writeOff",
            "swap",
            "setEthPrice",
            "warp",
            "liquidate",
            "leveredOpen",
            "leverUp",
            "deleverage",
            "flash",
            "trespass",
            "pause",
            "setUsdcPrice",
            "donateTokens",
            "borrowLiquid",
            "borrowIlliquid",
            "borrowThird",
            "routerOpen",
            "routerLeverUp",
            "routerDeleverage",
            "routerClose",
            "routerCloseWithFees",
            "routerLiquidate",
            "routerSlippage",
            "routerAttack",
            "attackerSupply",
            "attackerWithdraw",
            "attackerBurst",
            "attackerSwapBurst"
        ];
    }

    /// @notice Deterministic coverage of Part 1 (continuous market share conservation across accrual), Part 2A (frozen
    ///         burst incl. self-liquidation and resolveBadDebt) and Part 2B (pool-aligned swap burst)
    function test_attackerProfitChecksCoverAllBurstActions() public {
        // Part 1: supply -> other borrows -> warp -> accrue -> 1-share/partial/full withdraw
        handler.attackerSupply(0, 100);
        handler.open(0, 1, 5e13, true);
        handler.borrow(0, 0, 0, 5000);
        handler.warp(7 days);
        handler.attackerWithdraw(0, 0); // 1 share (reverts ZeroAmount on real code; drains +1 wei if withdraw rounds up)
        handler.attackerWithdraw(0, 0); // 2nd 1-share withdraw
        handler.attackerWithdraw(0, 3); // partial
        handler.attackerWithdraw(0, 1); // full
        handler.checkAll();

        // Part 2A: frozen bursts (supply/withdraw/open/increase/redeem/collect/borrow/repay/flash/selfLiq/resolveBadDebt)
        for (uint256 s = 1; s <= 12; ++s) {
            handler.attackerBurst(s * 97);
        }
        // Crash ETH so any attacker debt can hit self-liquidation inside a burst
        handler.setEthPrice(0);
        for (uint256 s = 13; s <= 20; ++s) {
            handler.attackerBurst(s * 131);
        }
        handler.checkAll();

        // Part 2B: move pool off oracle price, then run pool-aligned swap bursts
        handler.swap(true, 10e18);
        for (uint256 s = 1; s <= 8; ++s) {
            handler.attackerSwapBurst(s * 173);
        }
        handler.checkAll();
        handler.unwindAll();
    }

    function afterInvariant() public {
        string[38] memory names = _names();
        for (uint256 i; i < names.length; ++i) {
            console2.log(names[i], handler.calls(bytes32(bytes(names[i]))));
        }
        console2.log("badLock", handler.calls("badLock"));
        console2.log("max fee shortfall (wei)", handler.maxFeeShortfall());
        console2.log("max flash excess debt (wei)", handler.maxFlashExcess());
        console2.log("max fee drift from pro-rata (wei)", handler.maxFeeDrift());
        (uint256 dust0, uint256 dust1) = handler.feeDust();
        console2.log("fee dust token0 (wei)", dust0);
        console2.log("fee dust token1 (wei)", dust1);
        console2.log("calls", handler.totalCalls());
        handler.unwindAll();
    }
}

/// @notice Empty-market invariant suite: starts with 0 supplied across all markets, exercises 1-wei dust, direct
///         donations, bad-debt write-offs draining a market before a new lender joins, and full `unwindAll()`
abstract contract EmptyMarketInvariantTest is LocalInvariantTest {
    function test_emptyMarketInflationAndBadDebtDrain() public {
        address usdc = address(handler.usdc());
        Market memory m0 = handler.borrowable().getMarket(usdc);
        assertEq(m0.totalSupplyAssets, 0, "market starts empty");

        // 1. Cold-start inflation attempt: actor 0 supplies 1 wei, donates 50k USDC directly, actor 1 supplies ~$25 USDC
        handler.supply(0, 0, 0); // 1..10 wei dust
        handler.donateTokens(0, 0, 50_000e6);
        handler.supply(1, 0, 25e6 + 2); // normal supply: supply() asserts convertToAssets(shares) + 2 >= amount
        handler.checkAll();

        // 2. Actor 2 opens a narrow position (range 2: ±120 ticks) and borrows ~80% of the ~$25 market
        handler.open(2, 2, 5e13, true);
        handler.borrow(2, 0, 0, 7499); // % 5 != 0 (avoids dust-borrow bias)
        uint256 supplyBeforeCrash = handler.borrowable().getMarket(usdc).totalSupplyAssets;
        uint256 debt = handler.borrowable().debtOf(handler.actors(2), 1, usdc);
        assertGt(debt, 15e6, "borrowed most of the fresh market");

        // 3. ETH crashes to $300 -> position is deeply underwater -> full liquidation writes off bad debt,
        //    draining totalSupplyAssets while totalSupplyShares stays large
        handler.setEthPrice(0);
        handler.liquidate(2, 0, 0, debt);
        uint256 supplyAfterWriteOff = handler.borrowable().getMarket(usdc).totalSupplyAssets;
        assertLt(supplyAfterWriteOff, supplyBeforeCrash, "bad debt drained the market");
        handler.checkAll();

        // 4. New lender (actor 3) joins the drained market with 1 wei, then normal size: must get fair shares
        //    without hurting existing lenders
        uint256 a1Shares = handler.borrowable().balanceOf(handler.actors(1), lenderId(usdc));
        uint256 a1ClaimBefore = handler.borrowable().convertToAssets(usdc, a1Shares);
        handler.supply(3, 0, 0); // dust into drained market
        handler.supply(3, 0, 20_000e6 + 2); // normal into drained market
        assertGe(handler.borrowable().convertToAssets(usdc, a1Shares) + 1, a1ClaimBefore, "existing lender intact");
        handler.checkAll();

        // 5. Everyone exits cleanly
        handler.unwindAll();
    }

    /// @notice Red/green test for BorrowLogic.repay partial-repay rounding: 100 × repay(1) at a frozen timestamp after
    ///         interest accrual must not shift debt onto other borrowers or profit a lender-attacker
    function test_repayDustDoesNotShiftDebtOrProfitLender() public {
        address usdc = address(handler.usdc());
        address attacker = address(0xA77AC4);
        address alice = handler.actors(0);

        // 1. Attacker supplies 100k USDC as sole lender
        vm.startPrank(attacker);
        handler.borrowable().supply(usdc, 100_000e6, attacker);
        vm.stopPrank();

        // 2. Alice opens a well-collateralized position and borrows 100 USDC
        handler.open(0, 1, 5e13, true); // id 1
        vm.startPrank(alice);
        handler.collateral().borrow(alice, 1, usdc, 100e6, alice);
        vm.stopPrank();

        // 3. Attacker opens a position and borrows 400 wei USDC
        uint256 attId = _openForAttacker(1, 1e12);
        vm.startPrank(attacker);
        handler.collateral().borrow(attacker, attId, usdc, 400, attacker);
        vm.stopPrank();

        // 4. Advance 1 day and accrue so borrow share price is non-integer
        handler.warp(1 days);
        handler.borrowable().accrueInterest(usdc);

        uint256 aliceDebtBefore = handler.borrowable().debtOf(alice, 1, usdc);
        uint256 attWalletBefore = handler.usdc().balanceOf(attacker);
        uint256 attClaimBefore =
            handler.borrowable().convertToAssets(usdc, handler.borrowable().balanceOf(attacker, lenderId(usdc)));
        uint256 attDebtBefore = handler.borrowable().debtOf(attacker, attId, usdc);
        int256 attNetBefore = int256(attWalletBefore + attClaimBefore) - int256(attDebtBefore);

        // 5. 100 × repay(1 wei) (burns 0 shares without reverting per audit M-02 on fixed BorrowLogic; steals +100 on
        //    old rounding) and 100 × repay(2 wei) (shifts +0 onto Alice on fixed vs +100 on old rounding)
        vm.startPrank(attacker);
        for (uint256 i; i < 100; ++i) {
            handler.borrowable().repay(attacker, attId, usdc, 1);
        }
        for (uint256 i; i < 100; ++i) {
            handler.borrowable().repay(attacker, attId, usdc, 2);
        }
        vm.stopPrank();

        uint256 aliceDebtAfter = handler.borrowable().debtOf(alice, 1, usdc);
        uint256 attWalletAfter = handler.usdc().balanceOf(attacker);
        uint256 attClaimAfter =
            handler.borrowable().convertToAssets(usdc, handler.borrowable().balanceOf(attacker, lenderId(usdc)));
        uint256 attDebtAfter = handler.borrowable().debtOf(attacker, attId, usdc);
        int256 attNetAfter = int256(attWalletAfter + attClaimAfter) - int256(attDebtAfter);

        assertLe(aliceDebtAfter, aliceDebtBefore, "repay dust shifted debt onto Alice");
        assertLe(attNetAfter, attNetBefore, "repay dust profited lender-attacker");
    }

    /// @notice Emptied-market rate reset replay:
    ///         (a) repay/clear every loan in a market,
    ///         (b) supply 1 wei then withdraw 2/3 of shares so totalSupplyAssets reaches 0 while attacker still holds
    ///             lender shares,
    ///         (c) a victim supplies a large amount,
    ///         (d) attacker withdraws everything.
    ///         Attacker net <= +1 wei and victim round trip loses <= one share's price + 1 wei.
    function test_emptiedMarketRateResetReplay() public {
        MockERC20 usdc = handler.usdc();
        address asset = address(usdc);
        address attacker = address(0xA77AC4);
        address victim = handler.actors(1);
        uint256 sid = lenderId(asset);

        // Setup: attacker seeds $25 USDC, actor 0 borrows $24 of it, extreme ETH crash -> bad-debt write-off clears
        // all loans (step a) and leaves totalSupplyShares >> totalSupplyAssets
        vm.startPrank(attacker);
        handler.borrowable().supply(asset, 25e6, attacker);
        vm.stopPrank();
        handler.open(0, 2, 9e13, true);
        address alice = handler.actors(0);
        vm.startPrank(alice);
        handler.collateral().borrow(alice, 1, asset, 24e6, alice);
        vm.stopPrank();
        uint256 debt = handler.borrowable().debtOf(alice, 1, asset);
        handler.ethFeed().set(1e6, block.timestamp); // $0.01 ETH -> near-total bad-debt write-off
        handler.liquidate(0, 0, 0, debt);

        // (a) Ensure every loan in the market is repaid / zeroed
        Market memory m = handler.borrowable().getMarket(asset);
        assertEq(m.totalBorrowAssets, 0, "step (a): borrow assets remained");
        assertEq(m.totalBorrowShares, 0, "step (a): borrow shares remained");

        // Mint and withdraw DAO's reserve shares first so attacker owns 100% of totalShares, then drain
        // totalSupplyAssets down to 0 while keeping residual lender shares (possible because S > A * 1e6 after write-off)
        handler.borrowable().mintReserves(asset);
        address dao = handler.factory().protocolReserves();
        uint256 daoShares = handler.borrowable().balanceOf(dao, sid);
        if (daoShares > 0 && handler.borrowable().convertToAssets(asset, daoShares) > 0) {
            vm.startPrank(dao);
            handler.borrowable().withdraw(asset, daoShares, dao, dao);
            vm.stopPrank();
        }
        m = handler.borrowable().getMarket(asset);
        if (m.totalSupplyAssets > 0) {
            uint256 totalShares = handler.borrowable().totalSupply(sid);
            uint256 need = (uint256(m.totalSupplyAssets) * (totalShares + 1e6) + uint256(m.totalSupplyAssets))
                / (uint256(m.totalSupplyAssets) + 1);
            vm.startPrank(attacker);
            handler.borrowable().withdraw(asset, need, attacker, attacker);
            vm.stopPrank();
        }
        assertEq(handler.borrowable().getMarket(asset).totalSupplyAssets, 0, "pre-(b): supply not zero");
        assertGt(handler.borrowable().balanceOf(attacker, sid), 0, "pre-(b): attacker has no residual shares");

        // (b) Supply 1 wei, then withdraw 2/3 of attacker's shares -> totalSupplyAssets returns to 0 while attacker
        //     still holds 1/3 of its lender shares
        uint256 attWalletBefore = usdc.balanceOf(attacker);
        vm.startPrank(attacker);
        handler.borrowable().supply(asset, 1, attacker);
        uint256 attSharesMid = handler.borrowable().balanceOf(attacker, sid);
        handler.borrowable().withdraw(asset, attSharesMid * 2 / 3, attacker, attacker);
        vm.stopPrank();

        m = handler.borrowable().getMarket(asset);
        uint256 attSharesAfterB = handler.borrowable().balanceOf(attacker, sid);
        assertEq(m.totalSupplyAssets, 0, "step (b): totalSupplyAssets must be 0");
        assertGt(attSharesAfterB, 0, "step (b): attacker must still hold lender shares");

        // (c) Victim supplies a large amount (100,000 USDC)
        uint256 deposit = 100_000e6;
        usdc.mint(victim, deposit);
        vm.startPrank(victim);
        usdc.approve(address(handler.borrowable()), deposit);
        uint256 victimShares = handler.borrowable().supply(asset, deposit, victim);
        vm.stopPrank();
        uint256 oneSharePrice = handler.borrowable().convertToAssets(asset, 1);

        // (d) Attacker withdraws everything withdrawable, then victim withdraws everything
        if (handler.borrowable().convertToAssets(asset, attSharesAfterB) > 0) {
            vm.startPrank(attacker);
            handler.borrowable().withdraw(asset, attSharesAfterB, attacker, attacker);
            vm.stopPrank();
        }
        uint256 attWalletAfter = usdc.balanceOf(attacker);

        vm.startPrank(victim);
        uint256 victimOut = handler.borrowable().withdraw(asset, victimShares, victim, victim);
        vm.stopPrank();

        assertLe(attWalletAfter, attWalletBefore + 1, "rate reset replay: attacker profited > 1 wei");
        assertGe(
            victimOut + oneSharePrice + 1, deposit, "rate reset replay: victim lost more than one share's price + 1 wei"
        );
    }

    function _openForAttacker(uint256 r, uint128 l) internal returns (uint256 id) {
        address attacker = address(0xA77AC4);
        bytes memory md = handler.mintDataFor(r, l);
        (,, uint256 a0, uint256 a1) = handler.adapter().quoteDeposit(md);
        vm.startPrank(attacker);
        if (a0 > 0) handler.token0().transfer(address(handler.adapter()), a0);
        if (a1 > 0) handler.token1().transfer(address(handler.adapter()), a1);
        (id,,,,,) = handler.collateral().open(attacker, attacker, md);
        vm.stopPrank();
    }
}
