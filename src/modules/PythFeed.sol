// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPyth} from "../interfaces/external/pyth/IPyth.sol";
import {PythStructs} from "../interfaces/external/pyth/PythStructs.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 *  @title  PythFeed
 *  @notice One Pyth Core feed read as a Chainlink aggregator, for a token Chainlink has no feed for on this chain:
 *          `SenzuOracle.addFeed(token, pythFeed, MAX_AGE)`. Pyth is a pull oracle, so callers post signed updates
 *          before they act (the router's PostPrices); Core keeps the newest per feed. `updatedAt` is Pyth's publish
 *          time, so the oracle's heartbeat judges the age. This contract reverts on what a round can't say: a
 *          confidence interval wider than `MAX_CONF_WAD` of the price, a publish time more than `MAX_AGE` ahead of
 *          the block, an exponent outside [-18, 0]. Pyth may change a feed's exponent; the price is rescaled to the
 *          decimals it was deployed with, since the oracle's feeds can't be replaced.
 */
contract PythFeed is AggregatorV3Interface {
    error PythFeed__InvalidFeed();
    error PythFeed__NoRoundHistory();
    error PythFeed__InvalidExponent();
    error PythFeed__PriceAhead();
    error PythFeed__UncertainPrice();

    /// @notice The heartbeat to list this feed with, in seconds; also how far ahead of the block a price may be
    uint256 public constant MAX_AGE = 60;

    /// @inheritdoc AggregatorV3Interface
    uint256 public constant override version = 1;

    /// @notice Widest usable confidence interval, as a fraction of the price (1e18 = 100%)
    uint256 public constant MAX_CONF_WAD = 0.02e18;

    /// @notice Pyth Core on this chain (its address differs per chain)
    IPyth public immutable pyth;

    /// @notice The Pyth feed id (the same on every chain)
    bytes32 public immutable id;

    /// @inheritdoc AggregatorV3Interface
    uint8 public immutable override decimals;

    /// @inheritdoc AggregatorV3Interface
    string public override description;

    /// @dev Someone must have posted the feed on this chain first (anyone can): its stored price, of any age, gives
    ///      the exponent and proves the id
    constructor(address pyth_, bytes32 id_, string memory description_) {
        // The exponent is all that's read here; every read checks the rest
        // slither-disable-next-line pyth-unchecked-confidence,pyth-unchecked-publishtime
        PythStructs.Price memory p = IPyth(pyth_).getPriceUnsafe(id_);
        if (p.expo > 0 || p.expo < -18) revert PythFeed__InvalidFeed();
        pyth = IPyth(pyth_);
        id = id_;
        // forge-lint: disable-next-line(unsafe-typecast)
        decimals = uint8(uint32(-p.expo));
        description = description_;
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev The round is the publish time. A price that isn't positive is returned as it is: the oracle refuses it
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        // Age is the oracle's check, against `updatedAt`
        // slither-disable-next-line pyth-unchecked-publishtime
        PythStructs.Price memory p = pyth.getPriceUnsafe(id);
        if (p.expo > 0 || p.expo < -18) revert PythFeed__InvalidExponent();
        // Pyth's publish times can run a little ahead of the chain's clock
        // forge-lint: disable-next-line(block-timestamp)
        if (p.publishTime > block.timestamp + MAX_AGE) revert PythFeed__PriceAhead();
        // The confidence and the price share the exponent, so their ratio is the same at any scale
        // forge-lint: disable-next-line(unsafe-typecast)
        if (p.price > 0 && uint256(p.conf) * 1e18 > uint64(p.price) * MAX_CONF_WAD) {
            revert PythFeed__UncertainPrice();
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        uint8 posted = uint8(uint32(-p.expo));
        answer = p.price;
        if (posted > decimals) answer /= int256(10 ** (posted - decimals));
        else if (posted < decimals) answer *= int256(10 ** (decimals - posted));
        // forge-lint: disable-next-line(block-timestamp)
        updatedAt = p.publishTime < block.timestamp ? p.publishTime : block.timestamp;
        startedAt = updatedAt;
        // forge-lint: disable-next-line(unsafe-typecast)
        roundId = uint80(p.publishTime);
        answeredInRound = roundId;
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev Pyth Core keeps only the newest price of a feed, so there are no past rounds to read
    function getRoundData(uint80) external pure override returns (uint80, int256, uint256, uint256, uint80) {
        revert PythFeed__NoRoundHistory();
    }
}
