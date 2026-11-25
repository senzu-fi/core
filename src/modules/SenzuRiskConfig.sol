// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISenzuFactory} from "../interfaces/ISenzuFactory.sol";
import {ISenzuOracle} from "../interfaces/ISenzuOracle.sol";
import {ISenzuRiskConfig} from "../interfaces/ISenzuRiskConfig.sol";
import {ACTION_BORROW, ACTION_OPEN, ACTION_SUPPLY, MIN_INCENTIVE, TokenRisk, WAD} from "../libraries/Types.sol";

/**
 *  @title  SenzuRiskConfig
 *  @author Senzu
 *  @notice Every risk parameter Senzu reads, keyed per DEX by its adapter (`dex`). The admin is the SenzuFactory
 *          admin; the guardian can only pause supply, borrow and open. A token's σ and liquidation penalty, once
 *          set, can only go down, and the penalty stays at least MIN_INCENTIVE. Everything else can move both ways.
 */
contract SenzuRiskConfig is ISenzuRiskConfig {
    uint256 internal constant MAX_SIGMA = 3e18;
    uint256 internal constant MAX_PENALTY = 1.25e18;
    uint256 internal constant MAX_BORROW_FEE = 0.002e18;
    uint256 internal constant MAX_FEE_CUT = 0.05e18;
    uint256 internal constant MAX_LIQUIDATION_FEE = 0.2e18;
    uint64 internal constant DEFAULT_LIQUIDATION_FEE = 0.1e18;

    /// @dev One slot: a borrow reads its fee and its pause together
    struct Dex {
        uint64 borrowFeeWad;
        uint64 feeCutWad;
        uint64 liquidationFeeWad;
        bool added;
        bool supplyPaused;
        bool borrowPaused;
        bool openPaused;
    }

    mapping(address dex => Dex) internal _dex;
    mapping(address dex => mapping(address token => TokenRisk)) internal _tokenRisk;
    mapping(bytes32 pairKey => bool) internal _pairEnabled;

    /// @inheritdoc ISenzuRiskConfig
    address public immutable override factory;

    constructor(address factory_) {
        factory = factory_;
    }

    modifier onlyAdmin() {
        if (msg.sender != ISenzuFactory(factory).admin()) revert SenzuRiskConfig__NotAdmin();
        _;
    }

    modifier onlyDex(address dex) {
        if (!_dex[dex].added) revert SenzuRiskConfig__UnknownDex(dex);
        _;
    }

    /// @inheritdoc ISenzuRiskConfig
    function isDex(address dex) external view override returns (bool) {
        return _dex[dex].added;
    }

    /// @inheritdoc ISenzuRiskConfig
    function tokenRisk(address dex, address token) external view override returns (TokenRisk memory) {
        return _tokenRisk[dex][token];
    }

    /// @inheritdoc ISenzuRiskConfig
    function pairRisk(address dex, address token0, address token1)
        external
        view
        override
        returns (uint256 sigma0Wad, uint256 sigma1Wad, uint256 penaltyWad)
    {
        mapping(address token => TokenRisk) storage risks = _tokenRisk[dex];
        TokenRisk storage risk0 = risks[token0];
        TokenRisk storage risk1 = risks[token1];
        (sigma0Wad, sigma1Wad) = (risk0.sigmaWad, risk1.sigmaWad);
        (uint256 penalty0, uint256 penalty1) = (risk0.penaltyWad, risk1.penaltyWad);
        penaltyWad = penalty0 > penalty1 ? penalty0 : penalty1;
    }

    /// @inheritdoc ISenzuRiskConfig
    function pairEnabled(bytes32 pairKey) external view override returns (bool) {
        return _pairEnabled[pairKey];
    }

    /// @inheritdoc ISenzuRiskConfig
    function requireListed(address dex, address token0, address token1)
        external
        view
        override
        returns (bytes32 pairKey)
    {
        mapping(address token => TokenRisk) storage risks = _tokenRisk[dex];
        if (!risks[token0].collateralEnabled) revert SenzuRiskConfig__CollateralNotEnabled(token0);
        if (!risks[token1].collateralEnabled) revert SenzuRiskConfig__CollateralNotEnabled(token1);
        pairKey = keccak256(abi.encode(dex, token0, token1));
        if (!_pairEnabled[pairKey]) revert SenzuRiskConfig__PairNotEnabled(pairKey);
    }

    /// @inheritdoc ISenzuRiskConfig
    function borrowFeeWad(address dex) external view override returns (uint64) {
        return _dex[dex].borrowFeeWad;
    }

    /// @inheritdoc ISenzuRiskConfig
    function borrowTerms(address dex) external view override returns (bool paused, uint64 feeWad) {
        Dex storage d = _dex[dex];
        return (d.borrowPaused, d.borrowFeeWad);
    }

    /// @inheritdoc ISenzuRiskConfig
    function feeCut(address dex) external view override returns (uint64 cutWad, address to) {
        return (_dex[dex].feeCutWad, ISenzuFactory(factory).protocolReserves());
    }

    /// @inheritdoc ISenzuRiskConfig
    function liquidationFeeWad(address dex) external view override returns (uint64) {
        return _dex[dex].liquidationFeeWad;
    }

    /// @inheritdoc ISenzuRiskConfig
    function isPaused(address dex, bytes32 action) external view override returns (bool) {
        Dex storage d = _dex[dex];
        if (action == ACTION_SUPPLY) return d.supplyPaused;
        if (action == ACTION_BORROW) return d.borrowPaused;
        return action == ACTION_OPEN && d.openPaused;
    }

    /// @inheritdoc ISenzuRiskConfig
    function addDex(address dex) external override {
        if (msg.sender != factory) revert SenzuRiskConfig__NotFactory();
        if (_dex[dex].added) revert SenzuRiskConfig__DexAlreadyAdded(dex);
        _dex[dex].added = true;
        _dex[dex].liquidationFeeWad = DEFAULT_LIQUIDATION_FEE;
        emit DexAdded(dex);
        emit LiquidationFeeSet(dex, DEFAULT_LIQUIDATION_FEE);
    }

    /// @inheritdoc ISenzuRiskConfig
    function setTokenRisk(address dex, address token, uint64 sigmaWad, uint64 penaltyWad, bool collateralEnabled)
        external
        override
        onlyAdmin
        onlyDex(dex)
    {
        if (sigmaWad < WAD || sigmaWad > MAX_SIGMA) revert SenzuRiskConfig__InvalidSigma();
        if (penaltyWad < MIN_INCENTIVE || penaltyWad > MAX_PENALTY) revert SenzuRiskConfig__InvalidPenalty();
        TokenRisk memory current = _tokenRisk[dex][token];
        if (current.sigmaWad != 0 && (sigmaWad > current.sigmaWad || penaltyWad > current.penaltyWad)) {
            revert SenzuRiskConfig__OnlyInBorrowersFavor();
        }
        _tokenRisk[dex][token] = TokenRisk({
            sigmaWad: sigmaWad, penaltyWad: penaltyWad, collateralEnabled: collateralEnabled, liquid: current.liquid
        });
        emit TokenRiskSet(dex, token, sigmaWad, penaltyWad, collateralEnabled);
    }

    /// @inheritdoc ISenzuRiskConfig
    function setLiquid(address dex, address token) external override onlyAdmin onlyDex(dex) {
        TokenRisk storage risk = _tokenRisk[dex][token];
        ISenzuOracle oracle = ISenzuOracle(ISenzuFactory(factory).oracle());
        // Feeds are write-once, so a token with a feed that can't pause never gets one that can
        (address aggregator,,) = oracle.feedOf(token);
        if (risk.sigmaWad == 0 || aggregator == address(0) || oracle.isPausable(token)) {
            revert SenzuRiskConfig__CannotBeLiquid(token);
        }
        risk.liquid = true;
        emit LiquidSet(dex, token);
    }

    /// @inheritdoc ISenzuRiskConfig
    function setPairEnabled(address dex, address token0, address token1, bool enabled)
        external
        override
        onlyAdmin
        onlyDex(dex)
    {
        bytes32 pairKey = keccak256(abi.encode(dex, token0, token1));
        _pairEnabled[pairKey] = enabled;
        emit PairEnabledSet(dex, pairKey, token0, token1, enabled);
    }

    /// @inheritdoc ISenzuRiskConfig
    function setBorrowFee(address dex, uint64 borrowFeeWad_) external override onlyAdmin onlyDex(dex) {
        if (borrowFeeWad_ > MAX_BORROW_FEE) revert SenzuRiskConfig__InvalidBorrowFee();
        _dex[dex].borrowFeeWad = borrowFeeWad_;
        emit BorrowFeeSet(dex, borrowFeeWad_);
    }

    /// @inheritdoc ISenzuRiskConfig
    function setFeeCut(address dex, uint64 feeCutWad) external override onlyAdmin onlyDex(dex) {
        if (feeCutWad > MAX_FEE_CUT) revert SenzuRiskConfig__InvalidFeeCut();
        _dex[dex].feeCutWad = feeCutWad;
        emit FeeCutSet(dex, feeCutWad);
    }

    /// @inheritdoc ISenzuRiskConfig
    function setLiquidationFee(address dex, uint64 liquidationFeeWad_) external override onlyAdmin onlyDex(dex) {
        if (liquidationFeeWad_ > MAX_LIQUIDATION_FEE) revert SenzuRiskConfig__InvalidLiquidationFee();
        _dex[dex].liquidationFeeWad = liquidationFeeWad_;
        emit LiquidationFeeSet(dex, liquidationFeeWad_);
    }

    /// @inheritdoc ISenzuRiskConfig
    function setPaused(address dex, bytes32 action, bool paused) external override onlyDex(dex) {
        ISenzuFactory senzuFactory = ISenzuFactory(factory);
        if (msg.sender != senzuFactory.guardian() && msg.sender != senzuFactory.admin()) {
            revert SenzuRiskConfig__NotGuardian();
        }
        Dex storage d = _dex[dex];
        if (action == ACTION_SUPPLY) d.supplyPaused = paused;
        else if (action == ACTION_BORROW) d.borrowPaused = paused;
        else if (action == ACTION_OPEN) d.openPaused = paused;
        else revert SenzuRiskConfig__InvalidAction();
        emit PauseSet(dex, action, paused);
    }
}
