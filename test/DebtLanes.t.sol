// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISenzuBorrowable} from "../src/interfaces/ISenzuBorrowable.sol";
import {DebtLanes} from "../src/libraries/DebtLanes.sol";
import {DebtLane} from "../src/types/DebtLane.sol";
import {MockAggregator, MockERC20} from "./mocks/Mocks.sol";
import {HubFixture} from "./utils/HubFixture.sol";

/// @notice A position's debts packed in two lanes (DebtLanes): two debts, a third market refused, the first paid off
///         (the second moves down), borrowed again, all written off; the lanes always the first ones, nobody's shares
///         moved
contract DebtLanesTest is HubFixture {
    MockERC20[] tokens;

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 2; ++i) {
            MockERC20 token = new MockERC20("TKN", 6);
            oracle.addFeed(address(token), address(new MockAggregator(8, 1e8)), 1 days);
            borrowable.createMarket(address(token), 0.1e18);
            riskConfig.setTokenRisk(address(adapter), address(token), 1.05e18, 1.05e18, false);
            riskConfig.setLiquid(address(adapter), address(token));
            token.mint(BOB, 1_000e6);
            vm.startPrank(BOB);
            token.approve(address(borrowable), type(uint256).max);
            borrowable.supply(address(token), 1_000e6, BOB);
            vm.stopPrank();
            tokens.push(token);
        }
    }

    function _index(MockERC20 token) internal view returns (uint256) {
        return borrowable.getMarket(address(token)).index;
    }

    function _assertDebts(MockERC20[] memory expected) internal view {
        (address asset0, uint256 amount0, address asset1, uint256 amount1) = borrowable.debts(ALICE, id);
        address[2] memory assets = [asset0, asset1];
        uint256[2] memory amounts = [amount0, amount1];
        for (uint256 i; i < 2; ++i) {
            if (i >= expected.length) {
                assertEq(assets[i], address(0), "debt count");
                continue;
            }
            assertEq(assets[i], address(expected[i]), "lane order");
            assertEq(amounts[i], borrowable.debtOf(ALICE, id, assets[i]));
            assertGt(borrowable.borrowSharesOf(ALICE, id, assets[i]), 0);
        }
        assertEq(borrowable.hasDebt(ALICE, id), expected.length > 0);
    }

    function test_lanes_twoDebts_payOffTheFirst() public {
        _borrow(ALICE, address(tokens[0]), 10e6);
        _borrow(ALICE, address(tokens[1]), 20e6);
        MockERC20[] memory two = new MockERC20[](2);
        (two[0], two[1]) = (tokens[0], tokens[1]);
        _assertDebts(two);
        uint256 shares1 = borrowable.borrowSharesOf(ALICE, id, address(tokens[1]));

        // A third market doesn't fit
        vm.prank(ALICE);
        vm.expectRevert(ISenzuBorrowable.SenzuBorrowable__TooManyDebts.selector);
        collateral.borrow(ALICE, id, address(usdc), 10e6, ALICE);

        // Paying off the first moves the second into lane 0
        tokens[0].mint(ALICE, 1e6);
        vm.startPrank(ALICE);
        tokens[0].approve(address(borrowable), type(uint256).max);
        borrowable.repay(ALICE, id, address(tokens[0]), type(uint256).max);
        vm.stopPrank();
        MockERC20[] memory one = new MockERC20[](1);
        one[0] = tokens[1];
        _assertDebts(one);
        assertEq(borrowable.borrowSharesOf(ALICE, id, address(tokens[1])), shares1, "moved, not changed");
        assertEq(borrowable.borrowSharesOf(ALICE, id, address(tokens[0])), 0);

        // Now USDC fits, in the free lane
        _borrow(ALICE, address(usdc), 10e6);
        MockERC20[] memory again = new MockERC20[](2);
        (again[0], again[1]) = (tokens[1], MockERC20(address(usdc)));
        _assertDebts(again);

        // Written off, last lane first: nothing left
        vm.prank(address(collateral));
        borrowable.writeOff(ALICE, id);
        _assertDebts(new MockERC20[](0));
        assertEq(borrowable.getMarket(address(tokens[1])).totalBorrowShares, 0);
    }

    function test_lanes_addingToADebtKeepsItsLane() public {
        _borrow(ALICE, address(tokens[0]), 10e6);
        _borrow(ALICE, address(tokens[1]), 10e6);
        uint256 before = borrowable.borrowSharesOf(ALICE, id, address(tokens[0]));
        _borrow(ALICE, address(tokens[0]), 10e6);
        assertGt(borrowable.borrowSharesOf(ALICE, id, address(tokens[0])), before);
        MockERC20[] memory two = new MockERC20[](2);
        (two[0], two[1]) = (tokens[0], tokens[1]);
        _assertDebts(two);
    }

    /// @dev Market 0 (USDC) owed: an asset with no market isn't read as market 0's lane
    function test_lanes_unknownAssetOwesNothing() public {
        _borrow(ALICE, address(usdc), 10e6);
        assertEq(_index(MockERC20(address(usdc))), 0);
        assertEq(borrowable.borrowSharesOf(ALICE, id, address(0xBEEF)), 0);
        assertEq(borrowable.debtOf(ALICE, id, address(0xBEEF)), 0);
    }

    function laneOf(uint8 index, uint256 shares) external pure returns (uint256) {
        return DebtLane.unwrap(DebtLanes.lane(index, shares));
    }

    function test_lanes_sharesPast119BitsRevert() public {
        assertEq(this.laneOf(7, (1 << 119) - 1) >> 8, (1 << 119) - 1);
        vm.expectRevert(ISenzuBorrowable.SenzuBorrowable__DebtTooLarge.selector);
        this.laneOf(7, 1 << 119);
    }

    /// @dev Random adds and subs over 6 markets against a plain model: same shares, lanes contiguous, lane 1 empty
    ///      unless two markets are owed
    function testFuzz_lanes_matchAModel(uint256[] memory ops) public {
        LanesHarness h = new LanesHarness();
        uint256[6] memory model;
        uint256 n = ops.length > 64 ? 64 : ops.length;
        for (uint256 k; k < n; ++k) {
            uint8 idx = uint8(ops[k] % 6);
            uint256 amount = (ops[k] >> 8) % 1e6 + 1;
            uint256 count = _modelCount(model);
            if ((ops[k] >> 40) % 3 != 0) {
                if (model[idx] == 0 && count == 2) {
                    vm.expectRevert(ISenzuBorrowable.SenzuBorrowable__TooManyDebts.selector);
                    h.add(idx, amount);
                } else {
                    h.add(idx, amount);
                    model[idx] += amount;
                }
            } else if (model[idx] == 0) {
                vm.expectRevert(ISenzuBorrowable.SenzuBorrowable__NoDebt.selector);
                h.sub(idx, 1);
            } else {
                uint256 taken = (ops[k] >> 48) % 2 == 0 ? model[idx] : (amount % model[idx]) + 1;
                h.sub(idx, taken);
                model[idx] -= taken;
            }
            _assertMatches(h, model);
        }
    }

    function _modelCount(uint256[6] memory model) internal pure returns (uint256 c) {
        for (uint256 i; i < 6; ++i) {
            if (model[i] != 0) ++c;
        }
    }

    function _assertMatches(LanesHarness h, uint256[6] memory model) internal view {
        uint256 count = _modelCount(model);
        DebtLane[] memory lanes = h.lanes();
        assertEq(lanes.length, count, "count");
        assertEq(h.hasDebt(), count > 0, "hasDebt");
        for (uint256 i; i < lanes.length; ++i) {
            assertEq(lanes[i].shares(), model[lanes[i].marketIndex()], "shares");
        }
        for (uint8 idx; idx < 6; ++idx) {
            assertEq(h.sharesOf(idx), model[idx], "sharesOf");
        }
        if (count < 2) assertEq(h.raw() >> 128, 0, "lane 1 empty");
    }
}

contract LanesHarness {
    uint256 internal d;

    function add(uint8 idx, uint256 amount) external {
        d = DebtLanes.add(d, idx, amount);
    }

    function sub(uint8 idx, uint256 amount) external {
        d = DebtLanes.sub(d, idx, amount);
    }

    function sharesOf(uint8 idx) external view returns (uint256) {
        return DebtLanes.sharesOf(d, idx);
    }

    function lanes() external view returns (DebtLane[] memory) {
        return DebtLanes.lanes(d);
    }

    function hasDebt() external view returns (bool) {
        return DebtLanes.hasDebt(d);
    }

    function raw() external view returns (uint256) {
        return d;
    }
}
