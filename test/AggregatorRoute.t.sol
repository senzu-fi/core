// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISenzuRouter} from "../src/interfaces/ISenzuRouter.sol";
import {HostileAggregator} from "./invariant/LocalRouterHandler.sol";
import {MockERC20, MockSwapRouter, MockWETH} from "./mocks/Mocks.sol";
import {HubFixture} from "./utils/HubFixture.sol";
import {RouterPlan} from "./utils/RouterPlan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev An aggregator that does what its calldata says, well or badly
contract MockAggregator {
    /// @dev A fill: takes `amountIn` from the caller and pays `amountOut` to `to`
    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut, address to) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenOut).mint(to, amountOut);
    }

    /// @dev Pays in native ETH instead of the token
    function payEth(address tokenIn, uint256 amountIn, uint256 amountOut) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        (bool ok,) = msg.sender.call{value: amountOut}("");
        require(ok, "eth refused");
    }

    function reenter(address tokenIn, address tokenOut, uint256 amountIn) external {
        ISenzuRouter(msg.sender).swap(tokenIn, tokenOut, amountIn, 1, "");
    }

    function fail() external pure {
        revert("aggregator says no");
    }

    receive() external payable {}
}

/// @dev 0x's AllowanceHolder: `operator` may pull up to `amount` of `token` from exec's caller during the call
contract MockAllowanceHolder {
    address operator;
    address owner;
    address token;
    uint256 left;

    function exec(address operator_, address token_, uint256 amount, address payable target, bytes calldata data)
        external
        payable
        returns (bytes memory result)
    {
        (operator, owner, token, left) = (operator_, msg.sender, token_, amount);
        bool ok;
        (ok, result) = target.call(data);
        require(ok, "settler failed");
        (operator, owner, token, left) = (address(0), address(0), address(0), 0);
    }

    function transferFrom(address token_, address owner_, address recipient, uint256 amount) external returns (bool) {
        require(msg.sender == operator && owner_ == owner && token_ == token && amount <= left, "not allowed");
        left -= amount;
        return IERC20(token_).transferFrom(owner_, recipient, amount);
    }
}

contract MockSettler {
    function fill(address tokenIn, address from, uint256 amountIn, address tokenOut, uint256 amountOut) external {
        MockAllowanceHolder(msg.sender).transferFrom(tokenIn, from, address(this), amountIn);
        MockERC20(tokenOut).mint(from, amountOut);
    }
}

contract AggregatorRouteTest is HubFixture {
    using RouterPlan for RouterPlan.Plan;

    uint256 constant ALL = type(uint256).max;
    address constant KYBERSWAP = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address constant ZERO_EX = 0x0000000000001fF3684f28c67538d4D072C22734;

    MockSwapRouter senzuRouter;

    function setUp() public override {
        super.setUp();
        vm.etch(address(weth), address(new MockWETH()).code);
        senzuRouter = new MockSwapRouter(address(collateral), address(weth), address(0));
        address[] memory list = senzuRouter.aggregators();
        for (uint256 i; i < list.length; ++i) {
            if (list[i] != ZERO_EX) vm.etch(list[i], address(new MockAggregator()).code);
        }
        vm.etch(ZERO_EX, address(new MockAllowanceHolder()).code);

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
        return senzuRouter.execute(p.actions, p.params, vm.getBlockTimestamp(), false);
    }

    function _route(address aggregator, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(aggregator, data);
    }

    /// @dev A route through KyberSwap that sells `amountIn` and pays `amountOut` to the router
    function _fill(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut)
        internal
        view
        returns (bytes memory)
    {
        return _route(
            KYBERSWAP,
            abi.encodeCall(MockAggregator.swap, (tokenIn, amountIn, tokenOut, amountOut, address(senzuRouter)))
        );
    }

    /// @dev Alice sells 1,000 USDC from her wallet along `route`
    function _sell(bytes memory route, uint256 amountOutMin) internal returns (RouterPlan.Plan memory p) {
        usdc.mint(ALICE, 1_000e6);
        p = p.pull(address(usdc), 1_000e6);
        p = p.swap(address(usdc), address(weth), 1_000e6, amountOutMin, route);
    }

    function _expectSellReverts(bytes memory route, uint256 amountOutMin, bytes memory reason) internal {
        RouterPlan.Plan memory p = _sell(route, amountOutMin);
        vm.prank(ALICE);
        vm.expectRevert(reason);
        senzuRouter.execute(p.actions, p.params, vm.getBlockTimestamp(), false);
    }

    /// @dev Nothing stays in the router, and no aggregator keeps an approval
    function _assertRouterEmpty() internal view {
        assertEq(usdc.balanceOf(address(senzuRouter)), 0, "router holds USDC");
        assertEq(weth.balanceOf(address(senzuRouter)), 0, "router holds WETH");
        assertEq(address(senzuRouter).balance, 0, "router holds ETH");
        address[] memory list = senzuRouter.aggregators();
        for (uint256 i; i < list.length; ++i) {
            assertEq(usdc.allowance(address(senzuRouter), list[i]), 0, "USDC approval left");
            assertEq(weth.allowance(address(senzuRouter), list[i]), 0, "WETH approval left");
        }
    }

    /*  ================================================
                         The aggregator list
        ================================================  */

    function test_list() public view {
        address[] memory list = senzuRouter.aggregators();
        assertEq(list.length, 6);
        for (uint256 i; i < list.length; ++i) {
            assertTrue(senzuRouter.isAggregator(list[i]));
        }
        assertFalse(senzuRouter.isAggregator(address(collateral)));
        assertFalse(senzuRouter.isAggregator(address(borrowable)));
        assertFalse(senzuRouter.isAggregator(address(usdc)));
        assertFalse(senzuRouter.isAggregator(address(0)));
    }

    function test_everyAggregatorFills() public {
        address[] memory list = senzuRouter.aggregators();
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == ZERO_EX) continue;
            bytes memory route = _route(
                list[i],
                abi.encodeCall(
                    MockAggregator.swap, (address(usdc), 1_000e6, address(weth), 0.5e18, address(senzuRouter))
                )
            );
            _run(ALICE, _sell(route, 0.5e18));
            assertEq(usdc.balanceOf(list[i]), 1_000e6, "the aggregator took exactly the amount sold");
        }
        assertEq(weth.balanceOf(ALICE), 0.5e18 * (list.length - 1));
        _assertRouterEmpty();
    }

    /// @dev 0x pulls through AllowanceHolder, approved like any aggregator
    function test_zeroExFillsThroughAllowanceHolder() public {
        address settler = address(new MockSettler());
        bytes memory fill =
            abi.encodeCall(MockSettler.fill, (address(usdc), address(senzuRouter), 1_000e6, address(weth), 0.5e18));
        bytes memory exec =
            abi.encodeCall(MockAllowanceHolder.exec, (settler, address(usdc), 1_000e6, payable(settler), fill));
        _run(ALICE, _sell(_route(ZERO_EX, exec), 0.5e18));
        assertEq(weth.balanceOf(ALICE), 0.5e18);
        assertEq(usdc.balanceOf(settler), 1_000e6);
        _assertRouterEmpty();
    }

    /*  ================================================
                    Leverage through an aggregator
        ================================================  */

    function test_leverage_borrowSwapThroughAggregatorIncrease() public {
        adapter.setNextIncrease(L / 2);
        RouterPlan.Plan memory p;
        p = p.borrow(id, address(usdc), 2_000e6);
        p = p.swap(address(usdc), address(weth), 1_000e6, 0.5e18, _fill(address(usdc), 1_000e6, address(weth), 0.5e18));
        p = p.increase(id, ALL, ALL, 0, 0);
        vm.recordLogs();
        _run(ALICE, p);
        _assertNoSwapEvent();

        assertEq(collateral.balanceOf(ALICE, id), L + L / 2);
        assertEq(usdc.balanceOf(KYBERSWAP), 1_000e6, "the aggregator took exactly the amount sold");
        assertEq(senzuRouter.kept(address(usdc)), 0, "nothing went to the DEX");
        assertEq(weth.balanceOf(address(adapter)), 0.5e18);
        _assertRouterEmpty();
    }

    /// @dev What a full redeem of Alice's position pays, in USDC (before any debt, which would block it)
    function _redeemedUsdc() internal returns (uint256 got) {
        uint256 snapshot = vm.snapshotState();
        RouterPlan.Plan memory p;
        _run(ALICE, p.redeem(id, ALL, 0, 0));
        got = usdc.balanceOf(ALICE);
        vm.revertToState(snapshot);
    }

    /// @dev The aggregator sells a little more than the gap, so the DEX swap for the debt skips and the extra comes back
    function test_close_aggregatorCoversTheDebt_dexSkips() public {
        uint256 redeemed = _redeemedUsdc();
        _borrow(ALICE, address(usdc), 6_000e6);
        usdc.burn(ALICE, 6_000e6);
        assertLt(redeemed, 6_000e6, "the redeem alone doesn't cover the debt");

        RouterPlan.Plan memory p;
        p = p.redeem(id, ALL, 0, 0);
        p = p.swap(address(weth), address(usdc), 1e18, 2_000e6, _fill(address(weth), 1e18, address(usdc), 2_000e6));
        p = p.swapForDebt(id, address(usdc), address(weth), ALL, "");
        p = p.repay(id, address(usdc), ALL);
        vm.recordLogs();
        _run(ALICE, p);
        // The close's swap is part of the close
        _assertNoSwapEvent();

        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), 0);
        assertEq(senzuRouter.kept(address(weth)), 0, "the DEX wasn't used");
        assertEq(usdc.balanceOf(ALICE), redeemed + 2_000e6 - 6_000e6, "the extra USDC comes back");
        _assertRouterEmpty();
    }

    /// @dev The aggregator came up short (the price moved): the DEX buys exactly the rest
    function test_close_aggregatorShort_dexBuysTheRest() public {
        uint256 missing = 6_000e6 - _redeemedUsdc();
        _borrow(ALICE, address(usdc), 6_000e6);
        usdc.burn(ALICE, 6_000e6);
        senzuRouter.setRate(address(weth), address(usdc), 1e18, 5e8 * 1e18);

        RouterPlan.Plan memory p;
        p = p.redeem(id, ALL, 0, 0);
        p = p.swap(
            address(weth), address(usdc), 0.5e18, 1, _fill(address(weth), 0.5e18, address(usdc), missing - 100e6)
        );
        p = p.swapForDebt(id, address(usdc), address(weth), ALL, "");
        p = p.repay(id, address(usdc), ALL);
        _run(ALICE, p);

        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), 0);
        assertEq(senzuRouter.kept(address(weth)), 0.05e18, "the DEX sold only the 100 USDC gap");
        assertEq(usdc.balanceOf(ALICE), 0, "no USDC beyond the debt");
        _assertRouterEmpty();
    }

    /// @dev Spending less than approved: the rest comes back and the approval still ends at zero
    function test_partialFill_restComesBack() public {
        RouterPlan.Plan memory p = _sell(_fill(address(usdc), 600e6, address(weth), 0.3e18), 0.3e18);
        // A swap on its own: what was spent, not what was asked
        vm.expectEmit(address(senzuRouter));
        emit ISenzuRouter.Swap(ALICE, address(usdc), address(weth), 600e6, 0.3e18);
        _run(ALICE, p);
        assertEq(weth.balanceOf(ALICE), 0.3e18);
        assertEq(usdc.balanceOf(ALICE), 400e6);
        _assertRouterEmpty();
    }

    /// @dev ETH sent with a swap-only call is reported as ETH, not as the WETH it was wrapped into
    function test_swapOnly_ethIn() public {
        vm.deal(ALICE, 1e18);
        RouterPlan.Plan memory p;
        p = p.swap(address(weth), address(usdc), 1e18, 2_000e6, _fill(address(weth), 1e18, address(usdc), 2_000e6));
        vm.expectEmit(address(senzuRouter));
        emit ISenzuRouter.Swap(ALICE, address(0), address(usdc), 1e18, 2_000e6);
        vm.prank(ALICE);
        senzuRouter.execute{value: 1e18}(p.actions, p.params, vm.getBlockTimestamp(), false);
        assertEq(usdc.balanceOf(ALICE), 2_000e6);
        _assertRouterEmpty();
    }

    /// @dev WETH unwrapped on the way out (nativeOut) is reported as ETH
    function test_swapOnly_ethOut() public {
        // The mock aggregator mints WETH: back it with ETH so it can be unwrapped
        vm.deal(address(weth), 0.5e18);
        RouterPlan.Plan memory p = _sell(_fill(address(usdc), 1_000e6, address(weth), 0.5e18), 0.5e18);
        vm.expectEmit(address(senzuRouter));
        emit ISenzuRouter.Swap(ALICE, address(usdc), address(0), 1_000e6, 0.5e18);
        vm.prank(ALICE);
        senzuRouter.execute(p.actions, p.params, vm.getBlockTimestamp(), true);
        assertEq(ALICE.balance, 0.5e18);
        _assertRouterEmpty();
    }

    /// @dev The Swap tab's ETH to WETH and back: no actions wraps the ETH sent, a pull with nativeOut unwraps; no Swap
    function test_wrapAndUnwrapThroughExecute() public {
        vm.deal(ALICE, 1e18);
        RouterPlan.Plan memory none;
        vm.recordLogs();
        vm.prank(ALICE);
        senzuRouter.execute{value: 1e18}(none.actions, none.params, vm.getBlockTimestamp(), false);
        assertEq(weth.balanceOf(ALICE), 1e18);
        assertEq(ALICE.balance, 0);

        RouterPlan.Plan memory p;
        p = p.pull(address(weth), 0.4e18);
        vm.startPrank(ALICE);
        weth.approve(address(senzuRouter), 0.4e18);
        senzuRouter.execute(p.actions, p.params, vm.getBlockTimestamp(), true);
        vm.stopPrank();
        assertEq(weth.balanceOf(ALICE), 0.6e18);
        assertEq(ALICE.balance, 0.4e18);
        _assertNoSwapEvent();
        _assertRouterEmpty();
    }

    function _assertNoSwapEvent() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(senzuRouter)) {
                assertTrue(logs[i].topics[0] != ISenzuRouter.Swap.selector, "a swap inside an action emitted Swap");
            }
        }
    }

    /*  ================================================
                    swap(): the swap tab, the automator
        ================================================  */

    function test_swap_throughAnAggregatorWithAMinimum() public {
        usdc.mint(ALICE, 1_000e6);
        vm.prank(ALICE);
        uint256 out = senzuRouter.swap(
            address(usdc), address(weth), 1_000e6, 0.5e18, _fill(address(usdc), 1_000e6, address(weth), 0.5e18)
        );
        assertEq(out, 0.5e18);
        assertEq(weth.balanceOf(ALICE), 0.5e18);
        _assertRouterEmpty();
    }

    /// @dev What the aggregator didn't spend goes back to the caller, not left for the next `Pull` to sweep; the event
    ///      reports only what was sold
    function test_swap_partialFillRestComesBack() public {
        usdc.mint(ALICE, 1_000e6);
        vm.expectEmit(address(senzuRouter));
        emit ISenzuRouter.Swap(ALICE, address(usdc), address(weth), 600e6, 0.3e18);
        vm.prank(ALICE);
        senzuRouter.swap(
            address(usdc), address(weth), 1_000e6, 0.3e18, _fill(address(usdc), 600e6, address(weth), 0.3e18)
        );
        assertEq(weth.balanceOf(ALICE), 0.3e18);
        assertEq(usdc.balanceOf(ALICE), 400e6, "unspent USDC back");
        _assertRouterEmpty();
    }

    /// @dev The automator swaps with no minimum (a keeper's route): never through an aggregator
    function test_swap_refusesAnAggregatorWithoutAMinimum() public {
        usdc.mint(ALICE, 1_000e6);
        bytes memory route = _fill(address(usdc), 1_000e6, address(weth), 0.5e18);
        vm.prank(ALICE);
        vm.expectRevert(ISenzuRouter.SenzuRouter__InvalidAggregatorRoute.selector);
        senzuRouter.swap(address(usdc), address(weth), 1_000e6, 0, route);
    }

    /*  ================================================
                            Refusals
        ================================================  */

    function test_refuses_noMinimumOutput() public {
        _expectSellReverts(
            _fill(address(usdc), 1_000e6, address(weth), 0.5e18),
            0,
            abi.encodeWithSelector(ISenzuRouter.SenzuRouter__InvalidAggregatorRoute.selector)
        );
    }

    function test_refuses_buyingAnExactAmount() public {
        _borrow(ALICE, address(usdc), 3_000e6);
        RouterPlan.Plan memory p;
        p = p.redeem(id, ALL, 0, 0);
        p = p.swapForDebt(id, address(usdc), address(weth), ALL, _fill(address(weth), 1e18, address(usdc), 2_000e6));
        vm.prank(ALICE);
        vm.expectRevert(ISenzuRouter.SenzuRouter__InvalidAggregatorRoute.selector);
        senzuRouter.execute(p.actions, p.params, vm.getBlockTimestamp(), false);
    }

    /// @dev The output must reach the router: a fill paid elsewhere fails the minimum
    function test_outputPaidElsewhereFailsTheMinimum() public {
        bytes memory route = _route(
            KYBERSWAP,
            abi.encodeCall(MockAggregator.swap, (address(usdc), 1_000e6, address(weth), 0.5e18, address(0xBAD)))
        );
        _expectSellReverts(
            route,
            0.5e18,
            abi.encodeWithSelector(ISenzuRouter.SenzuRouter__InsufficientOutput.selector, address(weth), 0, 0.5e18)
        );
    }

    /// @dev Taking more than the amount sold fails: the approval is exactly the amount
    function test_takingMoreThanTheAmountFails() public {
        usdc.mint(address(senzuRouter), 5_000e6); // even with more in the router
        _expectSellReverts(
            _fill(address(usdc), 1_001e6, address(weth), 0.5e18),
            0.5e18,
            abi.encodeWithSignature("Panic(uint256)", 0x11)
        );
    }

    function test_paidInEthInsteadOfWeth_reverts() public {
        vm.deal(KYBERSWAP, 1e18);
        bytes memory route = _route(KYBERSWAP, abi.encodeCall(MockAggregator.payEth, (address(usdc), 1_000e6, 0.5e18)));
        _expectSellReverts(route, 0.5e18, bytes("eth refused"));
    }

    function test_reentering_reverts() public {
        usdc.mint(KYBERSWAP, 1e6);
        bytes memory route =
            _route(KYBERSWAP, abi.encodeCall(MockAggregator.reenter, (address(usdc), address(weth), 1e6)));
        _expectSellReverts(route, 0.5e18, abi.encodeWithSelector(ISenzuRouter.SenzuRouter__Reentrant.selector));
    }

    function test_aggregatorRevertReasonPassesThrough() public {
        _expectSellReverts(
            _route(KYBERSWAP, abi.encodeCall(MockAggregator.fail, ())), 0.5e18, bytes("aggregator says no")
        );
    }

    /// @dev A route starting with an address off the list is the DEX's own route, never called
    function test_unlistedPrefixIsADexRoute() public {
        bytes memory route =
            abi.encodePacked(address(usdc), abi.encodeCall(IERC20.transfer, (address(0xBAD), 1_000e6)), bytes12(0));
        senzuRouter.setRate(address(usdc), address(weth), 1e12, 2_000);
        _run(ALICE, _sell(route, 1));
        assertEq(usdc.balanceOf(address(0xBAD)), 0, "the token was never called");
        assertEq(senzuRouter.kept(address(usdc)), 1_000e6, "the DEX swapped");
        _assertRouterEmpty();
    }

    /// @dev A listed aggregator turned hostile, against Bob who approved the router without limit and made it his
    ///      operator: it gets only the seller's exact amount, and nothing of Bob's moves
    function test_hostileAggregatorReachesNoOtherUser() public {
        vm.etch(KYBERSWAP, address(new HostileAggregator()).code);
        uint256 bobHad = usdc.balanceOf(BOB);
        vm.startPrank(BOB);
        usdc.approve(address(senzuRouter), type(uint256).max);
        collateral.setOperator(address(senzuRouter), true);
        vm.stopPrank();

        usdc.mint(ALICE, 1_000e6);
        bytes memory route = abi.encodePacked(
            KYBERSWAP,
            abi.encodeCall(
                HostileAggregator.attack, (BOB, address(usdc), 1_000e6, address(weth), address(collateral), id)
            )
        );
        vm.prank(ALICE);
        assertEq(senzuRouter.swap(address(usdc), address(weth), 1_000e6, 1, route), 1);

        assertEq(usdc.balanceOf(BOB), bobHad, "Bob's wallet");
        assertEq(borrowable.debtOf(BOB, id, address(weth)), 0, "no debt for Bob");
        assertEq(usdc.balanceOf(KYBERSWAP), 1_000e6, "only the amount sold");
        _assertRouterEmpty();
    }
}
