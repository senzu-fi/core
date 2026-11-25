// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {MockAggregator, MockERC20} from "./mocks/Mocks.sol";
import {HubFixture} from "./utils/HubFixture.sol";
import {lockLiquidator} from "./utils/LockLiquidator.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Gas of the health check, a borrow and a liquidation as a position's number of debts grows.
///         Each debt beyond USDC is an unrelated $1 token (its own oracle read and σ), the worst case per debt.
///         Run with `forge test --match-contract GasBenchmark -vv` to print the table.
contract GasBenchmark is HubFixture {
    uint256 constant MAX_N = 2; // a position owes at most two markets
    MockERC20[] tokens;
    address[] feeds;

    function setUp() public override {
        super.setUp();
        // Fee-free unless a test sets it: the `withFee` tests measure the protocol's liquidation fee on top
        riskConfig.setLiquidationFee(address(adapter), 0);
        for (uint256 i; i < MAX_N; ++i) {
            MockERC20 token = new MockERC20("TKN", 6);
            MockAggregator feed = new MockAggregator(8, 1e8);
            oracle.addFeed(address(token), address(feed), 1 days);
            borrowable.createMarket(address(token), 0.1e18);
            riskConfig.setTokenRisk(address(adapter), address(token), 1.05e18, 1.05e18, false);
            riskConfig.setLiquid(address(adapter), address(token));

            token.mint(BOB, 1_000e6);
            vm.startPrank(BOB);
            token.approve(address(borrowable), type(uint256).max);
            borrowable.supply(address(token), 1_000e6, BOB);
            vm.stopPrank();

            tokens.push(token);
            feeds.push(address(feed));
        }

        usdc.mint(CAROL, 1_000_000e6);
        address liq = address(lockLiquidator());
        vm.startPrank(CAROL);
        usdc.approve(address(borrowable), type(uint256).max);
        usdc.approve(liq, type(uint256).max);
        vm.stopPrank();
        vm.prank(liq);
        usdc.approve(address(borrowable), type(uint256).max);
    }

    function _netGas() internal view returns (uint256) {
        VmSafe.Gas memory g = vm.lastCallGas();
        uint256 refunded = g.gasRefunded > 0 ? uint256(uint64(g.gasRefunded)) : 0;
        uint256 cap = uint256(g.gasTotalUsed) / 5;
        return uint256(g.gasTotalUsed) - (refunded < cap ? refunded : cap);
    }

    /// @dev Alice owes `n` markets: n - 1 unrelated $20 debts and USDC up to 78% of her collateral in total
    function _openDebts(uint256 n) internal {
        uint256 others = (n - 1) * 20e6;
        for (uint256 i; i < n - 1; ++i) {
            _borrow(ALICE, address(tokens[i]), 20e6);
        }
        _borrow(ALICE, address(usdc), _usdcFor(0.78e18) - others);
    }

    /// @dev Marks everything the call reads as cold, like the first touch in a real transaction
    function _coolAll() internal {
        vm.cool(address(borrowable));
        vm.cool(address(collateral));
        vm.cool(address(oracle));
        vm.cool(address(riskConfig));
        vm.cool(address(adapter));
        vm.cool(address(factory));
        vm.cool(address(usdc));
        vm.cool(address(ethFeed));
        (address usdcFeed,,) = oracle.feedOf(address(usdc));
        vm.cool(usdcFeed);
        for (uint256 i; i < tokens.length; ++i) {
            vm.cool(address(tokens[i]));
            vm.cool(feeds[i]);
        }
    }

    function _bench(uint256 n) internal {
        _openDebts(n);

        _coolAll();
        collateral.health(ALICE, id);
        uint256 healthGas = _netGas();

        _coolAll();
        vm.prank(ALICE);
        collateral.borrow(ALICE, id, address(usdc), 1e6, ALICE);
        uint256 borrowGas = _netGas();

        ethFeed.set(1550e8, block.timestamp); // -22.5%: liquidatable at every n
        assertTrue(collateral.health(ALICE, id).minSurplusUsdWad < 0);
        _coolAll();
        vm.cool(address(lockLiquidator()));
        vm.prank(CAROL);
        lockLiquidator().liquidate(collateral, ALICE, id, address(usdc), type(uint256).max, CAROL);
        uint256 liquidateGas = _netGas();

        console2.log("debts %s | health %s | borrow %s", n, healthGas, borrowGas);
        console2.log("         | liquidate %s", liquidateGas);
    }

    /// @dev An hour after the debts were opened: one market's accrual, and the health check accruing every debt in view
    function _benchAccrued(uint256 n) internal {
        _openDebts(n);
        vm.warp(block.timestamp + 1 hours);

        _coolAll();
        collateral.health(ALICE, id);
        uint256 healthGas = _netGas();

        _coolAll();
        borrowable.accrueInterest(address(usdc));
        uint256 accrueGas = _netGas();

        console2.log("debts %s, 1h later | health %s | accrue %s", n, healthGas, accrueGas);
    }

    function test_gas_accrued01() public {
        _benchAccrued(1);
    }

    function test_gas_accrued02() public {
        _benchAccrued(2);
    }

    function test_gas_debts01() public {
        _bench(1);
    }

    function test_gas_debts02() public {
        _bench(2);
    }

    function test_gas_debts01_withFee() public {
        riskConfig.setLiquidationFee(address(adapter), 0.1e18);
        _bench(1);
    }

    function test_gas_debts02_withFee() public {
        riskConfig.setLiquidationFee(address(adapter), 0.1e18);
        _bench(2);
    }

    /// @dev A liquidation repaying the debt outside the pair, the one priced by its own feed
    function test_gas_liquidateDebtOutsideThePair() public {
        _openDebts(2);
        MockERC20 other = tokens[0];
        other.mint(CAROL, 1_000e6);
        address liq = address(lockLiquidator());
        vm.startPrank(CAROL);
        other.approve(address(borrowable), type(uint256).max);
        other.approve(liq, type(uint256).max);
        vm.stopPrank();
        vm.prank(liq);
        other.approve(address(borrowable), type(uint256).max);
        ethFeed.set(1550e8, block.timestamp);
        _coolAll();
        vm.cool(liq);
        vm.prank(CAROL);
        (uint256 seized,) = lockLiquidator().liquidate(collateral, ALICE, id, address(other), type(uint256).max, CAROL);
        uint256 liquidateGas = _netGas();
        assertGt(seized, 0);
        console2.log("debts 2 | liquidate the debt outside the pair %s", liquidateGas);
    }
}
