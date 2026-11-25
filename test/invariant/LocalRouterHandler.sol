// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISenzuCollateral} from "../../src/interfaces/ISenzuCollateral.sol";
import {ISenzuERC6909} from "../../src/interfaces/ISenzuERC6909.sol";
import {ISenzuRouter} from "../../src/interfaces/ISenzuRouter.sol";
import {lenderId} from "../../src/libraries/Types.sol";
import {MockERC20, MockPermit2} from "../mocks/Mocks.sol";
import {RouterPlan} from "../utils/RouterPlan.sol";
import {LocalHandler} from "./LocalHandler.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @dev An aggregator on the router's list gone hostile: with the router's exact approval in hand it tries to take a
///      victim's tokens, re-enter the router and borrow for a victim, then pays the swap's minimum
contract HostileAggregator {
    function attack(address victim, address tokenIn, uint256 amountIn, address tokenOut, address collateral, uint256 id)
        external
    {
        address router = msg.sender;
        MockERC20(tokenIn).transferFrom(router, address(this), amountIn);
        tokenIn.call(abi.encodeCall(MockERC20.transferFrom, (victim, address(this), 1)));
        tokenIn.call(abi.encodeCall(MockERC20.transferFrom, (router, address(this), 1)));
        router.call(abi.encodeCall(ISenzuRouter.swap, (tokenIn, tokenOut, 1, 1, "")));
        collateral.call(abi.encodeCall(ISenzuCollateral.borrow, (victim, id, tokenOut, 1, address(this))));
        MockERC20(tokenOut).mint(router, 1);
    }
}

/**
 *  @notice LocalHandler's world driven through the deployment's real router as well: leveraged opens, leveraging up,
 *          deleveraging, closes and flash liquidations as the app builds them, swapping in the positions' own pool.
 *          The router keeps nothing and its minimums hold. And an outsider tries to make the router act on, or pay
 *          with, the accounts that approved it without limit and made it their operator (Ekubo's routers, May 2026,
 *          paid a settlement with whoever the callback's data named): every attempt leaves their wallets,
 *          allowances, units, debts and lender shares as they were.
 */
abstract contract LocalRouterHandler is LocalHandler {
    using RouterPlan for RouterPlan.Plan;

    uint256 internal constant ALL = type(uint256).max;
    address internal constant KYBERSWAP = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;

    ISenzuRouter public router;

    /// @dev A swap path between the pair's tokens through the pool, in the router's encoding
    function _route(address tokenIn, address tokenOut) internal view virtual returns (bytes memory);

    /// @dev Actors approve the router without limit and make it their operator on both sides: everything a victim
    ///      can have given it
    function _wireRouter(address router_) internal {
        router = ISenzuRouter(router_);
        _placeStandIns();
        for (uint256 i; i < actors.length; ++i) {
            address a = actors[i];
            vm.prank(a);
            token0.approve(router_, type(uint256).max);
            vm.prank(a);
            token1.approve(router_, type(uint256).max);
            vm.prank(a);
            dai.approve(router_, type(uint256).max);
            vm.prank(a);
            collateral.setOperator(router_, true);
            vm.prank(a);
            ISenzuERC6909(address(borrowable)).setOperator(router_, true);
        }
    }

    /*  ================================================
                         The app's flows
        ================================================  */

    /// @notice A leveraged open in one call: half the deposit from the wallet and the rest borrowed against the new
    ///         position (OpenExact), or the deposit pulled, a borrow swapped half into the other token, and an open
    ///         with everything the router holds
    function routerOpen(uint256 actorSeed, uint256 rangeSeed, uint256 liquidity, uint256 assetSeed, uint256 bps)
        external
        action("routerOpen")
    {
        if (_freeSlot() == type(uint256).max) return;
        address a = actors[actorSeed % actors.length];
        _actor = a;
        uint256 r = rangeSeed % RANGES;
        uint128 l = uint128(_bound(liquidity, 1e9, 1e14));
        (,, uint256 amount0, uint256 amount1) = adapter.quoteDeposit(_mintData(r, l));
        RouterPlan.Plan memory plan = bps % 2 == 0
            ? _exactOpenPlan(a, r, l, amount0, amount1)
            : _swapOpenPlan(a, r, amount0, amount1, _pairAsset(assetSeed), _bound(bps, 1, 9000));
        (bool ok, uint256 id,) = _execute(a, plan);
        if (!ok) return;
        _track(id, r);
        _absorbed();
        if (collateral.balanceOf(a, id) == 0 || collateral.balanceOf(a, id) != collateral.totalSupply(id)) {
            _fail("a router open didn't give the user the whole position");
        }
        if (collateral.health(a, id).minSurplusUsdWad < 0) _fail("a router open ended liquidatable");
        ++calls["routerOpen"];
    }

    function _exactOpenPlan(address a, uint256 r, uint128 l, uint256 amount0, uint256 amount1)
        internal
        returns (RouterPlan.Plan memory plan)
    {
        _give(token0, a, amount0 / 2);
        _give(token1, a, amount1 / 2);
        plan = plan.openExact(_mintData(r, l), amount0 / 2, amount1 / 2, amount0, amount1);
    }

    function _swapOpenPlan(address a, uint256 r, uint256 amount0, uint256 amount1, MockERC20 asset, uint256 bps)
        internal
        returns (RouterPlan.Plan memory plan)
    {
        _give(token0, a, amount0);
        _give(token1, a, amount1);
        plan = plan.pull(address(token0), amount0).pull(address(token1), amount1);
        uint256 borrowed = (asset == token0 ? amount0 : amount1) * bps / 10_000;
        if (borrowed > 1) {
            MockERC20 other = _other(asset);
            plan = plan.borrow(0, address(asset), borrowed);
            plan = plan.swap(address(asset), address(other), borrowed / 2, 0, _route(address(asset), address(other)));
        }
        plan = plan.open(_mintData(r, 0), address(token0), address(token1));
    }

    /// @notice Leverage up: borrow against the position, swap half in its pool, add everything
    function routerLeverUp(uint256 holderSeed, uint256 idSeed, uint256 assetSeed, uint256 bps)
        external
        action("routerLeverUp")
    {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        address h = _actorOf(id, holderSeed);
        if (h == address(0)) return;
        _actor = h;
        MockERC20 asset = _pairAsset(assetSeed);
        MockERC20 other = _other(asset);
        uint256 amount = _usdToAsset(asset, collateral.health(h, id).collateralUsdWad * _bound(bps, 1, 6000) / 10_000);
        if (amount < 2) return;
        uint256 units = collateral.balanceOf(h, id);
        RouterPlan.Plan memory plan;
        plan = plan.borrow(id, address(asset), amount);
        plan = plan.swap(address(asset), address(other), amount / 2, 0, _route(address(asset), address(other)));
        plan = plan.increase(id, ALL, ALL, 0, 0);
        (bool ok,,) = _execute(h, plan);
        if (!ok) return;
        _absorbed();
        if (collateral.balanceOf(h, id) < units) _fail("a router lever-up took units");
        if (collateral.health(h, id).minSurplusUsdWad < 0) _fail("a router lever-up ended liquidatable");
        ++calls["routerLeverUp"];
    }

    /// @notice Deleverage: redeem part of the position, swap the other token into the debt's, repay with all of it.
    ///         The debt's token comes back to the user only once that debt is gone
    function routerDeleverage(uint256 holderSeed, uint256 idSeed, uint256 assetSeed, uint256 fraction)
        external
        action("routerDeleverage")
    {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        address h = _actorOf(id, holderSeed);
        if (h == address(0)) return;
        MockERC20 asset = _pairDebt(h, id, assetSeed);
        if (address(asset) == address(0)) return;
        _actor = h;
        uint256 balance = collateral.balanceOf(h, id);
        uint256 units = balance * _bound(fraction, 1, 9000) / 10_000;
        if (units == 0) return;
        uint256 debt = borrowable.debtOf(h, id, address(asset));
        uint256 cash = asset.balanceOf(h);
        MockERC20 other = _other(asset);
        RouterPlan.Plan memory plan;
        plan = plan.redeem(id, units, 0, 0);
        plan = plan.swap(address(other), address(asset), ALL, 0, _route(address(other), address(asset)));
        plan = plan.repay(id, address(asset), ALL);
        _creditAfter = true;
        (bool ok,,) = _execute(h, plan);
        if (!ok) return;
        if (collateral.balanceOf(h, id) != balance - units) _fail("a router deleverage redeemed another amount");
        uint256 left = borrowable.debtOf(h, id, address(asset));
        if (left > debt) _fail("a router deleverage raised the debt");
        if (left > 0 && asset.balanceOf(h) != cash) _fail("a deleverage kept debt and paid the user back");
        if (collateral.health(h, id).minSurplusUsdWad < 0) _fail("a router deleverage ended liquidatable");
        ++calls["routerDeleverage"];
    }

    /// @notice Close: redeem every unit, buy back exactly each debt in the pool (a DAI debt paid from the wallet),
    ///         repay. Leaving pays the account all its fees. A position worth twice its debt, with the pool at the
    ///         oracle's price, must close
    function routerClose(uint256 holderSeed, uint256 idSeed) external action("routerClose") {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        address h = _actorOf(id, holderSeed);
        if (h == address(0)) return;
        _actor = h;
        (uint256 owed0, uint256 owed1) = adapter.feesOwed(h, id);
        bool covered = _covered(h, id);
        RouterPlan.Plan memory plan = _closePlan(h, id);
        _creditAfter = true;
        (bool ok,,) = _execute(h, plan);
        if (!ok) {
            if (covered) _fail("a well-covered position couldn't close through the router");
            return;
        }
        if (collateral.balanceOf(h, id) != 0 || borrowable.hasDebt(h, id)) _fail("a router close left units or debt");
        (uint256 left0, uint256 left1) = adapter.feesOwed(h, id);
        if (left0 + left1 > 0) _fail("a router close left fees owed");
        payouts.push(Payout(h, id, owed0, owed1));
        ++calls["routerClose"];
        if (owed0 + owed1 > 0) ++calls["routerCloseWithFees"];
    }

    function _closePlan(address h, uint256 id) internal returns (RouterPlan.Plan memory plan) {
        plan = plan.redeem(id, ALL, 0, 0);
        for (uint256 k; k < 2; ++k) {
            MockERC20 asset = k == 0 ? usdc : weth;
            if (borrowable.debtOf(h, id, address(asset)) == 0) continue;
            MockERC20 other = _other(asset);
            plan = plan.swapForDebt(id, address(asset), address(other), ALL, _route(address(other), address(asset)));
            plan = plan.repay(id, address(asset), ALL);
        }
        uint256 owed = borrowable.debtOf(h, id, address(dai));
        if (owed > 0) {
            uint256 pay = owed + owed / 100 + 1;
            _give(dai, h, pay);
            plan = plan.pull(address(dai), pay).repay(id, address(dai), ALL);
        }
    }

    /// @dev One debt in the pair at most, the pool within a percent of the oracle's price, and the units worth twice
    ///      the debts
    function _covered(address h, uint256 id) internal view returns (bool) {
        uint256 debtUsdc = borrowable.debtOf(h, id, address(usdc));
        uint256 debtWeth = borrowable.debtOf(h, id, address(weth));
        if (debtUsdc > 0 && debtWeth > 0) return false;
        uint256 pool = adapter.poolSqrtPriceX96(id);
        uint256 fair = _oracleSqrtPriceX96();
        if (pool > fair + fair / 200 || pool + fair / 200 < fair) return false;
        (uint256 amount0, uint256 amount1) = _amountsOf(id, collateral.balanceOf(h, id));
        uint256 debt = _usd(usdc, debtUsdc) + _usd(weth, debtWeth) + _usd(dai, borrowable.debtOf(h, id, address(dai)));
        return debt * 2 < _usd(token0, amount0) + _usd(token1, amount1);
    }

    /// @notice A flash liquidation with no capital: seize, redeem every unit the liquidator holds, sell the other
    ///         token for the debt's; the router settles the repayment from what came out (a DAI debt from the wallet)
    function routerLiquidate(uint256 holderSeed, uint256 idSeed, uint256 liquidatorSeed, uint256 mode)
        external
        action("routerLiquidate")
    {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        address b = _debtorOf(id, holderSeed);
        if (b == address(0) || collateral.health(b, id).minSurplusUsdWad >= 0) return;
        address liquidator = _freeActor(b, id, liquidatorSeed);
        if (liquidator == address(0)) return;
        _actor = liquidator;
        MockERC20 asset = _debtAsset(b, id, mode);
        uint256 debt = borrowable.debtOf(b, id, address(asset));
        uint256 units = collateral.balanceOf(b, id);
        (uint256 owed0, uint256 owed1) = adapter.feesOwed(liquidator, id);
        RouterPlan.Plan memory plan = _flashLiquidation(liquidator, b, id, asset, debt, mode);
        _creditAfter = true;
        (bool ok,,) = _execute(liquidator, plan);
        if (!ok) return;
        uint256 left = collateral.balanceOf(b, id);
        if (left < units) seizes.push(Seize(b, liquidator, id, units - left, units));
        if (left >= units) _fail("a router liquidation seized nothing");
        if (borrowable.debtOf(b, id, address(asset)) >= debt) _fail("a router liquidation repaid nothing");
        if (collateral.balanceOf(b, id) == 0 && borrowable.hasDebt(b, id)) _fail("a full seize left bad debt waiting");
        if (collateral.balanceOf(liquidator, id) != 0) _fail("a flash liquidation left the liquidator units");
        (uint256 left0, uint256 left1) = adapter.feesOwed(liquidator, id);
        if (left0 + left1 > 0) _fail("a flash liquidation left the liquidator fees owed");
        payouts.push(Payout(liquidator, id, owed0, owed1));
        ++calls["routerLiquidate"];
        if (collateral.balanceOf(b, id) == 0) ++calls["writeOff"];
    }

    /// @dev Mode 0 repays the whole debt, 1 half, 2 a sliver
    function _flashLiquidation(address liquidator, address b, uint256 id, MockERC20 asset, uint256 debt, uint256 mode)
        internal
        returns (RouterPlan.Plan memory plan)
    {
        mode %= 3;
        uint256 repayAssets = mode == 0 ? ALL : mode == 1 ? debt / 2 + 1 : debt / 50 + 1;
        if (asset == dai) {
            _give(dai, liquidator, debt * 2);
            plan = plan.pull(address(dai), debt * 2);
            plan = plan.liquidate(b, id, address(dai), repayAssets);
            return plan.redeem(id, ALL, 0, 0);
        }
        MockERC20 other = _other(asset);
        plan = plan.liquidate(b, id, address(asset), repayAssets);
        plan = plan.redeem(id, ALL, 0, 0);
        plan = plan.swap(address(other), address(asset), ALL, 0, _route(address(other), address(asset)));
    }

    /// @notice The router's minimums: a redeem, a swap and an increase asking a wei more than they give revert
    function routerSlippage(uint256 holderSeed, uint256 idSeed, uint256 kind) external action("routerSlippage") {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        address h = _actorOf(id, holderSeed);
        if (h == address(0) || borrowable.hasDebt(h, id)) return;
        _actor = h;
        RouterPlan.Plan memory plan;
        bytes4 expected = ISenzuRouter.SenzuRouter__InsufficientOutput.selector;
        kind %= 3;
        if (kind == 0) {
            uint256 units = collateral.balanceOf(h, id) / 2;
            if (units == 0) return;
            (uint256 amount0, uint256 amount1) = _amountsOf(id, units);
            plan = plan.redeem(id, units, amount0 + 1, amount1 + 1);
        } else if (kind == 1) {
            uint256 amount = token0 == usdc ? 1000e6 : 0.5e18;
            _give(token0, h, amount);
            plan = plan.pull(address(token0), amount);
            plan = plan.swap(
                address(token0), address(token1), amount, type(uint128).max, _route(address(token0), address(token1))
            );
        } else {
            (,, uint256 amount0, uint256 amount1) = adapter.quoteDeposit(_mintData(rangeOf[id], 1e10));
            _give(token0, h, amount0);
            _give(token1, h, amount1);
            plan = plan.pull(address(token0), amount0).pull(address(token1), amount1);
            plan = plan.increase(id, ALL, ALL, amount0 + 1, amount1 + 1);
            expected = ISenzuRouter.SenzuRouter__DepositBelowMinimum.selector;
        }
        (bool ok,, bytes memory err) = _execute(h, plan);
        if (ok) _fail("the router let a call through below its minimum");
        else if (_selector(err) == expected) ++calls["routerSlippage"];
    }

    /*  ================================================
                            The thief
        ================================================  */

    /// @notice An outsider with nothing, against accounts that approved the router without limit and made it their
    ///         operator: pulls, borrows, liquidating a healthy debtor, opening on someone's wallet, the lock callback
    ///         called directly with a victim as the user, `execute` with a victim appended to its calldata, the swap
    ///         callbacks called directly, and `swap`. Each must revert, and nothing of any victim's may move
    /// @dev The hostile aggregator, and Permit2 where every chain has it: Solady takes Permit2 as present on chain id 1
    ///      (Medusa's) without looking, so an empty address there would pass a pull nobody approved. Medusa keeps
    ///      etched code only for the transaction that etches it, while the address can still report code, so every
    ///      attack places them again
    function _placeStandIns() internal {
        vm.etch(KYBERSWAP, address(new HostileAggregator()).code);
        vm.etch(SafeTransferLib.PERMIT2, address(new MockPermit2()).code);
    }

    function routerAttack(uint256 kind, uint256 victimSeed, uint256 idSeed, uint256 assetSeed)
        external
        action("routerAttack")
    {
        _placeStandIns();
        _actor = OUTSIDER;
        address victim = actors[victimSeed % actors.length];
        uint256 id = ids.length == 0 ? 1 : ids[idSeed % ids.length];
        MockERC20 asset = _asset(assetSeed);
        bytes32 before = _victims();
        kind %= 12;
        bool ok = _attack(kind, victim, id, asset);
        // A redeem, collect or withdraw of the outsider's own nothing may go through, and a swap of its own tokens
        if (ok && kind != 1 && kind != 3 && kind != 4 && kind != 11) _fail("the router let an outsider through");
        if (_victims() != before) _fail("an outsider moved a victim's wallet, allowance, units, debt or shares");
        ++calls["routerAttack"];
    }

    function _attack(uint256 kind, address victim, uint256 id, MockERC20 asset) internal returns (bool ok) {
        RouterPlan.Plan memory plan;
        if (kind == 0) {
            plan = plan.pull(address(asset), 1e6);
        } else if (kind == 1) {
            plan = plan.redeem(id, ALL, 0, 0);
        } else if (kind == 2) {
            plan = plan.borrow(id, address(asset), 1e6);
        } else if (kind == 3) {
            plan = plan.collectFees(id);
        } else if (kind == 4) {
            plan = plan.withdraw(address(asset), ALL);
        } else if (kind == 5) {
            plan = plan.liquidate(_healthyDebtor(id, victim), id, address(asset), ALL);
        } else if (kind == 6) {
            plan = plan.openExact(_mintData(0, 1e9), ALL, ALL, 0, 0);
        } else if (kind == 7) {
            return _lockCallback(asset);
        } else if (kind == 8) {
            return _appended(victim, asset);
        } else if (kind == 9) {
            return _fakeCallbacks(victim, asset);
        } else if (kind == 11) {
            return _hostileAggregator(victim, id);
        } else {
            return _callAs(
                address(router),
                abi.encodeCall(
                    router.swap, (address(token0), address(token1), 1e6, 0, _route(address(token0), address(token1)))
                )
            );
        }
        (ok,,) = _execute(OUTSIDER, plan);
    }

    /// @dev The lock callback with a pull, called by the outsider and then by the collateral itself, outside any
    ///      `execute`: the user may only ever be that call's caller
    function _lockCallback(MockERC20 asset) internal returns (bool ok) {
        RouterPlan.Plan memory plan;
        plan = plan.pull(address(asset), 1e6);
        bytes memory data = abi.encodeCall(router.senzuLockAcquired, (abi.encode(plan.actions, plan.params, false)));
        ok = _callAs(address(router), data);
        vm.prank(address(collateral));
        (bool viaCollateral,) = address(router).call(data);
        ok = ok || viaCollateral;
        _checkRouterEmpty();
    }

    /// @dev `execute` with a pull, its calldata followed by the victim's address and an amount
    function _appended(address victim, MockERC20 asset) internal returns (bool) {
        RouterPlan.Plan memory plan;
        plan = plan.pull(address(asset), 1e6);
        bytes memory data = abi.encodeCall(router.execute, (plan.actions, plan.params, block.timestamp, false));
        return _callAs(address(router), bytes.concat(data, abi.encode(victim, uint256(1e6))));
    }

    /// @dev The DEXes' callbacks, called by the outsider as if it were the pool or the PoolManager
    function _fakeCallbacks(address victim, MockERC20 asset) internal returns (bool ok) {
        bytes memory route = _route(address(token0), address(token1));
        ok = _callAs(
            address(router),
            abi.encodeWithSignature(
                "uniswapV3SwapCallback(int256,int256,bytes)",
                int256(1e6),
                int256(1e6),
                abi.encode(route, uint256(0), false)
            )
        );
        ok = ok
            || _callAs(
                address(router),
                abi.encodeWithSignature(
                    "unlockCallback(bytes)", abi.encode(true, address(asset), victim, uint256(1e6), route)
                )
            );
    }

    /// @dev The outsider swaps its own token0 through a listed aggregator that turns on the router's users
    function _hostileAggregator(address victim, uint256 id) internal returns (bool ok) {
        token0.mint(OUTSIDER, 1e6);
        vm.prank(OUTSIDER);
        token0.approve(address(router), 1e6);
        bytes memory route = abi.encodePacked(
            KYBERSWAP,
            abi.encodeCall(
                HostileAggregator.attack, (victim, address(token0), 1e6, address(token1), address(collateral), id)
            )
        );
        ok = _callAs(address(router), abi.encodeCall(router.swap, (address(token0), address(token1), 1e6, 1, route)));
        if (token0.allowance(address(router), KYBERSWAP) != 0) _fail("the router left an aggregator approved");
        // The outsider owns nothing again, so a later pull of its own tokens can't pass for an attack
        token0.burn(OUTSIDER, token0.balanceOf(OUTSIDER));
        vm.prank(OUTSIDER);
        token0.approve(address(router), 0);
    }

    function _callAs(address target, bytes memory data) internal returns (bool ok) {
        vm.prank(OUTSIDER);
        (ok,) = target.call(data);
        _checkRouterEmpty();
    }

    /// @dev A debtor of `id` that isn't liquidatable, or the victim (whose missing debt makes it revert as well)
    function _healthyDebtor(uint256 id, address victim) internal view returns (address) {
        for (uint256 i; i < actors.length; ++i) {
            if (borrowable.hasDebt(actors[i], id) && collateral.health(actors[i], id).minSurplusUsdWad >= 0) {
                return actors[i];
            }
        }
        return victim;
    }

    /// @dev Everything the actors hold or have given: wallets, allowances to the router, units, debts, lender shares
    function _victims() internal view returns (bytes32 h) {
        for (uint256 i; i < actors.length; ++i) {
            address a = actors[i];
            h = keccak256(
                abi.encode(
                    h,
                    token0.balanceOf(a),
                    token1.balanceOf(a),
                    dai.balanceOf(a),
                    token0.allowance(a, address(router)),
                    token1.allowance(a, address(router)),
                    dai.allowance(a, address(router))
                )
            );
            for (uint256 k; k < 3; ++k) {
                h = keccak256(abi.encode(h, borrowable.balanceOf(a, lenderId(address(_asset(k))))));
            }
        }
        // A second pass for positions: in one loop, the optimizer at 1M runs keeps every address read here on the
        // stack and runs out of it
        for (uint256 i; i < actors.length; ++i) {
            address a = actors[i];
            for (uint256 j; j < allIds.length; ++j) {
                uint256 id = allIds[j];
                if (retired[id]) continue;
                h = keccak256(
                    abi.encode(
                        h,
                        collateral.balanceOf(a, id),
                        borrowable.debtOf(a, id, address(usdc)),
                        borrowable.debtOf(a, id, address(weth)),
                        borrowable.debtOf(a, id, address(dai))
                    )
                );
            }
        }
    }

    /*  ================================================
                            Helpers
        ================================================  */

    /// @dev Runs the plan for `user`; the router must hold nothing after, whether it went through or reverted
    function _execute(address user, RouterPlan.Plan memory plan)
        internal
        returns (bool ok, uint256 id, bytes memory err)
    {
        vm.prank(user);
        try router.execute(plan.actions, plan.params, block.timestamp, false) returns (uint256 lastId) {
            (ok, id) = (true, lastId);
        } catch (bytes memory e) {
            err = e;
        }
        _checkRouterEmpty();
    }

    function _checkRouterEmpty() internal {
        address r = address(router);
        if (
            token0.balanceOf(r) != 0 || token1.balanceOf(r) != 0 || dai.balanceOf(r) != 0 || junk.balanceOf(r) != 0
                || r.balance != 0
        ) _fail("the router kept tokens");
    }

    function _pairAsset(uint256 seed) internal view returns (MockERC20) {
        return seed % 2 == 0 ? usdc : weth;
    }

    function _other(MockERC20 asset) internal view returns (MockERC20) {
        return asset == usdc ? weth : usdc;
    }

    /// @dev One of the pair's tokens `h` owes on `id`, from the seed's; zero if neither
    function _pairDebt(address h, uint256 id, uint256 seed) internal view returns (MockERC20) {
        MockERC20 asset = _pairAsset(seed);
        if (borrowable.debtOf(h, id, address(asset)) > 0) return asset;
        asset = _other(asset);
        return borrowable.debtOf(h, id, address(asset)) > 0 ? asset : MockERC20(address(0));
    }

    /// @dev An actor holding units of `id`: only actors approved the router
    function _actorOf(uint256 id, uint256 seed) internal view returns (address) {
        for (uint256 i; i < actors.length; ++i) {
            address a = actors[(seed + i) % actors.length];
            if (collateral.balanceOf(a, id) > 0) return a;
        }
        return address(0);
    }

    /// @dev An actor other than the borrower with no debt on `id`, so it can redeem everything it seizes
    function _freeActor(address b, uint256 id, uint256 seed) internal view returns (address) {
        for (uint256 i; i < actors.length; ++i) {
            address a = actors[(seed + i) % actors.length];
            if (a != b && !borrowable.hasDebt(a, id)) return a;
        }
        return address(0);
    }
}
