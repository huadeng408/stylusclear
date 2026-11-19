// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISettlementEngine
/// @notice Canonical compact struct ABI shared between Arbitrum Stylus (Rust/WASM) and Solidity Benchmark (`v0.7.0`).
interface ISettlementEngine {
    struct ObligationInput {
        uint16 debtor;
        uint16 creditor;
        uint8 assetId;
        uint8 authMode;
        uint8 v;
        uint64 maxEpoch;
        uint256 amountWad;
        uint256 nonce;
        bytes32 r;
        bytes32 s;
    }

    struct SignedTradeIntent {
        uint16 trader;
        uint8 baseAsset;
        uint8 quoteAsset;
        uint8 side;
        uint8 authMode;
        uint8 v;
        uint64 maxEpoch;
        uint256 amountWad;
        uint256 limitPriceWad;
        uint256 nonce;
        bytes32 r;
        bytes32 s;
    }

    error MathOverflow();
    error DivisionByZero();
    error InvalidAssetConfig();
    error InvalidHaircut();
    error StaleMarkPrice();
    error BatchCapacityExceeded();
    error DuplicateParticipant();
    error InvalidObligation();
    error UnauthorizedObligation();
    error InvalidIntent();
    error ExpiredIntent();
    error UnauthorizedCaller();
    error InvalidSignature();
    error NonceAlreadyUsed();
    error AssetConservationViolated();
    error LimitPriceViolated();
    error InsufficientInitialMargin();
    error HealthMonotonicityViolated();
    error InsufficientWithdrawableBalance();

    event AdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event CollateralDeposited(address indexed trader, uint8 indexed assetId, uint256 rawAmount, int256 newBalanceWad);
    event CollateralWithdrawn(address indexed trader, uint8 indexed assetId, uint256 rawAmount, int256 newBalanceWad);
    event SubQuantumDebtRepaid(address indexed trader, uint8 indexed assetId, uint256 rawAmount, int256 newBalanceWad);
    event BadDebtAbsorbed(address indexed backstop, address indexed underwater, uint8 indexed debtAsset, uint256 absorbedWad);
    event FeeVaultSwept(address indexed recipient, uint8 indexed assetId, uint256 sweptWad, uint256 rawAmount);
    event SubQuantumDustSwept(address indexed trader, uint8 indexed assetId, uint256 dustWad);
    event ObligationRegistered(address indexed debtor, address indexed creditor, uint8 indexed assetId, uint256 totalConfirmedWad);
    event ObligationRevoked(address indexed debtor, address indexed creditor, uint8 indexed assetId, uint256 remainingConfirmedWad);
    event NoncesInvalidated(address indexed trader, uint256 indexed wordPos, uint256 mask);
    event SolverApprovalUpdated(address indexed solver, bool approved);
    event AccountLiquidated(
        address indexed liquidator,
        address indexed underwater,
        uint8 indexed debtAsset,
        uint8 collateralAsset,
        uint256 repaidDebtWad,
        uint256 seizedCollateralWad
    );
    event MarketCleared(
        uint64 indexed batchEpoch,
        uint8 indexed baseAsset,
        uint8 indexed quoteAsset,
        uint256 clearingPriceWad,
        uint256 matchedVolumeWad,
        uint256 roundingDustWad
    );
    event BatchTelemetry(uint64 indexed batchEpoch, uint64 wasmInkUsed, uint64 stylusComputeGas);
    event BatchSettled(uint64 indexed batchEpoch, uint32 cyclesEliminated, uint256 totalMatchedVolumeWad);

    function initialize(address initialAdmin, bool benchmarkSeedingEnabled) external;
    function transferAdmin(address newAdmin) external;
    function acceptAdmin() external;
    function pendingAdmin() external view returns (address);

    function configureAsset(
        uint8 assetId,
        address token,
        uint8 decimals,
        uint256 markPriceWad,
        uint16 haircutBps,
        uint16 imBps,
        uint16 mmBps
    ) external;

    function updateMarkPrice(uint8 assetId, uint256 markPriceWad) external;
    function setRiskWindows(uint64 maxStaleness, uint16 maxDeviationBps, bool permissionless) external;
    function setApprovedSolver(address solver, bool approved) external;

    function deposit(uint8 assetId, uint256 rawAmount) external returns (int256 newBalanceWad);
    function withdraw(uint8 assetId, uint256 rawAmount) external returns (int256 newBalanceWad);
    function repaySubQuantumDebt(uint8 assetId) external returns (int256 newBalanceWad);
    function absorbBadDebt(address underwater, uint8 debtAsset) external returns (uint256 absorbedWad);
    function sweepDustToFeeVault(uint8 assetId) external returns (uint256 dustWad);
    function sweepFeeVault(uint8 assetId, address recipient) external returns (uint256 sweptWad);
    function registerObligation(address creditor, uint8 assetId, uint256 amountWad) external returns (uint256 totalConfirmedWad);
    function revokeObligation(address creditor, uint8 assetId, uint256 amountWad) external returns (uint256 remainingConfirmedWad);
    function invalidateNonces(uint256 wordPos, uint256 mask) external returns (uint256 updatedWord);
    function liquidate(
        address underwater,
        uint8 debtAsset,
        uint8 collateralAsset,
        uint256 repayAmountWad
    ) external returns (uint256 repaidDebtWad, uint256 seizedCollateralWad);
    function seedAccountBalance(address trader, uint8 assetId, int256 balanceWad) external;

    function admin() external view returns (address);
    function benchmarkSeedingEnabled() external view returns (bool);
    function permissionlessSolver() external view returns (bool);
    function maxPriceStaleness() external view returns (uint64);
    function maxPriceDeviationBps() external view returns (uint16);
    function approvedSolvers(address solver) external view returns (bool);
    function assetCount() external view returns (uint8);
    function currentEpoch() external view returns (uint64);
    function domainSeparator() external view returns (bytes32);
    function getAccountBalance(address trader, uint8 assetId) external view returns (int256);
    function getConfirmedObligation(address debtor, address creditor, uint8 assetId) external view returns (uint256);
    function getFeeVault(uint8 assetId) external view returns (uint256);
    function getVaultPhysicalRaw(uint8 assetId) external view returns (uint256);
    function getNonceBitmap(address trader, uint256 wordPos) external view returns (uint256);
    function getPartialFill(address trader, uint256 nonce) external view returns (uint256);
    function getAssetConfig(
        uint8 assetId
    )
        external
        view
        returns (
            address token,
            uint8 decimals,
            uint256 markPriceWad,
            uint64 priceUpdatedAt,
            uint16 haircutBps,
            uint16 imBps,
            uint16 mmBps
        );
    function getAccountRisk(
        address trader
    )
        external
        view
        returns (
            uint256 effectiveCollateralWad,
            uint256 totalLiabilityWad,
            uint256 requiredImWad,
            uint256 requiredMmWad,
            int256 healthWad,
            int256 imSurplusWad
        );

    function settleBatch(
        address[] calldata participants,
        ObligationInput[] calldata obligations,
        SignedTradeIntent[] calldata intents
    ) external returns (uint32 cyclesEliminated, uint256 totalMatchedVolumeWad);
}
