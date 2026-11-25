// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISenzuCollateral} from "../src/interfaces/ISenzuCollateral.sol";
import {ISenzuERC6909} from "../src/interfaces/ISenzuERC6909.sol";
import {ISenzuRouter} from "../src/interfaces/ISenzuRouter.sol";
import {lenderId} from "../src/libraries/Types.sol";
import {SenzuBaseRouter} from "../src/periphery/SenzuBaseRouter.sol";
import {MockERC20, MockSwapRouter, MockWETH} from "./mocks/Mocks.sol";
import {HubFixture} from "./utils/HubFixture.sol";
import {RouterPlan} from "./utils/RouterPlan.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev A pool that calls back into the router mid-swap, through execute or swap
contract ReentrantPool {
    function callBack(SenzuBaseRouter r, bool viaSwap) external {
        if (viaSwap) r.swap(address(0), address(1), 0, 0, "");
        else r.execute("", new bytes[](0), block.timestamp, false);
    }
}

/// @dev A router whose swap reaches that pool
contract ReentrantRouter is SenzuBaseRouter {
    ReentrantPool internal immutable _pool = new ReentrantPool();

    constructor(address collateral_, address weth_) SenzuBaseRouter(collateral_, weth_, address(0)) {}

    function _swapExactIn(address, address, uint256, bytes memory route) internal override {
        _pool.callBack(this, abi.decode(route, (bool)));
    }

    function _swapExactOut(address, address, uint256, bytes memory) internal override {}
}

contract SenzuRouterTest is HubFixture {
    using RouterPlan for RouterPlan.Plan;

    uint256 constant ALL = type(uint256).max;

    MockSwapRouter senzuRouter;

    function setUp() public override {
        super.setUp();
        vm.etch(address(weth), address(new MockWETH()).code);
        senzuRouter = new MockSwapRouter(address(collateral), address(weth), address(0));

        vm.startPrank(ALICE);
        collateral.setOperator(address(senzuRouter), true);
        usdc.approve(address(senzuRouter), type(uint256).max);
        weth.approve(address(senzuRouter), type(uint256).max);
        vm.stopPrank();
    }

    /*  ================================================
                            Helpers
        ================================================  */

    function _run(address who, RouterPlan.Plan memory p) internal returns (uint256) {
        vm.prank(who);
        return senzuRouter.execute(p.actions, p.params, block.timestamp, false);
    }

    /// @dev A mock route that pays exactly `amountOut`
    function _fill(uint256 amountOut) internal pure returns (bytes memory) {
        return abi.encode(amountOut);
    }

    function _assertRouterEmpty() internal view {
        assertEq(usdc.balanceOf(address(senzuRouter)), 0, "router holds USDC");
        assertEq(weth.balanceOf(address(senzuRouter)), 0, "router holds WETH");
        assertEq(address(senzuRouter).balance, 0, "router holds ETH");
        // Approvals stand at the max (or were never given): with nothing held, they reach nothing between calls
        uint256 allowed = usdc.allowance(address(senzuRouter), address(borrowable));
        assertTrue(allowed == 0 || allowed == type(uint256).max, "only standing max approvals");
    }

    /*  ================================================
                      Borrow and leverage
        ================================================  */

    function test_borrow_sendsTheLoanToTheUser() public {
        RouterPlan.Plan memory p;
        _run(ALICE, p.borrow(id, address(usdc), 1_000e6));

        assertEq(usdc.balanceOf(ALICE), 1_000e6);
        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), 1_000e6);
        _assertRouterEmpty();
    }

    function test_leverage_borrowSwapIncrease() public {
        adapter.setNextIncrease(L / 2);
        RouterPlan.Plan memory p;
        p = p.borrow(id, address(usdc), 2_000e6);
        p = p.swap(address(usdc), address(weth), 1_000e6, 0.5e18, _fill(0.5e18));
        p = p.increase(id, ALL, ALL, 0, 0);
        vm.recordLogs();
        _run(ALICE, p);
        // The swap is part of the leverage: only `swap()` emits Swap
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics.length == 0 || logs[i].topics[0] != ISenzuRouter.Swap.selector, "Swap inside execute"
            );
        }

        assertEq(collateral.balanceOf(ALICE, id), L + L / 2);
        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), 2_000e6);
        // Everything went to the adapter
        assertEq(usdc.balanceOf(address(adapter)), 1_000e6);
        assertEq(weth.balanceOf(address(adapter)), 0.5e18);
        _assertRouterEmpty();
    }

    function test_healthIsCheckedOnceAtTheEnd() public {
        // Borrowing 95% alone fails the borrow check...
        uint256 tooMuch = _usdcFor(0.95e18);
        RouterPlan.Plan memory p;
        p = p.borrow(id, address(usdc), tooMuch);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__InsufficientCollateral.selector);
        _run(ALICE, p);

        // ...but repaying most of it in the same call passes
        p = p.repay(id, address(usdc), tooMuch / 2);
        _run(ALICE, p);
        assertApproxEqAbs(borrowable.debtOf(ALICE, id, address(usdc)), tooMuch - tooMuch / 2, 1);
        _assertRouterEmpty();
    }

    function test_swapBelowMinimumReverts() public {
        RouterPlan.Plan memory p;
        p = p.borrow(id, address(usdc), 1_000e6);
        p = p.swap(address(usdc), address(weth), 1_000e6, 1e18, _fill(0.4e18));
        vm.expectRevert(
            abi.encodeWithSelector(ISenzuRouter.SenzuRouter__InsufficientOutput.selector, address(weth), 0.4e18, 1e18)
        );
        _run(ALICE, p);
    }

    /*  ================================================
                Slippage: the router's minimums
        ================================================  */

    /// @dev The core takes no minimums; the router checks what actually went in (the balance it lost, net of the
    ///      adapter's refund) against the user's min0/min1
    function test_increase_checksWhatWentInAgainstTheMinimums() public {
        bool usdcIs0 = adapter.shape(id).token0 == address(usdc);
        adapter.setNextIncrease(L / 10);

        RouterPlan.Plan memory p;
        p = p.borrow(id, address(usdc), 1_000e6);
        (uint256 min0, uint256 min1) = usdcIs0 ? (uint256(1_000e6 + 1), uint256(0)) : (uint256(0), uint256(1_000e6 + 1));
        vm.expectRevert(
            abi.encodeWithSelector(
                ISenzuRouter.SenzuRouter__DepositBelowMinimum.selector, address(usdc), 1_000e6, 1_000e6 + 1
            )
        );
        _run(ALICE, p.increase(id, ALL, ALL, min0, min1));

        // Exactly the minimum goes through
        (min0, min1) = usdcIs0 ? (uint256(1_000e6), uint256(0)) : (uint256(0), uint256(1_000e6));
        _run(ALICE, p.increase(id, ALL, ALL, min0, min1));
        assertEq(collateral.balanceOf(ALICE, id), L + L / 10);
        _assertRouterEmpty();
    }

    function test_redeem_checksWhatCameOutAgainstTheMinimums() public {
        RouterPlan.Plan memory p;
        vm.expectPartialRevert(ISenzuRouter.SenzuRouter__InsufficientOutput.selector);
        _run(ALICE, p.redeem(id, L / 10, type(uint128).max, 0));

        _run(ALICE, p.redeem(id, L / 10, 1, 1));
        assertEq(collateral.balanceOf(ALICE, id), L - L / 10);
        _assertRouterEmpty();
    }

    function test_increaseRedeemAndCompound_passTheirAdapterData() public {
        adapter.setNextIncrease(L / 10);
        RouterPlan.Plan memory p;
        _run(ALICE, p.borrow(id, address(usdc), 1_000e6).increase(id, ALL, ALL, 0, 0, hex"0a"));
        assertEq(adapter.lastIncreaseData(), hex"0a");

        RouterPlan.Plan memory r;
        _run(ALICE, r.redeem(id, L / 10, 0, 0, hex"0b"));
        assertEq(adapter.lastDecreaseData(), hex"0b");

        adapter.accrueFees(id, 0.1e18, 200e6);
        RouterPlan.Plan memory c;
        _run(ALICE, c.compound(id, 0, 0, hex"0c"));
        assertEq(adapter.lastIncreaseData(), hex"0c");
        _assertRouterEmpty();
    }

    function test_compound_collectsAndAddsWithTheMinimums() public {
        adapter.accrueFees(id, 0.1e18, 200e6);
        adapter.setNextIncrease(L / 100);

        RouterPlan.Plan memory p;
        vm.expectPartialRevert(ISenzuRouter.SenzuRouter__DepositBelowMinimum.selector);
        _run(ALICE, p.compound(id, type(uint128).max, 0));

        _run(ALICE, p.compound(id, 1, 1));
        assertEq(collateral.balanceOf(ALICE, id), L + L / 100);
        _assertRouterEmpty();
    }

    /// @dev No fees to add still fails a minimum above zero
    function test_compound_nothingToAddFailsAMinimum() public {
        RouterPlan.Plan memory p;
        vm.expectPartialRevert(ISenzuRouter.SenzuRouter__DepositBelowMinimum.selector);
        _run(ALICE, p.compound(id, 0, 1));
    }

    function test_open_minimumForEveryToken() public {
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(weth), address(usdc));
        bytes memory data = abi.encode(address(weth), address(usdc), uint160(1), uint160(2), L);
        RouterPlan.Plan memory p;
        p.actions = bytes.concat(bytes1(uint8(ISenzuRouter.Action.Open)));
        p.params = new bytes[](1);
        p.params[0] = abi.encode(data, tokens, new uint256[](1));
        vm.expectRevert(ISenzuRouter.SenzuRouter__LengthMismatch.selector);
        _run(ALICE, p);
    }

    /*  ================================================
                      Deleverage and close
        ================================================  */

    function test_close_redeemSwapRepayAll() public {
        _borrow(ALICE, address(usdc), 3_000e6);
        usdc.burn(ALICE, 3_000e6); // she spent the loan

        // Redeem everything: about 2.2 WETH + 4.5k USDC at $2000. Swap the WETH for USDC, repay all, keep the rest
        RouterPlan.Plan memory p;
        p = p.redeem(id, ALL, 0, 0);
        p = p.swap(address(weth), address(usdc), ALL, 0, _fill(4_400e6));
        p = p.repay(id, address(usdc), ALL);
        _run(ALICE, p);

        assertEq(collateral.balanceOf(ALICE, id), 0);
        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), 0);
        assertGt(usdc.balanceOf(ALICE), 5_000e6, "equity comes back in USDC");
        _assertRouterEmpty();
    }

    /// @dev WETH per USDC unit at $2000: 1e-6 USDC = 5e8 wei
    uint256 constant WETH_PER_USDC_WAD = 5e8 * 1e18;

    /// @dev The mock router ignores an exact output's route
    bytes constant ROUTE = "";

    function _setWethPrice() internal {
        senzuRouter.setRate(address(weth), address(usdc), 1e18, WETH_PER_USDC_WAD);
    }

    /// @dev The debt (interest included) is read on-chain after the redeem; the swap buys exactly the gap, so the
    ///      close needs no headroom and sells no more WETH than the gap costs
    function test_close_swapForDebtBuysExactlyTheGap() public {
        _borrow(ALICE, address(usdc), 6_000e6);
        usdc.burn(ALICE, 6_000e6); // she spent the loan
        vm.warp(block.timestamp + 12 hours); // inside the feeds' heartbeat
        uint256 debt = borrowable.debtOf(ALICE, id, address(usdc));
        assertGt(debt, 6_000e6, "interest accrued");
        _setWethPrice();

        RouterPlan.Plan memory p;
        p = p.redeem(id, ALL, 0, 0);
        p = p.swapForDebt(id, address(usdc), address(weth), ALL, ROUTE);
        p = p.repay(id, address(usdc), ALL);
        _run(ALICE, p);

        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), 0);
        assertEq(collateral.balanceOf(ALICE, id), 0);
        assertEq(usdc.balanceOf(ALICE), 0, "no USDC bought beyond the debt");
        assertGt(senzuRouter.kept(address(weth)), 0, "WETH sold for the gap");
        _assertRouterEmpty();
    }

    function test_swapForDebt_skipsWhenTheRouterHoldsEnough() public {
        _borrow(ALICE, address(usdc), 1_000e6);
        _setWethPrice();

        RouterPlan.Plan memory p;
        p = p.redeem(id, ALL, 0, 0);
        p = p.swapForDebt(id, address(usdc), address(weth), ALL, ROUTE);
        p = p.repay(id, address(usdc), ALL);
        _run(ALICE, p);

        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), 0);
        assertEq(senzuRouter.kept(address(weth)), 0, "no swap");
        _assertRouterEmpty();
    }

    function test_swapForDebt_spendsAtMostMaxIn() public {
        _borrow(ALICE, address(usdc), 6_000e6);
        usdc.burn(ALICE, 6_000e6);
        _setWethPrice();

        RouterPlan.Plan memory p;
        p = p.redeem(id, ALL, 0, 0);
        p = p.swapForDebt(id, address(usdc), address(weth), 0.1e18, ROUTE); // the gap costs about 0.75 WETH
        vm.expectPartialRevert(ISenzuRouter.SenzuRouter__ExcessiveInput.selector);
        _run(ALICE, p);
    }

    /// @dev SWAP of ALL with nothing to sell is no swap (pools refuse a zero amount), and its minimum still holds
    function test_swapOfNothingIsSkipped() public {
        RouterPlan.Plan memory p;
        _run(ALICE, p.swap(address(weth), address(usdc), ALL, 0, _fill(1)));
        assertEq(usdc.balanceOf(ALICE), 0, "no swap ran");

        vm.expectRevert(
            abi.encodeWithSelector(ISenzuRouter.SenzuRouter__InsufficientOutput.selector, address(usdc), 0, 1)
        );
        _run(ALICE, p.swap(address(weth), address(usdc), ALL, 1, _fill(1)));
    }

    function test_callbackOnlyFromTheCollateral() public {
        vm.expectRevert(ISenzuRouter.SenzuRouter__NotCollateral.selector);
        senzuRouter.senzuLockAcquired(abi.encode(bytes(""), new bytes[](0), false));
    }

    /// @dev Ekubo's EVM routers (May 2026) paid a settlement with whoever the callback's data named. Here the user is
    ///      the caller of `execute`, kept in transient storage: outside one, even the collateral can't make the
    ///      router pull from someone who approved it
    function test_callbackOnlyInsideItsOwnExecute() public {
        usdc.mint(ALICE, 1_000e6);
        RouterPlan.Plan memory p;
        p = p.pull(address(usdc), 1_000e6);
        vm.prank(address(collateral));
        vm.expectRevert(ISenzuRouter.SenzuRouter__NotCollateral.selector);
        senzuRouter.senzuLockAcquired(abi.encode(p.actions, p.params, false));
        assertEq(usdc.balanceOf(ALICE), 1_000e6, "nothing pulled");
    }

    /// @dev A pool calling back into execute or swap mid-swap
    function test_poolCantReenter() public {
        ReentrantRouter r = new ReentrantRouter(address(collateral), address(weth));
        vm.prank(ALICE);
        collateral.setOperator(address(r), true);

        for (uint256 i; i < 2; ++i) {
            RouterPlan.Plan memory p;
            p = p.borrow(id, address(usdc), 1_000e6);
            p = p.swap(address(usdc), address(weth), 1_000e6, 0, abi.encode(i == 1));
            vm.prank(ALICE);
            vm.expectRevert(ISenzuRouter.SenzuRouter__Reentrant.selector);
            r.execute(p.actions, p.params, block.timestamp, false);
        }
    }

    /// @dev `swap` outside a lock (for the automator): pulls from the caller, the output and only it back
    function test_swap_forACallerOutsideALock() public {
        weth.mint(ALICE, 1e18);
        vm.expectEmit(address(senzuRouter));
        emit ISenzuRouter.Swap(ALICE, address(weth), address(usdc), 1e18, 2_000e6);
        vm.prank(ALICE);
        uint256 out = senzuRouter.swap(address(weth), address(usdc), 1e18, 2_000e6, _fill(2_000e6));
        assertEq(out, 2_000e6);
        assertEq(usdc.balanceOf(ALICE), 2_000e6);
        assertEq(weth.balanceOf(ALICE), 0);
        _assertRouterEmpty();

        weth.mint(ALICE, 1e18);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(ISenzuRouter.SenzuRouter__InsufficientOutput.selector, address(usdc), 1, 2)
        );
        senzuRouter.swap(address(weth), address(usdc), 1e18, 2, _fill(1));

        vm.prank(ALICE);
        vm.expectRevert(ISenzuRouter.SenzuRouter__InvalidRoute.selector);
        senzuRouter.swap(address(weth), address(weth), 1e18, 0, _fill(1));
    }

    /*  ================================================
                        Audit 2026-10-06
        ================================================  */

    /// @dev Audit lead 2026-10-06: FLASH_LIQUIDATE leaves its repayment approved until the lock ends, and a later
    ///      SUPPLY, REPAY or LIQUIDATE in the same asset reset the approval to 0, so the repayment failed and the whole
    ///      call reverted. Those actions put back what was approved before them
    function test_flashLiquidationRepaymentSurvivesALaterSupply() public {
        _borrow(ALICE, address(usdc), _usdcFor(0.8e18));
        ethFeed.set(1600e8, block.timestamp);
        usdc.mint(CAROL, 100_000e6);
        vm.startPrank(CAROL);
        usdc.approve(address(senzuRouter), type(uint256).max);
        collateral.setOperator(address(senzuRouter), true);
        vm.stopPrank();

        RouterPlan.Plan memory p;
        p = p.pull(address(usdc), 100_000e6);
        p = p.liquidate(ALICE, id, address(usdc), ALL);
        p = p.supply(address(usdc), 1_000e6);
        _run(CAROL, p);

        assertGt(collateral.balanceOf(CAROL, id), 0, "seized units");
        assertGt(borrowable.balanceOf(CAROL, uint256(uint160(address(usdc)))), 0, "supplied");
        _assertRouterEmpty();
    }

    /// @dev The router max-approves the borrowable once, then only reads the allowance; one that a token decremented
    ///      below what an action pulls is approved again (USDC-style tokens decrement even a max allowance)
    function test_approveMax_standsAndIsRenewedWhenShort() public {
        usdc.mint(CAROL, 2_000e6);
        vm.prank(CAROL);
        usdc.approve(address(senzuRouter), type(uint256).max);

        RouterPlan.Plan memory p;
        p = p.pull(address(usdc), 1_000e6);
        p = p.supply(address(usdc), 1_000e6);
        _run(CAROL, p);
        assertEq(usdc.allowance(address(senzuRouter), address(borrowable)), type(uint256).max, "standing");

        // As if a decrementing token had worn it down below the next pull
        vm.prank(address(senzuRouter));
        usdc.approve(address(borrowable), 1);
        _run(CAROL, p);
        assertEq(usdc.allowance(address(senzuRouter), address(borrowable)), type(uint256).max, "renewed");
        assertEq(borrowable.balanceOf(CAROL, lenderId(address(usdc))) > 0, true);
        _assertRouterEmpty();
    }

    /// @dev An id that was never opened is refused up front, not somewhere unhelpful inside the adapter
    function test_unknownPositionIsRefused() public {
        RouterPlan.Plan memory p;
        vm.expectRevert(ISenzuRouter.SenzuRouter__NoPosition.selector);
        _run(ALICE, p.collectFees(999));
    }

    /*  ================================================
                           AUTHORIZE
        ================================================  */

    function _operatorSig(uint256 key, ISenzuERC6909 token, address operator, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        address owner = vm.addr(key);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("SetOperator(address owner,address operator,bool approved,uint256 nonce,uint256 deadline)"),
                owner,
                operator,
                true,
                token.nonces(owner),
                deadline
            )
        );
        return vm.sign(key, keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)));
    }

    /// @dev A WETH lender with no approval of the router: AUTHORIZE then WITHDRAW, native ETH out, one call
    function _lendWeth() internal returns (address lender, uint256 key) {
        (lender, key) = makeAddrAndKey("ethLender");
        weth.mint(lender, 2e18);
        vm.startPrank(lender);
        weth.approve(address(borrowable), type(uint256).max);
        borrowable.supply(address(weth), 2e18, lender);
        vm.stopPrank();
    }

    function test_authorize_withdrawsEthInOneCall() public {
        (address lender, uint256 key) = _lendWeth();
        vm.deal(address(weth), 10e18); // the mock WETH pays its unwraps from its own ETH
        (uint8 v, bytes32 r, bytes32 s) = _operatorSig(key, borrowable, address(senzuRouter), block.timestamp);
        RouterPlan.Plan memory p;
        p = p.authorize(true, block.timestamp, v, r, s);
        p = p.withdraw(address(weth), ALL);

        vm.prank(lender);
        senzuRouter.execute(p.actions, p.params, block.timestamp, true);
        assertApproxEqAbs(lender.balance, 2e18, 1, "native ETH, no approval first");
        assertEq(borrowable.balanceOf(lender, lenderId(address(weth))), 0);
        assertTrue(borrowable.isOperator(lender, address(senzuRouter)), "and later calls need nothing");
    }

    /// @dev A signature someone else submitted first doesn't make the call revert: already an operator, skipped
    function test_authorize_skipsWhenAlreadyAnOperator() public {
        (address lender, uint256 key) = _lendWeth();
        (uint8 v, bytes32 r, bytes32 s) = _operatorSig(key, borrowable, address(senzuRouter), block.timestamp);
        borrowable.setOperatorBySig(lender, address(senzuRouter), true, block.timestamp, v, r, s); // front-run
        RouterPlan.Plan memory p;
        p = p.authorize(true, block.timestamp, v, r, s);
        p = p.withdraw(address(weth), borrowable.balanceOf(lender, lenderId(address(weth))) / 2);
        vm.prank(lender);
        senzuRouter.execute(p.actions, p.params, block.timestamp, false);
        assertApproxEqAbs(weth.balanceOf(lender), 1e18, 1);
    }

    /// @dev Only ever for the caller: someone else's signature authorizes the router for nobody. As Uniswap's
    ///      Permit2Forwarder, a signature that fails is skipped, and the first action that needs it reverts
    function test_authorize_onlyForTheCaller() public {
        (address lender, uint256 key) = _lendWeth();
        (uint8 v, bytes32 r, bytes32 s) = _operatorSig(key, borrowable, address(senzuRouter), block.timestamp);
        RouterPlan.Plan memory p;
        p = p.authorize(true, block.timestamp, v, r, s);
        vm.prank(BOB);
        senzuRouter.execute(p.actions, p.params, block.timestamp, false);
        assertFalse(borrowable.isOperator(BOB, address(senzuRouter)), "not for the caller");
        assertFalse(borrowable.isOperator(lender, address(senzuRouter)), "not for the signer");
        assertEq(borrowable.nonces(lender), 0, "the signer's signature is untouched");
        assertEq(borrowable.nonces(BOB), 0);
    }

    /// @dev The collateral too: borrowing needs no setOperator transaction first
    function test_authorize_collateralForABorrow() public {
        (address borrower, uint256 key) = makeAddrAndKey("borrower");
        uint256 pid = _open(borrower, L);
        (uint8 v, bytes32 r, bytes32 s) = _operatorSig(key, collateral, address(senzuRouter), block.timestamp);
        RouterPlan.Plan memory p;
        p = p.authorize(false, block.timestamp, v, r, s);
        p = p.borrow(pid, address(usdc), 1_000e6);
        vm.prank(borrower);
        senzuRouter.execute(p.actions, p.params, block.timestamp, false);
        assertEq(usdc.balanceOf(borrower), 1_000e6);
    }

    /// @dev A signature submitted while the router already is an operator is still spent: it can't bring the router
    ///      back after the user revokes it
    function test_authorize_spendsTheSignatureWhenAlreadyAnOperator() public {
        (address lender, uint256 key) = _lendWeth();
        vm.prank(lender);
        borrowable.setOperator(address(senzuRouter), true);
        (uint8 v, bytes32 r, bytes32 s) = _operatorSig(key, borrowable, address(senzuRouter), block.timestamp);
        RouterPlan.Plan memory p;
        p = p.authorize(true, block.timestamp, v, r, s);
        _run(lender, p);
        assertEq(borrowable.nonces(lender), 1, "spent");

        vm.prank(lender);
        borrowable.setOperator(address(senzuRouter), false);
        vm.expectRevert(ISenzuERC6909.ERC6909__InvalidSignature.selector);
        borrowable.setOperatorBySig(lender, address(senzuRouter), true, block.timestamp, v, r, s);
    }

    /*  ================================================
                           OPEN_EXACT
        ================================================  */

    function _exactData(uint160 sqrtPaX96, uint160 sqrtPbX96, uint128 liquidity) internal view returns (bytes memory) {
        return abi.encode(address(weth), address(usdc), sqrtPaX96, sqrtPbX96, liquidity);
    }

    /// @dev Each token from the router's balance first, then the wallet (ALL: all it has), then borrowed against the
    ///      new position: exactly what the mint takes, nothing left over
    function test_openExact_paysFromHeldThenWalletThenBorrow() public {
        bytes memory data = _exactData(TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, 1e15);
        (,, uint256 q0, uint256 q1) = adapter.quoteDeposit(data);
        assertGt(q0, 0);
        assertGt(q1, 0);
        uint256 held = q0 / 2;
        uint256 inWallet = q0 / 4;
        uint256 borrowed = q0 - held - inWallet;
        weth.mint(ALICE, held + inWallet);
        usdc.mint(ALICE, q1);
        uint256 newId = collateral.nextPositionId();
        uint256 adapter0 = weth.balanceOf(address(adapter));
        uint256 adapter1 = usdc.balanceOf(address(adapter));

        RouterPlan.Plan memory p;
        p = p.pull(address(weth), held);
        p = p.openExact(data, ALL, q1, borrowed, 0);
        _run(ALICE, p);

        assertEq(weth.balanceOf(address(adapter)) - adapter0, q0, "exactly the mint's token0");
        assertEq(usdc.balanceOf(address(adapter)) - adapter1, q1, "exactly the mint's token1");
        assertEq(weth.balanceOf(ALICE), 0, "the whole wallet, as ALL says");
        assertEq(usdc.balanceOf(ALICE), 0);
        assertGe(borrowable.debtOf(ALICE, newId, address(weth)), borrowed, "the rest borrowed");
        assertEq(collateral.balanceOf(ALICE, newId), 1e15);
        _assertRouterEmpty();
    }

    function test_openExact_borrowsAtMostMaxBorrow() public {
        bytes memory data = _exactData(TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, 1e15);
        (,, uint256 q0, uint256 q1) = adapter.quoteDeposit(data);
        usdc.mint(ALICE, q1);
        RouterPlan.Plan memory p;
        p = p.openExact(data, 0, q1, q0 - 1, 0);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(ISenzuRouter.SenzuRouter__ExcessiveInput.selector, address(weth), q0, q0 - 1)
        );
        senzuRouter.execute(p.actions, p.params, block.timestamp, false);
    }

    /// @dev A range above the price takes only token0: token1 needs nothing, and nothing is left in the router
    function test_openExact_oneSided() public {
        uint160 price = adapter.poolSqrtPrice();
        bytes memory data = _exactData(price * 11 / 10, price * 12 / 10, 1e15);
        (,, uint256 q0, uint256 q1) = adapter.quoteDeposit(data);
        assertGt(q0, 0);
        assertEq(q1, 0);
        weth.mint(ALICE, q0);
        uint256 newId = collateral.nextPositionId();
        RouterPlan.Plan memory p;
        _run(ALICE, p.openExact(data, q0, 0, 0, 0));
        assertEq(collateral.balanceOf(ALICE, newId), 1e15);
        assertEq(weth.balanceOf(ALICE), 0);
        _assertRouterEmpty();
    }

    function test_openExact_needsAnExactLiquidity() public {
        RouterPlan.Plan memory p;
        p = p.openExact(_exactData(TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, 0), 0, 0, 0, 0);
        vm.prank(ALICE);
        vm.expectRevert();
        senzuRouter.execute(p.actions, p.params, block.timestamp, false);
    }
}
