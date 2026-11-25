// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISenzuPreviews} from "../../src/interfaces/ISenzuPreviews.sol";
import {MarketLogic} from "../../src/libraries/MarketLogic.sol";
import {Market, lenderId} from "../../src/libraries/Types.sol";
import {SenzuPreviews} from "../../src/periphery/SenzuPreviews.sol";
import {MockAggregator} from "../mocks/Mocks.sol";
import {HubFixture} from "../utils/HubFixture.sol";
import {HubHandler, LockScript} from "./HubHandler.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Stateful invariants: after any sequence of Hub actions, prices and time jumps, the accounting holds
contract HubInvariantTest is HubFixture {
    address constant DAVE = address(0xDA7E);
    HubHandler handler;
    address[] actors;

    function setUp() public virtual override {
        super.setUp();
        riskConfig.setBorrowFee(address(adapter), 0.001e18); // exercise the opening fee in every borrow

        actors.push(ALICE);
        actors.push(BOB);
        actors.push(CAROL);
        actors.push(DAVE);
        LockScript lockScript = new LockScript(collateral);
        lockScript.setPair(address(adapter), address(weth), address(usdc));
        actors.push(address(lockScript)); // last: the handler's lock attacker

        (address usdcFeed,,) = oracle.feedOf(address(usdc));
        handler = new HubHandler(
            borrowable, collateral, adapter, weth, usdc, ethFeed, MockAggregator(usdcFeed), DAO, actors, id
        );
        handler.setLens(ISenzuPreviews(address(new SenzuPreviews(address(collateral)))));
        targetContract(address(handler));
        // Setup, not an action: pointed at any other address, the handler's lens reads garbage
        bytes4[] memory setup = new bytes4[](1);
        setup[0] = HubHandler.setLens.selector;
        excludeSelector(FuzzSelector({addr: address(handler), selectors: setup}));
    }

    /// @dev Everyone who can hold Hub tokens: the actors and the DAO reserves
    function _holders() internal view returns (address[] memory holders) {
        holders = new address[](actors.length + 1);
        for (uint256 i; i < actors.length; ++i) {
            holders[i] = actors[i];
        }
        holders[actors.length] = DAO;
    }

    function _assets() internal view returns (address[2] memory) {
        return [address(usdc), address(weth)];
    }

    /*  ================================================
                            Coverage
        ================================================  */

    /// @notice Drives the handler through a long pseudo-random sequence and checks every action really succeeds
    ///         somewhere (a green invariant run means little if liquidations never happened), then checks the
    ///         invariants on the final state
    function test_handlerReachesEveryAction() public {
        for (uint256 i; i < 3_000; ++i) {
            uint256 r = uint256(keccak256(abi.encode(i)));
            uint256 a = r >> 8;
            uint256 b = r >> 64;
            uint256 c = r >> 128;
            uint256 d = r >> 192;
            uint256 which = r % 18;
            // Every tenth step also runs a script inside a lock, on top of the usual mix
            if (i % 10 == 0) handler.lockScript(uint256(keccak256(abi.encode("lock", i))));

            if (which == 0) {
                handler.supply(a, b, c);
            } else if (which == 1) {
                handler.withdraw(a, b, c);
            } else if (which == 2) {
                handler.open(a, b, c % 2 == 0);
            } else if (which == 3) {
                handler.increase(a, b, c);
            } else if (which == 4) {
                handler.redeem(a, b, c);
            } else if (which == 5) {
                // Units don't transfer, so the attempt changes nothing: a price move too, for liquidation windows
                handler.transfer(a, b, c, d);
                handler.setEthPrice(d);
            } else if (which == 6) {
                handler.repay(a, b, c, d, r);
            } else if (which == 7) {
                handler.setEthPrice(a); // (was unwrap) more price moves, so more liquidation windows
            } else if (which == 8) {
                handler.accrueFees(a, b, c);
            } else if (which == 9) {
                handler.collectFees(a, b);
            } else if (which == 10) {
                handler.compound(a, b, c);
            } else if (which == 11) {
                handler.borrow(a, b, c, d);
            } else if (which == 12) {
                handler.borrowToTheLimit(a, b, c);
            } else if (which == 13) {
                handler.repay(a, b, c, d, r);
            } else if (which == 14) {
                handler.liquidate(a, b, c, d, r);
            } else if (which == 15) {
                handler.resolveBadDebt(a, b);
            } else if (which == 16) {
                handler.setEthPrice(a);
            } else {
                handler.warp(a);
            }
        }

        string[17] memory names = [
            "supply",
            "withdraw",
            "open",
            "increase",
            "redeem",
            "transfer",
            "accrueFees",
            "collectFees",
            "compound",
            "borrow",
            "borrowToTheLimit",
            "repay",
            "liquidate",
            "writeOff",
            "lockScript",
            "lockFlashLiquidation",
            "lockBorrowBeforeOpen"
        ];
        for (uint256 i; i < names.length; ++i) {
            uint256 count = handler.calls(bytes32(bytes(names[i])));
            console2.log(names[i], count);
            assertGt(count, 0, string.concat("never succeeded: ", names[i]));
        }

        invariant_noBehavioralViolations();
        invariant_positionLiquidityIsConserved();
        invariant_lenderSharesAreConserved();
        invariant_debtAccountingIsConsistent();
        invariant_marketsAreBacked();
        invariant_feesOwedAreCollectable();
        invariant_lenderClaimsAreCovered();
    }

    /*  ================================================
                           Invariants
        ================================================  */

    /// @notice Nothing the handler must never see happened (healthy liquidated, unsafe borrow/redeem, units moved)
    function invariant_noBehavioralViolations() public view {
        assertEq(handler.violation(), "");
    }

    /// @notice Position liquidity: holders sum to totalSupply, which equals the adapter's liquidity
    function invariant_positionLiquidityIsConserved() public view {
        address[] memory holders = _holders();
        for (uint256 i; i < handler.idsLength(); ++i) {
            uint256 id = handler.ids(i);
            uint256 sum;
            for (uint256 h; h < holders.length; ++h) {
                sum += collateral.balanceOf(holders[h], id);
            }
            assertEq(sum, collateral.totalSupply(id), "holders != totalSupply");

            (,,,, uint128 liquidity,,,,) = adapter.positions(id);
            assertEq(collateral.totalSupply(id), liquidity, "totalSupply != adapter liquidity");
        }
        // Units exist only for opened ids, which is all `increaseLiquidity`'s holder check needs
        assertEq(collateral.totalSupply(0), 0, "units of id 0");
        assertEq(collateral.totalSupply(collateral.nextPositionId()), 0, "units of an unopened id");
    }

    /// @notice Lender shares: holders sum to the market's supply shares
    function invariant_lenderSharesAreConserved() public view {
        address[] memory holders = _holders();
        address[2] memory assets = _assets();
        for (uint256 a; a < 2; ++a) {
            uint256 supplyId = lenderId(assets[a]);
            uint256 sum;
            for (uint256 h; h < holders.length; ++h) {
                sum += borrowable.balanceOf(holders[h], supplyId);
            }
            sum += borrowable.getMarket(assets[a]).pendingReserveShares;
            assertEq(sum, borrowable.totalSupply(supplyId), "lender shares != totalSupply");
        }
    }

    /// @notice Borrow shares: positions sum to the market total, and debt masks match the shares exactly
    function invariant_debtAccountingIsConsistent() public view {
        address[2] memory assets = _assets();
        for (uint256 a; a < 2; ++a) {
            Market memory market = borrowable.getMarket(assets[a]);
            uint256 sum;
            for (uint256 i; i < handler.idsLength(); ++i) {
                uint256 id = handler.ids(i);
                for (uint256 h; h < actors.length; ++h) {
                    uint256 shares = borrowable.borrowSharesOf(actors[h], id, assets[a]);
                    sum += shares;
                    (address owed0, uint256 amount0, address owed1, uint256 amount1) = borrowable.debts(actors[h], id);
                    bool listed = (owed0 == assets[a] && amount0 > 0) || (owed1 == assets[a] && amount1 > 0);
                    assertEq(listed, shares > 0, "debts out of sync with borrow shares");
                    assertEq(borrowable.hasDebt(actors[h], id), owed0 != address(0), "hasDebt out of sync");
                    if (owed0 == address(0)) assertEq(owed1, address(0), "a second debt without a first");
                }
            }
            assertEq(sum, market.totalBorrowShares, "borrow shares != market total");
        }
    }

    /// @notice Market solvency: borrows never exceed supply, and the Hub holds at least its cash
    function invariant_marketsAreBacked() public view {
        address[2] memory assets = _assets();
        for (uint256 a; a < 2; ++a) {
            Market memory market = borrowable.getMarket(assets[a]);
            assertLe(market.totalBorrowAssets, market.totalSupplyAssets, "borrows > supply");
            uint256 cash = market.totalSupplyAssets - market.totalBorrowAssets;
            assertGe(
                MockERC20Balance(assets[a]).balanceOf(address(borrowable)),
                cash,
                "token balance below the market's cash"
            );
        }
    }

    /// @notice Rates: the rate at target, stored and as of now, stays within its bounds, and no borrow rate passes
    ///         150% a year
    function invariant_ratesAreBounded() public view {
        address[2] memory assets = _assets();
        for (uint256 a; a < 2; ++a) {
            uint256 stored = borrowable.getMarket(assets[a]).rateAtTarget;
            (,,, uint256 borrowRate,, uint256 rateAtTarget) = borrowable.marketState(assets[a]);
            assertGe(stored, MarketLogic.MIN_RATE_AT_TARGET, "stored rate at target below the floor");
            assertLe(stored, MarketLogic.MAX_RATE_AT_TARGET, "stored rate at target above the ceiling");
            assertGe(rateAtTarget, MarketLogic.MIN_RATE_AT_TARGET, "rate at target below the floor");
            assertLe(rateAtTarget, MarketLogic.MAX_RATE_AT_TARGET, "rate at target above the ceiling");
            assertLe(borrowRate * 365 days, 1.5e18, "borrow rate above 150% a year");
        }
    }

    /// @notice Lenders' money: every lender share, valued at the current share price (interest accrued), adds up to no
    ///         more than the market's supply, which is its cash plus what borrowers owe. The last lender out is paid
    ///         like the first
    function invariant_lenderClaimsAreCovered() public view {
        address[] memory holders = _holders();
        address[2] memory assets = _assets();
        for (uint256 a; a < 2; ++a) {
            uint256 id = lenderId(assets[a]);
            uint256 claims;
            for (uint256 h; h < holders.length; ++h) {
                claims += borrowable.convertToAssets(assets[a], borrowable.balanceOf(holders[h], id));
            }
            (uint256 supplyAssets,,,,,) = borrowable.marketState(assets[a]);
            assertLe(claims, supplyAssets, "lender claims exceed the market's supply");
        }
    }

    /// @notice LP fees: what every holder of a position is owed never exceeds what the adapter still holds
    ///         for it (per-holder checkpoints round down, so the sum can't outgrow the position's fees)
    function invariant_feesOwedAreCollectable() public view {
        address[] memory holders = _holders();
        for (uint256 i; i < handler.idsLength(); ++i) {
            uint256 id = handler.ids(i);
            uint256 owed0;
            uint256 owed1;
            for (uint256 h; h < holders.length; ++h) {
                (uint256 f0, uint256 f1) = adapter.feesOwed(holders[h], id);
                owed0 += f0;
                owed1 += f1;
            }
            (,,,,,,, uint256 uncollected0, uint256 uncollected1) = adapter.positions(id);
            assertLe(owed0, uncollected0, "token0 fees owed > collectable");
            assertLe(owed1, uncollected1, "token1 fees owed > collectable");
        }
    }

    /// @notice Shows which actions ran, so a passing run isn't a run where everything reverted
    function afterInvariant() public view {
        string[16] memory names = [
            "supply",
            "withdraw",
            "open",
            "increase",
            "redeem",
            "transfer",
            "accrueFees",
            "collectFees",
            "compound",
            "borrow",
            "repay",
            "liquidate",
            "writeOff",
            "setEthPrice",
            "lockScript",
            "lockBorrowBeforeOpen"
        ];
        for (uint256 i; i < names.length; ++i) {
            console2.log(names[i], handler.calls(bytes32(bytes(names[i]))));
        }
    }
}

interface MockERC20Balance {
    function balanceOf(address) external view returns (uint256);
}

/// @notice The same invariants with a penalty per token: WETH at the floor, USDC above it, so the pair pays USDC's
///         and a liquidation's penalty shrinks to collateral / debt from 1.03 down
contract HubInvariantPenaltyPerTokenTest is HubInvariantTest {
    function setUp() public override {
        super.setUp();
        riskConfig.setTokenRisk(address(adapter), address(weth), 1.15e18, 1.02e18, true);
        riskConfig.setTokenRisk(address(adapter), address(usdc), 1.02e18, 1.03e18, true);
    }
}
