// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TokenRisk} from "../libraries/Types.sol";

/**
 *  @title  ISenzuRiskConfig
 *  @notice Every risk parameter Senzu reads, for every DEX, in one contract created by SenzuFactory. Each setting
 *          is per DEX, keyed by the DEX's adapter (`dex`), which both halves of a set hold as an immutable. Admin
 *          (timelock) sets parameters; the guardian can only pause. Pauses never block repay, withdraw or liquidate.
 */
interface ISenzuRiskConfig {
    error SenzuRiskConfig__NotAdmin();
    error SenzuRiskConfig__NotGuardian();
    error SenzuRiskConfig__NotFactory();
    error SenzuRiskConfig__UnknownDex(address dex);
    error SenzuRiskConfig__DexAlreadyAdded(address dex);
    error SenzuRiskConfig__InvalidSigma();
    error SenzuRiskConfig__InvalidPenalty();
    error SenzuRiskConfig__InvalidBorrowFee();
    error SenzuRiskConfig__InvalidFeeCut();
    error SenzuRiskConfig__InvalidLiquidationFee();
    error SenzuRiskConfig__InvalidAction();
    error SenzuRiskConfig__OnlyInBorrowersFavor();
    error SenzuRiskConfig__CannotBeLiquid(address token);
    error SenzuRiskConfig__CollateralNotEnabled(address token);
    error SenzuRiskConfig__PairNotEnabled(bytes32 pairKey);

    event DexAdded(address indexed dex);
    event TokenRiskSet(
        address indexed dex, address indexed token, uint64 sigmaWad, uint64 penaltyWad, bool collateralEnabled
    );
    event LiquidSet(address indexed dex, address indexed token);
    event PairEnabledSet(address indexed dex, bytes32 indexed pairKey, address token0, address token1, bool enabled);
    event BorrowFeeSet(address indexed dex, uint64 borrowFeeWad);
    event FeeCutSet(address indexed dex, uint64 feeCutWad);
    event LiquidationFeeSet(address indexed dex, uint64 liquidationFeeWad);
    event PauseSet(address indexed dex, bytes32 indexed action, bool paused);

    function factory() external view returns (address);

    /// @notice Whether `dex` (an adapter) was added by the factory, with the default parameters
    function isDex(address dex) external view returns (bool);

    /// @notice σ, the liquidation penalty and whether `token` can be collateral, on `dex` (σ and the penalty also
    ///         apply to `token` as a debt there)
    function tokenRisk(address dex, address token) external view returns (TokenRisk memory);

    /// @notice What every health check reads of a pair on `dex`, in one call: its two tokens' σ and the pair's
    ///         liquidation penalty (the higher of the two tokens')
    function pairRisk(address dex, address token0, address token1)
        external
        view
        returns (uint256 sigma0Wad, uint256 sigma1Wad, uint256 penaltyWad);

    /// @notice Whether a pair is listed, keyed by keccak256(adapter, token0, token1)
    function pairEnabled(bytes32 pairKey) external view returns (bool);

    /// @notice Reverts unless a pair on `dex` can be opened or borrowed against: both tokens enabled as collateral and
    ///         the pair listed. Returns its key, keccak256(dex, token0, token1)
    function requireListed(address dex, address token0, address token1) external view returns (bytes32 pairKey);

    /// @notice Opening fee on every borrow on `dex` (1e18 = 100%), added to the debt and minted to the DAO as lender
    ///         shares
    function borrowFeeWad(address dex) external view returns (uint64);

    /// @notice `isPaused(dex, ACTION_BORROW)` and `borrowFeeWad(dex)`, in one call and one storage read
    function borrowTerms(address dex) external view returns (bool paused, uint64 feeWad);

    /**
     *  @notice The protocol's share of the LP fees and rewards `dex` pays holders (1e18 = 100%), and where it goes:
     *          the factory's `protocolReserves` (the FeeRouter, which passes it to stakers). Taken by the adapter at
     *          payout, so a change applies to fees not yet collected
     */
    function feeCut(address dex) external view returns (uint64 cutWad, address to);

    /// @notice The protocol's share of the liquidation bonus on `dex` (1e18 = 100%), paid in the repaid asset and
    ///         booked to reserves as lender shares; zero when collateral is under 1.02x the debt or when the
    ///         liquidation writes debt off
    function liquidationFeeWad(address dex) external view returns (uint64);

    /// @notice Pausable actions on `dex`: SUPPLY, BORROW, OPEN
    function isPaused(address dex, bytes32 action) external view returns (bool);

    /// @notice Factory only, as it deploys a set. The DEX starts with a 10% liquidation fee
    function addDex(address dex) external;

    /// @notice σ and the penalty, once set, can only go down; the penalty stays between MIN_INCENTIVE (1.02) and 1.25
    function setTokenRisk(address dex, address token, uint64 sigmaWad, uint64 penaltyWad, bool collateralEnabled)
        external;

    /**
     *  @notice Admin only, set-only: `token` may be owed on `dex` by a position outside its pair. Clearing it would
     *          fail every health check of a position owing it, so it can't be cleared. Never a token whose price can
     *          pause (a stock), and only once `token` has its risk set on `dex` and its feed in the oracle
     */
    function setLiquid(address dex, address token) external;

    /// @notice Admin only. Lists or unlists the pair (token0, token1) on `dex`, in the order its adapter reports them;
    ///         a disabled pair takes no new positions or borrows, open ones keep repaying and closing
    function setPairEnabled(address dex, address token0, address token1, bool enabled) external;

    /// @notice Admin only. 0 (the default) to 0.20%
    function setBorrowFee(address dex, uint64 borrowFeeWad) external;

    /// @notice Admin only. 0 (the default) to 5%
    function setFeeCut(address dex, uint64 feeCutWad) external;

    /// @notice Admin only. 0 to 20% (10% when the DEX is added)
    function setLiquidationFee(address dex, uint64 liquidationFeeWad) external;

    /// @notice Guardian or admin
    function setPaused(address dex, bytes32 action, bool paused) external;
}
