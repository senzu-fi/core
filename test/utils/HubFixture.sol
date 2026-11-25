// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SenzuBorrowable} from "../../src/core/SenzuBorrowable.sol";
import {SenzuCollateral} from "../../src/core/SenzuCollateral.sol";
import {ISenzuFactory} from "../../src/interfaces/ISenzuFactory.sol";
import {HealthMath} from "../../src/libraries/HealthMath.sol";
import {SenzuFactory} from "../../src/modules/SenzuFactory.sol";
import {SenzuOracle} from "../../src/modules/SenzuOracle.sol";
import {SenzuRiskConfig} from "../../src/modules/SenzuRiskConfig.sol";
import {BorrowableDeployer} from "../../src/modules/deployers/BorrowableDeployer.sol";
import {CollateralDeployer} from "../../src/modules/deployers/CollateralDeployer.sol";
import {MockAdapter, MockAggregator, MockERC20, MockLockRouter} from "../mocks/Mocks.sol";
import {lockLiquidator} from "./LockLiquidator.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Test} from "forge-std/Test.sol";

/// @dev WETH/USDC markets, a mock adapter, Bob lending and Alice holding a full-range position `id`
abstract contract HubFixture is Test {
    address constant DAO = address(0xDA0);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA201);
    uint128 constant L = 1e14; // full-range WETH/USDC worth about $8.9k at $2000

    SenzuFactory factory;
    SenzuOracle oracle;
    SenzuRiskConfig riskConfig;
    SenzuBorrowable borrowable;
    SenzuCollateral collateral;
    MockAdapter adapter;
    MockLockRouter router;
    MockERC20 weth;
    MockERC20 usdc;
    MockAggregator ethFeed;
    bytes32 pairKey;
    uint256 id; // Alice's position

    function setUp() public virtual {
        vm.warp(1_000_000);
        factory = new SenzuFactory(
            address(this), address(0x6A6D), DAO, address(new BorrowableDeployer()), address(new CollateralDeployer())
        );
        oracle = SenzuOracle(factory.oracle());
        ISenzuFactory.Deployment memory d =
            factory.deploy("Uniswap", address(new MockAdapter(factory.collateralAddress("Uniswap"))));
        riskConfig = SenzuRiskConfig(factory.riskConfig());
        borrowable = SenzuBorrowable(d.borrowable);
        collateral = SenzuCollateral(d.collateral);
        adapter = MockAdapter(d.adapter);

        weth = new MockERC20("WETH", 18);
        usdc = new MockERC20("USDC", 6);
        ethFeed = new MockAggregator(8, 2000e8);
        oracle.addFeed(address(weth), address(ethFeed), 1 days);
        oracle.addFeed(address(usdc), address(new MockAggregator(8, 1e8)), 1 days);

        borrowable.createMarket(address(usdc), 0.1e18);
        borrowable.createMarket(address(weth), 0.1e18);

        adapter.setPoolSqrtPrice(HealthMath.sqrtPriceX96FromUsd(2000e18, 1e18, 18, 6));

        riskConfig.setTokenRisk(address(adapter), address(weth), 1.15e18, 1.05e18, true);
        riskConfig.setLiquid(address(adapter), address(weth));
        riskConfig.setTokenRisk(address(adapter), address(usdc), 1.02e18, 1.05e18, true);
        riskConfig.setLiquid(address(adapter), address(usdc));
        pairKey = keccak256(abi.encode(address(adapter), address(weth), address(usdc)));
        riskConfig.setPairEnabled(address(adapter), address(weth), address(usdc), true);

        // Bob lends
        usdc.mint(BOB, 2_000_000e6);
        weth.mint(BOB, 1_000e18);
        vm.startPrank(BOB);
        usdc.approve(address(borrowable), type(uint256).max);
        weth.approve(address(borrowable), type(uint256).max);
        borrowable.supply(address(usdc), 1_000_000e6, BOB);
        borrowable.supply(address(weth), 1_000e18, BOB);
        vm.stopPrank();

        // Alice opens a full-range WETH/USDC position
        id = _open(ALICE, L);

        router = new MockLockRouter(address(collateral));
        vm.prank(ALICE);
        collateral.setOperator(address(router), true);
    }

    /*  ================================================
                            Helpers
        ================================================  */

    function _open(address who, uint128 liquidity) internal returns (uint256 newId) {
        bytes memory data =
            abi.encode(address(weth), address(usdc), TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, liquidity);
        vm.prank(who);
        (newId,,,,,) = collateral.open(who, who, data);
    }

    function _collateralUsd() internal view returns (uint256) {
        return collateral.health(ALICE, id).collateralUsdWad;
    }

    /// @dev USDC amount worth `fraction` of Alice's collateral
    function _usdcFor(uint256 fraction) internal view returns (uint256) {
        return _collateralUsd() * fraction / 1e18 / 1e12;
    }

    function _borrow(address who, address asset, uint256 amount) internal {
        vm.prank(who);
        collateral.borrow(who, id, asset, amount, who);
    }

    /**
     *  @dev A second holder of Alice's position: units don't transfer, so a liquidation is how they change hands. Alice
     *       borrows 80% of her collateral in USDC, ETH drops 20%, `liquidator` repays a quarter of the debt and gets
     *       units, and the price comes back. Alice keeps the rest of the debt
     */
    function _liquidatePart(address liquidator) internal returns (uint256 seized, uint256 debtLeft) {
        uint256 debt = _usdcFor(0.8e18);
        _borrow(ALICE, address(usdc), debt);
        ethFeed.set(1600e8, block.timestamp);
        usdc.mint(liquidator, debt);
        vm.startPrank(liquidator);
        usdc.approve(address(borrowable), type(uint256).max);
        (seized,) = lockLiquidator().liquidate(collateral, ALICE, id, address(usdc), debt / 4, liquidator);
        vm.stopPrank();
        ethFeed.set(2000e8, block.timestamp);
        debtLeft = borrowable.debtOf(ALICE, id, address(usdc));
    }

    function _assertSupplyMatchesAdapter(uint256 positionId) internal view {
        uint256 lpId = positionId;
        assertEq(collateral.totalSupply(positionId), adapter.shape(lpId).liquidity, "totalSupply != adapter liquidity");
    }
}
