// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISenzuCore} from "../src/interfaces/ISenzuCore.sol";
import {ISenzuFactory} from "../src/interfaces/ISenzuFactory.sol";
import {MarketLogic} from "../src/libraries/MarketLogic.sol";
import {Market, lenderId} from "../src/libraries/Types.sol";
import {SenzuFactory} from "../src/modules/SenzuFactory.sol";
import {SenzuOracle} from "../src/modules/SenzuOracle.sol";
import {SenzuRiskConfig} from "../src/modules/SenzuRiskConfig.sol";
import {BorrowableDeployer} from "../src/modules/deployers/BorrowableDeployer.sol";
import {CollateralDeployer} from "../src/modules/deployers/CollateralDeployer.sol";
import {MockAdapter, MockAggregator, MockERC20} from "./mocks/Mocks.sol";
import {Test} from "forge-std/Test.sol";
import {SenzuBorrowable} from "src/core/SenzuBorrowable.sol";
import {SenzuCollateral} from "src/core/SenzuCollateral.sol";
import {ISenzuBorrowable} from "src/interfaces/ISenzuBorrowable.sol";

contract HubMarketsTest is Test {
    address constant DAO = address(0xDA0);
    address constant GUARDIAN = address(0x6A6D);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    SenzuFactory factory;
    SenzuOracle oracle;
    SenzuRiskConfig riskConfig;
    SenzuBorrowable borrowable;
    SenzuCollateral collateral;
    MockERC20 usdc;
    uint256 usdcId;

    function setUp() public {
        vm.warp(1_000_000);
        factory = new SenzuFactory(
            address(this), GUARDIAN, DAO, address(new BorrowableDeployer()), address(new CollateralDeployer())
        );
        oracle = SenzuOracle(factory.oracle());
        ISenzuFactory.Deployment memory set =
            factory.deploy("Test", address(new MockAdapter(factory.collateralAddress("Test"))));
        riskConfig = SenzuRiskConfig(factory.riskConfig());
        borrowable = SenzuBorrowable(set.borrowable);
        collateral = SenzuCollateral(set.collateral);
        usdc = new MockERC20("USDC", 6);
        oracle.addFeed(address(usdc), address(new MockAggregator(8, 1e8)), 1 days);
        borrowable.createMarket(address(usdc), 0.1e18);
        usdcId = lenderId(address(usdc));

        usdc.mint(ALICE, 1_000_000e6);
        usdc.mint(BOB, 1_000_000e6);
        vm.prank(ALICE);
        usdc.approve(address(borrowable), type(uint256).max);
        vm.prank(BOB);
        usdc.approve(address(borrowable), type(uint256).max);
    }

    function _supply(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        shares = borrowable.supply(address(usdc), assets, who);
    }

    /*  ================================================
                          createMarket
        ================================================  */

    function test_factory_needsBothDeployers() public {
        address borrowableDeployer = address(new BorrowableDeployer());
        address collateralDeployer = address(new CollateralDeployer());
        vm.expectRevert(ISenzuFactory.SenzuFactory__ZeroAddress.selector);
        new SenzuFactory(address(this), GUARDIAN, DAO, borrowableDeployer, address(0));
        vm.expectRevert(ISenzuFactory.SenzuFactory__ZeroAddress.selector);
        new SenzuFactory(address(this), GUARDIAN, DAO, address(0), collateralDeployer);
    }

    function test_createMarket_stored() public view {
        Market memory m = borrowable.getMarket(address(usdc));
        assertTrue(m.exists);
        assertEq(m.index, 0);
        assertEq(m.rateAtTarget, MarketLogic.INITIAL_RATE_AT_TARGET, "every market starts at an 8% rate at target");
        assertEq(m.reserveFactorWad, 0.1e18);
        assertEq(borrowable.marketsLength(), 1);
        assertEq(borrowable.marketAt(0), address(usdc));
    }

    function test_createMarket_onlyAdmin() public {
        MockERC20 weth = new MockERC20("WETH", 18);
        vm.prank(ALICE);
        vm.expectRevert(ISenzuCore.SenzuCore__NotAdmin.selector);
        borrowable.createMarket(address(weth), 0);
    }

    function test_createMarket_needsOracleFeed() public {
        MockERC20 weth = new MockERC20("WETH", 18);
        vm.expectRevert(abi.encodeWithSelector(ISenzuBorrowable.SenzuBorrowable__NoOracleFeed.selector, address(weth)));
        borrowable.createMarket(address(weth), 0);
    }

    function test_createMarket_noDuplicates() public {
        vm.expectRevert(
            abi.encodeWithSelector(ISenzuBorrowable.SenzuBorrowable__MarketAlreadyExists.selector, address(usdc))
        );
        borrowable.createMarket(address(usdc), 0);
    }

    function test_createMarket_reserveFactorCap() public {
        MockERC20 weth = new MockERC20("WETH", 18);
        oracle.addFeed(address(weth), address(new MockAggregator(8, 2000e8)), 1 days);
        vm.expectRevert(ISenzuBorrowable.SenzuBorrowable__InvalidReserveFactor.selector);
        borrowable.createMarket(address(weth), 0.5e18 + 1);
        borrowable.createMarket(address(weth), 0.5e18);
    }

    /// @dev A position's debt lane keeps its market's index in 8 bits, so the 257th market is refused
    function test_createMarket_atMost256() public {
        address feed = address(new MockAggregator(8, 1e8));
        for (uint256 i = borrowable.marketsLength(); i < 256; ++i) {
            address token = address(new MockERC20("T", 18));
            oracle.addFeed(token, feed, 1 days);
            borrowable.createMarket(token, 0);
        }
        assertEq(borrowable.getMarket(borrowable.marketAt(255)).index, 255);

        address extra = address(new MockERC20("T", 18));
        oracle.addFeed(extra, feed, 1 days);
        vm.expectRevert(ISenzuBorrowable.SenzuBorrowable__TooManyMarkets.selector);
        borrowable.createMarket(extra, 0);
    }

    function test_setReserveFactor_adminOnlyAndAtMost20Percent() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(ISenzuCore.SenzuCore__NotAdmin.selector);
        borrowable.setReserveFactor(address(usdc), 0.05e18);

        vm.expectRevert(ISenzuBorrowable.SenzuBorrowable__InvalidReserveFactor.selector);
        borrowable.setReserveFactor(address(usdc), 0.5e18 + 1);

        // Both ways within the ceiling
        borrowable.setReserveFactor(address(usdc), 0.5e18);
        assertEq(borrowable.getMarket(address(usdc)).reserveFactorWad, 0.5e18);
        borrowable.setReserveFactor(address(usdc), 0);
        assertEq(borrowable.getMarket(address(usdc)).reserveFactorWad, 0);

        vm.expectRevert(
            abi.encodeWithSelector(ISenzuBorrowable.SenzuBorrowable__MarketNotFound.selector, address(0x1234))
        );
        borrowable.setReserveFactor(address(0x1234), 0);
    }

    /*  ================================================
                       supply / withdraw
        ================================================  */

    function test_supply_mintsShares() public {
        uint256 shares = _supply(ALICE, 1_000e6);
        assertEq(borrowable.balanceOf(ALICE, usdcId), shares);
        assertEq(borrowable.totalSupply(usdcId), shares);
        assertEq(usdc.balanceOf(address(borrowable)), 1_000e6);
        assertEq(borrowable.getMarket(address(usdc)).totalSupplyAssets, 1_000e6);
        assertApproxEqAbs(borrowable.convertToAssets(address(usdc), shares), 1_000e6, 1);
    }

    function test_supplyThenWithdraw_roundTrip() public {
        uint256 shares = _supply(ALICE, 1_000e6);
        uint256 before = usdc.balanceOf(ALICE);

        vm.prank(ALICE);
        uint256 assets = borrowable.withdraw(address(usdc), shares, ALICE, ALICE);

        assertApproxEqAbs(assets, 1_000e6, 1);
        assertEq(usdc.balanceOf(ALICE), before + assets);
        assertEq(borrowable.balanceOf(ALICE, usdcId), 0);
    }

    function test_supply_zeroReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(ISenzuBorrowable.SenzuBorrowable__ZeroAmount.selector);
        borrowable.supply(address(usdc), 0, ALICE);
    }

    function test_supply_unknownMarketReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(ISenzuBorrowable.SenzuBorrowable__MarketNotFound.selector, address(0x1234))
        );
        borrowable.supply(address(0x1234), 1, ALICE);
    }

    function test_withdraw_byOtherNeedsAllowance() public {
        uint256 shares = _supply(ALICE, 1_000e6);

        vm.prank(BOB);
        vm.expectRevert(); // allowance underflow
        borrowable.withdraw(address(usdc), shares, BOB, ALICE);

        vm.prank(ALICE);
        borrowable.approve(BOB, usdcId, shares);
        vm.prank(BOB);
        borrowable.withdraw(address(usdc), shares, BOB, ALICE);
        assertEq(borrowable.balanceOf(ALICE, usdcId), 0);
        assertEq(borrowable.allowance(ALICE, BOB, usdcId), 0);
    }

    function test_withdraw_byOperator() public {
        uint256 shares = _supply(ALICE, 1_000e6);
        vm.prank(ALICE);
        borrowable.setOperator(BOB, true);
        vm.prank(BOB);
        borrowable.withdraw(address(usdc), shares, BOB, ALICE);
        assertEq(borrowable.balanceOf(ALICE, usdcId), 0);
    }

    function test_lenderShares_transferFreely() public {
        uint256 shares = _supply(ALICE, 1_000e6);
        vm.prank(ALICE);
        borrowable.transfer(BOB, usdcId, shares);
        assertEq(borrowable.balanceOf(BOB, usdcId), shares);
    }

    function test_supply_pausable_withdrawIsNot() public {
        uint256 shares = _supply(ALICE, 1_000e6);
        vm.mockCall(address(riskConfig), abi.encodeWithSelector(riskConfig.isPaused.selector), abi.encode(true));

        vm.prank(BOB);
        vm.expectRevert(); // Paused
        borrowable.supply(address(usdc), 1_000e6, BOB);

        vm.prank(ALICE);
        borrowable.withdraw(address(usdc), shares, ALICE, ALICE);
    }

    function test_donationDoesNotChangeShareValue() public {
        uint256 shares = _supply(ALICE, 1_000e6);
        usdc.mint(address(borrowable), 1_000_000e6); // someone sends tokens directly
        assertApproxEqAbs(borrowable.convertToAssets(address(usdc), shares), 1_000e6, 1);
    }

    function testFuzz_twoLenders_noValueFromNothing(uint256 a, uint256 b) public {
        a = bound(a, 1, 1_000_000e6);
        b = bound(b, 1, 1_000_000e6);
        uint256 sharesA = _supply(ALICE, a);
        uint256 sharesB = _supply(BOB, b);

        vm.prank(ALICE);
        uint256 outA = borrowable.withdraw(address(usdc), sharesA, ALICE, ALICE);
        vm.prank(BOB);
        uint256 outB = borrowable.withdraw(address(usdc), sharesB, BOB, BOB);

        assertLe(outA, a);
        assertLe(outB, b);
        assertLe(outA + outB, a + b);
    }

    /*  ================================================
                             views
        ================================================  */

    function test_marketState_noBorrows() public {
        _supply(ALICE, 1_000e6);
        (
            uint256 supplyAssets,
            uint256 borrowAssets,
            uint256 util,
            uint256 borrowRate,
            uint256 supplyRate,
            uint256 rateAtTarget
        ) = borrowable.marketState(address(usdc));
        assertEq(supplyAssets, 1_000e6);
        assertEq(borrowAssets, 0);
        assertEq(util, 0);
        assertEq(rateAtTarget, MarketLogic.INITIAL_RATE_AT_TARGET);
        assertEq(borrowRate, rateAtTarget / 4, "0% utilization: a quarter of the rate at target");
        assertEq(supplyRate, 0);
    }

    function test_maxWithdraw() public {
        _supply(ALICE, 1_000e6);
        assertApproxEqAbs(borrowable.maxWithdraw(address(usdc), ALICE), 1_000e6, 1);
        assertEq(borrowable.maxWithdraw(address(usdc), BOB), 0);
    }

    /*  ================================================
                       unsupported tokens
        ================================================  */

    function test_feeOnTransfer_supplyReverts() public {
        usdc.setTransferFee(10); // 0.1%
        usdc.mint(ALICE, 1_000e6);
        vm.startPrank(ALICE);
        usdc.approve(address(borrowable), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(ISenzuBorrowable.SenzuBorrowable__UnsupportedToken.selector, address(usdc))
        );
        borrowable.supply(address(usdc), 1_000e6, ALICE);
        vm.stopPrank();
    }
}
