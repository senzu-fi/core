// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISenzuAdapter} from "../src/interfaces/ISenzuAdapter.sol";
import {ISenzuCore} from "../src/interfaces/ISenzuCore.sol";
import {ISenzuERC6909} from "../src/interfaces/ISenzuERC6909.sol";
import {IMockHook} from "./mocks/Mocks.sol";
import {HubFixture} from "./utils/HubFixture.sol";
import {lockLiquidator} from "./utils/LockLiquidator.sol";
import {ERC6909} from "@openzeppelin/contracts/token/ERC6909/ERC6909.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ISenzuCollateral} from "src/interfaces/ISenzuCollateral.sol";
import {ISenzuLockCallback} from "src/interfaces/ISenzuLockCallback.sol";
import {lenderId} from "src/libraries/Types.sol";

/// @dev Plays a DEX hook: when MockAdapter changes liquidity it runs one armed call and records what happened
contract ReentryHook is IMockHook, ISenzuLockCallback {
    address internal target;
    bytes internal data;
    bool internal armed;
    bool public ran;
    bool public passed;
    bytes4 public errorSelector;

    function arm(address target_, bytes calldata data_) external {
        (target, data, armed) = (target_, data_, true);
    }

    function onModify() external {
        if (!armed) return;
        armed = false;
        ran = true;
        (bool ok, bytes memory ret) = target.call(data);
        passed = ok;
        if (!ok && ret.length >= 4) errorSelector = bytes4(ret);
    }

    /// @dev A lock started from the hook would call back here
    function senzuLockAcquired(bytes calldata) external pure returns (bytes memory) {
        return "";
    }
}

/// @notice Signed operators, leaving a position, holder-only adds, and units never moving mid-call
contract HubPositionsTest is HubFixture {
    address constant EVE = address(0xE7E);
    bytes32 constant SET_OPERATOR_TYPEHASH =
        keccak256("SetOperator(address owner,address operator,bool approved,uint256 nonce,uint256 deadline)");

    function _sign(uint256 key, address owner, address operator, bool approved, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        return _signFor(ISenzuERC6909(address(collateral)), key, owner, operator, approved, nonce, deadline);
    }

    function _signFor(
        ISenzuERC6909 token,
        uint256 key,
        address owner,
        address operator,
        bool approved,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(abi.encode(SET_OPERATOR_TYPEHASH, owner, operator, approved, nonce, deadline));
        return vm.sign(key, keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)));
    }

    /*  ================================================
                        setOperatorBySig
        ================================================  */

    function test_setOperatorBySig() public {
        (address owner, uint256 key) = makeAddrAndKey("owner");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(key, owner, address(router), true, 0, deadline);

        collateral.setOperatorBySig(owner, address(router), true, deadline, v, r, s); // anyone can submit it
        assertTrue(collateral.isOperator(owner, address(router)));
        assertEq(collateral.nonces(owner), 1);

        // Replay fails: the nonce moved
        vm.expectRevert(ISenzuERC6909.ERC6909__InvalidSignature.selector);
        collateral.setOperatorBySig(owner, address(router), true, deadline, v, r, s);
    }

    function test_setOperatorBySig_expired() public {
        (address owner, uint256 key) = makeAddrAndKey("owner");
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _sign(key, owner, address(router), true, 0, deadline);
        vm.expectRevert(ISenzuERC6909.ERC6909__SignatureExpired.selector);
        collateral.setOperatorBySig(owner, address(router), true, deadline, v, r, s);
    }

    function test_setOperatorBySig_wrongSigner() public {
        (address owner,) = makeAddrAndKey("owner");
        (, uint256 otherKey) = makeAddrAndKey("other");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(otherKey, owner, address(router), true, 0, deadline);
        vm.expectRevert(ISenzuERC6909.ERC6909__InvalidSignature.selector);
        collateral.setOperatorBySig(owner, address(router), true, deadline, v, r, s);
    }

    /// @dev Lender shares take the same signature, under the borrowable's own domain: a lender signs once for the
    ///      router, and a signature for one contract is useless on the other
    function test_setOperatorBySig_onLenderShares() public {
        (address owner, uint256 key) = makeAddrAndKey("owner");
        uint256 deadline = block.timestamp + 1 hours;
        assertTrue(borrowable.DOMAIN_SEPARATOR() != collateral.DOMAIN_SEPARATOR());

        (uint8 v, bytes32 r, bytes32 s) = _sign(key, owner, address(router), true, 0, deadline);
        vm.expectRevert(ISenzuERC6909.ERC6909__InvalidSignature.selector);
        borrowable.setOperatorBySig(owner, address(router), true, deadline, v, r, s);

        (v, r, s) = _signFor(ISenzuERC6909(address(borrowable)), key, owner, address(router), true, 0, deadline);
        borrowable.setOperatorBySig(owner, address(router), true, deadline, v, r, s);
        assertTrue(borrowable.isOperator(owner, address(router)));
        assertEq(borrowable.nonces(owner), 1);
        assertEq(collateral.nonces(owner), 0);
    }

    /*  ================================================
                            leaving
        ================================================  */

    /// @dev There's no unwrap (removed 2026-10-15): a position is left by redeeming every unit, and every redeem
    ///      pays the account's fees with its tokens, so nothing is left behind by closing without collecting
    function test_fees_paidWithEveryRedeem() public {
        uint256 lpId = id;
        // Carol gets units in a liquidation and holds them while 2 WETH of fees accrue, then redeems them all
        (uint256 carol, uint256 debtLeft) = _liquidatePart(CAROL);
        uint256 alice = collateral.balanceOf(ALICE, id);
        adapter.accrueFees(lpId, 2e18, 0);
        (uint256 carolOwed,) = adapter.feesOwed(CAROL, id);
        assertApproxEqAbs(carolOwed, 2e18 * carol / L, 1e6, "the liquidator's share");
        // The tokens go where she says; her fees go to her, wherever that is
        address elsewhere = address(0xE15E);
        vm.expectEmit(address(adapter));
        emit ISenzuAdapter.CollectFees(CAROL, lpId, CAROL, carolOwed, 0, 0, 0);
        vm.prank(CAROL);
        collateral.redeem(CAROL, id, carol, elsewhere, "");
        assertEq(weth.balanceOf(CAROL), carolOwed, "her fees");
        (carolOwed,) = adapter.feesOwed(CAROL, id);
        assertEq(carolOwed, 0, "paid with her redeem");
        adapter.accrueFees(lpId, 1e18, 0); // all Alice's

        // Alice leaves too: she repays and redeems every unit
        usdc.mint(ALICE, debtLeft + 1e6);
        vm.startPrank(ALICE);
        usdc.approve(address(borrowable), type(uint256).max);
        borrowable.repay(ALICE, id, address(usdc), type(uint256).max);
        (uint256 aliceOwed,) = adapter.feesOwed(ALICE, id);
        assertApproxEqAbs(aliceOwed, 2e18 * alice / L + 1e18, 1e6, "both shares");
        vm.expectEmit(address(adapter));
        emit ISenzuAdapter.CollectFees(ALICE, lpId, ALICE, aliceOwed, 0, 0, 0);
        collateral.redeem(ALICE, id, alice, ALICE, "");
        vm.stopPrank();
        assertEq(collateral.totalSupply(id), 0);
        _assertSupplyMatchesAdapter(id);

        vm.prank(ALICE);
        (uint256 left0, uint256 left1) = adapter.collectFees(ALICE, id, ALICE);
        assertEq(left0 + left1, 0, "nothing left to collect");
    }

    /// @dev Fees are the adapter's: the account or its operator on the collateral collects, nobody else, and only
    ///      the collateral tells the adapter of a seize
    function test_collectFees_onlyTheAccountOrItsOperator() public {
        uint256 lpId = _open(ALICE, 1e18);
        adapter.accrueFees(lpId, 1e18, 0);

        vm.prank(BOB);
        vm.expectRevert(ISenzuAdapter.SenzuAdapter__Unauthorized.selector);
        adapter.collectFees(ALICE, lpId, BOB);

        vm.prank(BOB);
        vm.expectRevert(ISenzuAdapter.SenzuAdapter__NotCollateral.selector);
        adapter.seize(lpId, ALICE, BOB, 0, 1e18);

        vm.prank(ALICE);
        collateral.setOperator(BOB, true);
        vm.prank(BOB);
        (uint256 fee0,) = adapter.collectFees(ALICE, lpId, BOB);
        assertApproxEqAbs(fee0, 1e18, 1, "the operator collects Alice's fees");
        assertEq(weth.balanceOf(BOB), fee0);

        (fee0,) = adapter.feesOwed(ALICE, lpId);
        assertEq(fee0, 0, "nothing left");
    }

    /// @dev Audit 2026-10-05/06: only holders add. An outsider's stale fee snapshot on an emptied v3 range (its ticks
    ///      cleared by Uniswap) underflowed into every fee left in it (`test_fork_formerHolderCantRefillAnEmptiedPosition`)
    function test_increaseLiquidity_onlyForAHolder() public {
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(ISenzuCollateral.SenzuCollateral__NotAHolder.selector, BOB, id));
        collateral.increaseLiquidity(BOB, id, BOB, "");

        // Nobody holds units of an id that was never opened, so it is refused the same way
        uint256 next = collateral.nextPositionId();
        for (uint256 i; i < 2; ++i) {
            uint256 unopened = i == 0 ? 0 : next;
            vm.prank(ALICE);
            vm.expectRevert(
                abi.encodeWithSelector(ISenzuCollateral.SenzuCollateral__NotAHolder.selector, ALICE, unopened)
            );
            collateral.increaseLiquidity(ALICE, unopened, address(this), "");
        }
    }

    /*  ================================================
                        Audit 2026-10-06
        ================================================  */

    /// @dev Audit 2026-10-06 [100]: a v4 hook re-entered transferFrom while increaseLiquidity ran, when units could
    ///      move, and moved collateral valued off liquidity with no units minted yet. Units don't transfer now
    ///      (`test_unitsDontTransfer`), and a hook can't start a lock either, whose end-of-lock checks would run in
    ///      the middle of the call
    function test_noLockFromInsideACoreCall() public {
        ReentryHook hook = new ReentryHook();
        hook.arm(address(collateral), abi.encodeCall(collateral.lock, ("")));
        adapter.setHook(address(hook));
        adapter.setNextIncrease(1e12);

        vm.prank(ALICE);
        collateral.increaseLiquidity(ALICE, id, ALICE, "");
        assertTrue(hook.ran(), "hook ran");
        assertFalse(hook.passed(), "lock opened in the middle of the add");
        assertEq(hook.errorSelector(), ISenzuCore.SenzuCore__Reentrant.selector);
    }

    /// @dev Audit 2026-10-06: units never reach address(0), where no one could collect the fees they earn (and,
    ///      back then, a v3 position moved there with its debt made every liquidation of it revert)
    function test_noUnitsToAddressZero() public {
        bytes memory data =
            abi.encode(address(weth), address(usdc), TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, uint128(1e12));
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(ERC6909.ERC6909InvalidReceiver.selector, address(0)));
        collateral.open(address(0), BOB, data);

        // Nor seized units
        _borrow(ALICE, address(usdc), _usdcFor(0.8e18));
        ethFeed.set(1600e8, block.timestamp);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(ERC6909.ERC6909InvalidReceiver.selector, address(0)));
        lockLiquidator().liquidate(collateral, ALICE, id, address(usdc), type(uint256).max, address(0));
    }

    /// @dev Lender shares neither: no one can act for address 0, so they'd be lost and look burned
    function test_noLenderSharesToAddressZero() public {
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(ERC6909.ERC6909InvalidReceiver.selector, address(0)));
        borrowable.supply(address(usdc), 1e6, address(0));

        uint256 lender = lenderId(address(usdc));
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(ERC6909.ERC6909InvalidReceiver.selector, address(0)));
        borrowable.transfer(address(0), lender, 1);
    }
}
