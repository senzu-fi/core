// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SenzuBorrowable} from "../src/core/SenzuBorrowable.sol";
import {SenzuCollateral} from "../src/core/SenzuCollateral.sol";
import {ISenzuAdapter} from "../src/interfaces/ISenzuAdapter.sol";
import {ISenzuCollateral} from "../src/interfaces/ISenzuCollateral.sol";
import {ISenzuFactory} from "../src/interfaces/ISenzuFactory.sol";
import {HealthMath} from "../src/libraries/HealthMath.sol";
import {lenderId} from "../src/libraries/Types.sol";
import {SenzuFactory} from "../src/modules/SenzuFactory.sol";
import {SenzuOracle} from "../src/modules/SenzuOracle.sol";
import {SenzuRiskConfig} from "../src/modules/SenzuRiskConfig.sol";
import {BorrowableDeployer} from "../src/modules/deployers/BorrowableDeployer.sol";
import {CollateralDeployer} from "../src/modules/deployers/CollateralDeployer.sol";
import {MockAdapter, MockAggregator, MockERC20} from "./mocks/Mocks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The point of one deployment per DEX: a broken or malicious adapter on one DEX can drain that DEX's
///         lenders, and nothing else.
contract IsolationTest is Test {
    address constant ATTACKER = address(0xBAD);
    address constant UNI_LENDER = address(0x1111);
    address constant EKUBO_LENDER = address(0x2222);

    SenzuFactory factory;
    MockERC20 weth;
    MockERC20 usdc;
    ISenzuFactory.Deployment uni;
    ISenzuFactory.Deployment ekubo;

    function setUp() public {
        vm.warp(1_000_000);
        factory = new SenzuFactory(
            address(this),
            address(0x6A6D),
            address(0xDA0),
            address(new BorrowableDeployer()),
            address(new CollateralDeployer())
        );
        SenzuOracle oracle = SenzuOracle(factory.oracle());

        weth = new MockERC20("WETH", 18);
        usdc = new MockERC20("USDC", 6);
        oracle.addFeed(address(weth), address(new MockAggregator(8, 2000e8)), 1 days);
        oracle.addFeed(address(usdc), address(new MockAggregator(8, 1e8)), 1 days);

        uni = factory.deploy("Uniswap", address(new MockAdapter(factory.collateralAddress("Uniswap"))));
        ekubo = factory.deploy("Ekubo", address(new MockAdapter(factory.collateralAddress("Ekubo"))));

        _setUpDeployment(uni, UNI_LENDER);
        _setUpDeployment(ekubo, EKUBO_LENDER);
    }

    function _setUpDeployment(ISenzuFactory.Deployment memory d, address lender) internal {
        SenzuBorrowable(d.borrowable).createMarket(address(usdc), 0.1e18);
        SenzuBorrowable(d.borrowable).createMarket(address(weth), 0.1e18);
        SenzuRiskConfig risk = SenzuRiskConfig(factory.riskConfig());
        risk.setTokenRisk(d.adapter, address(weth), 1.15e18, 1.05e18, true);
        risk.setTokenRisk(d.adapter, address(usdc), 1.02e18, 1.05e18, true);

        usdc.mint(lender, 1_000_000e6);
        vm.startPrank(lender);
        usdc.approve(d.borrowable, type(uint256).max);
        SenzuBorrowable(d.borrowable).supply(address(usdc), 1_000_000e6, lender);
        vm.stopPrank();
    }

    /// @dev Lists a pair that can borrow USDC on `d`'s MockAdapter (bound at deployment)
    function _allowAdapter(ISenzuFactory.Deployment memory d) internal returns (MockAdapter adapter) {
        adapter = MockAdapter(d.adapter);
        adapter.setPoolSqrtPrice(HealthMath.sqrtPriceX96FromUsd(2000e18, 1e18, 18, 6));
        SenzuRiskConfig(factory.riskConfig()).setPairEnabled(address(adapter), address(weth), address(usdc), true);
    }

    function _lenderValue(ISenzuFactory.Deployment memory d, address lender) internal view returns (uint256) {
        SenzuBorrowable b = SenzuBorrowable(d.borrowable);
        return b.convertToAssets(address(usdc), b.balanceOf(lender, lenderId(address(usdc))));
    }

    function test_maliciousAdapterOnlyDrainsItsOwnDeployment() public {
        // Ekubo's adapter is broken: it reports liquidity that doesn't exist (MockAdapter credits any shape)
        _allowAdapter(ekubo);

        uint256 uniLenderBefore = _lenderValue(uni, UNI_LENDER);
        uint256 uniCashBefore = usdc.balanceOf(uni.borrowable);

        // The attacker opens a fake $2M+ position through it and borrows all of Ekubo's USDC
        vm.startPrank(ATTACKER);
        (uint256 id,,,,,) = SenzuCollateral(ekubo.collateral)
            .open(
                ATTACKER,
                ATTACKER,
                abi.encode(
                    address(weth), address(usdc), TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, uint128(1e17)
                )
            );
        SenzuCollateral(ekubo.collateral).borrow(ATTACKER, id, address(usdc), 1_000_000e6, ATTACKER);
        vm.stopPrank();

        assertEq(usdc.balanceOf(ATTACKER), 1_000_000e6, "Ekubo lenders were drained");
        assertEq(usdc.balanceOf(ekubo.borrowable), 0);

        // Uniswap's lenders and cash are untouched
        assertEq(usdc.balanceOf(uni.borrowable), uniCashBefore);
        assertEq(_lenderValue(uni, UNI_LENDER), uniLenderBefore);
        uint256 shares = SenzuBorrowable(uni.borrowable).balanceOf(UNI_LENDER, lenderId(address(usdc)));
        vm.prank(UNI_LENDER);
        SenzuBorrowable(uni.borrowable).withdraw(address(usdc), shares, UNI_LENDER, UNI_LENDER);
        assertApproxEqAbs(usdc.balanceOf(UNI_LENDER), 1_000_000e6, 1);
    }

    /// @dev A deployment's adapter serves only its own collateral: another deployment's collateral calling it is
    ///      refused by the adapter itself (and `open` takes no adapter, so it could never name one anyway)
    function test_adapterCantBeUsedOnAnotherDeployment() public {
        MockAdapter ekuboAdapter = _allowAdapter(ekubo);
        assertTrue(SenzuCollateral(uni.collateral).adapter() != address(ekuboAdapter));

        vm.prank(uni.collateral);
        vm.expectRevert(ISenzuAdapter.SenzuAdapter__NotCollateral.selector);
        ekuboAdapter.deposit(
            1,
            ATTACKER,
            ATTACKER,
            abi.encode(address(weth), address(usdc), TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, uint128(1e17))
        );
    }

    function test_borrowableOnlyLendsToItsOwnCollateral() public {
        // Even the Ekubo collateral contract can't borrow from Uniswap's borrowable
        vm.prank(ekubo.collateral);
        vm.expectRevert();
        SenzuBorrowable(uni.borrowable).borrow(ATTACKER, 1, address(usdc), 1e6, ATTACKER);
    }
}
