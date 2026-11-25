// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {BaseAdapter} from "../../src/adapters/BaseAdapter.sol";
import {MockERC20} from "./Mocks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/**
 *  @dev An adapter whose positions are not ranges on x·y = k: each is one Liquidity Book–style bin, a constant-sum
 *       curve at a fixed price p (x · p + y = L). Above p arbitrage leaves it all token1, below p all token0. It has
 *       no `shape`: the core can value it only through `amountsAt`. No DEX behind it: the bin keeps what was
 *       deposited, and a redeem pays its share of that
 */
contract MockBinAdapter is BaseAdapter {
    uint256 internal constant Q96 = 1 << 96;

    struct Bin {
        address token0;
        address token1;
        uint160 sqrtPriceX96;
        uint256 units;
        uint256 reserve0;
        uint256 reserve1;
    }

    mapping(uint256 lpId => Bin) public bins;
    /// @dev Every bin's reserves together, by token: what the adapter holds beyond them was just sent in
    mapping(address token => uint256) internal _held;

    constructor(address collateral_) BaseAdapter(collateral_) {}

    /// @dev data = abi.encode(token0, token1, the bin's sqrt price)
    function deposit(uint256 lpId, address, address, bytes calldata data)
        external
        onlyCollateral
        returns (uint256 units_, address token0, address token1, uint256 used0, uint256 used1)
    {
        uint160 sqrtPriceX96;
        (token0, token1, sqrtPriceX96) = abi.decode(data, (address, address, uint160));
        bins[lpId] = Bin(token0, token1, sqrtPriceX96, 0, 0, 0);
        (units_, used0, used1) = _add(lpId);
        if (units_ == 0) revert SenzuAdapter__NoLiquidity();
    }

    function increaseLiquidity(uint256 lpId, address, uint256, address, bytes calldata)
        external
        onlyCollateral
        returns (uint256, uint256, uint256)
    {
        return _add(lpId);
    }

    function decreaseLiquidity(uint256 lpId, uint256 units_, address, uint256, address to, bytes calldata)
        external
        onlyCollateral
        returns (uint256 amount0, uint256 amount1)
    {
        Bin storage bin = bins[lpId];
        amount0 = FullMath.mulDiv(bin.reserve0, units_, bin.units);
        amount1 = FullMath.mulDiv(bin.reserve1, units_, bin.units);
        (bin.units, bin.reserve0, bin.reserve1) = (bin.units - units_, bin.reserve0 - amount0, bin.reserve1 - amount1);
        _held[bin.token0] -= amount0;
        _held[bin.token1] -= amount1;
        _sendPair(bin.token0, bin.token1, amount0, amount1, to);
    }

    function seize(uint256, address, address, uint256, uint256) external view onlyCollateral {}

    function collectFees(address, uint256, address) external pure returns (uint256, uint256) {}

    function feesOwed(address, uint256) external pure returns (uint256, uint256) {}

    function tokens(uint256 lpId) external view returns (address, address) {
        return (bins[lpId].token0, bins[lpId].token1);
    }

    function units(uint256 lpId) external view returns (uint256) {
        return bins[lpId].units;
    }

    function poolId(uint256) external pure returns (bytes32) {}

    function poolSqrtPriceX96(uint256 lpId) external view returns (uint160) {
        return bins[lpId].sqrtPriceX96;
    }

    /// @dev A unit is worth one token1 at the bin's price: all token1 at or above it, all token0 below it
    function amountsAt(uint256 lpId, uint256 accountUnits, uint256, uint160[5] calldata sqrtPricesX96)
        external
        view
        returns (uint256[5] memory amounts0, uint256[5] memory amounts1)
    {
        uint160 binPrice = bins[lpId].sqrtPriceX96;
        for (uint256 i; i < 5; ++i) {
            if (sqrtPricesX96[i] >= binPrice) amounts1[i] = accountUnits;
            else amounts0[i] = _inToken0(accountUnits, binPrice);
        }
    }

    /// @dev Takes every token0/token1 the adapter holds beyond the bins' reserves: units = their value in token1
    function _add(uint256 lpId) internal returns (uint256 added, uint256 in0, uint256 in1) {
        Bin storage bin = bins[lpId];
        in0 = MockERC20(bin.token0).balanceOf(address(this)) - _held[bin.token0];
        in1 = MockERC20(bin.token1).balanceOf(address(this)) - _held[bin.token1];
        added = FullMath.mulDiv(FullMath.mulDiv(in0, bin.sqrtPriceX96, Q96), bin.sqrtPriceX96, Q96) + in1;
        (bin.units, bin.reserve0, bin.reserve1) = (bin.units + added, bin.reserve0 + in0, bin.reserve1 + in1);
        _held[bin.token0] += in0;
        _held[bin.token1] += in1;
    }

    function _inToken0(uint256 amount1, uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(amount1, Q96, sqrtPriceX96), Q96, sqrtPriceX96);
    }
}
