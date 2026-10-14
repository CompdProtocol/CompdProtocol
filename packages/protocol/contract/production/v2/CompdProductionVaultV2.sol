// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ICompdProductionVaultView,
    ICompdProductionVaultReceiver,
    ICompdFlapReceiverView,
    ICompdProductionVaultFactoryView,
    ICompdStrategyExecutorIdentity,
    ICompdBuybackExecutorIdentity,
    ICompdStrategyExecutorView,
    ICompdBuybackReserveObserver,
    ICompdStrategyCapitalObserver
} from "../ICompdProductionInterfaces.sol";
import {CompdV2Types, CompdV2KnownRoles, CompdV2Errors} from "./CompdV2Types.sol";
import {ICompdEmergencyVaultV2, ICompdEmergencyEventsV2, ICompdEmergencyModuleV2} from "./ICompdEmergencyVaultV2.sol";
import {ICompdHolderRewardsDistributorV2} from "./ICompdHolderRewardsDistributorV2.sol";
import {ICompdHolderWorkflowV2} from "./ICompdHolderWorkflowV2.sol";
import {ICompdHolderLiabilityV2} from "./ICompdHolderLiabilityV2.sol";
import {ICompdEmergencyRegistryV2} from "./ICompdEmergencyRegistryV2.sol";
import {ICompdProductionVaultV2Decomposition} from "./ICompdProductionVaultV2Decomposition.sol";
import {ICompdVaultBoundComponentV2} from "./ICompdVaultBoundComponentV2.sol";

/// @notice Production accounting vault for COMPD. It is not the Flap receiver.
/// @dev A zero quote token denotes native BNB. Both approved accounting splits are fixed.
contract CompdProductionVaultV2 is AccessControl, ReentrancyGuard, ICompdEmergencyVaultV2, ICompdEmergencyEventsV2, ICompdProductionVaultV2Decomposition {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint64 public constant EMPTY_REVIEW_SECONDS = 1_800;
    uint16 public constant LOCAL_ASSET_MANIFEST_CAP_CANDIDATE = 16;
    uint256 public constant REVENUE_STRATEGY_BPS = 3_500;
    uint256 public constant REVENUE_BUYBACK_BPS = 1_500;
    uint256 public constant REVENUE_PROTOCOL_BPS = 5_000;
    uint256 public constant PROFIT_COMPOUND_BPS = 6_500;
    uint256 public constant PROFIT_BUYBACK_BPS = 1_500;
    uint256 public constant PROFIT_HOLDER_REWARD_BPS = 1_000;
    uint256 public constant PROFIT_PROTOCOL_BPS = 1_000;
    uint64 public constant MIN_SHUTDOWN_DELAY = 72 hours;
    uint64 public constant HOLDER_WINDOW_SECONDS = 28_800;
    uint64 public constant TERMINAL_GRACE_SECONDS = 7_776_000;
    bytes32 public constant HOLDER_PROTOCOL_ID = keccak256("COMPD_HOLDER_REWARDS_V2");
    bytes32 public constant HOLDER_DOMAIN_TYPEHASH = keccak256(
        "CompdHolderRewardsDomain(bytes32 protocolId,uint256 chainId,address compdToken,address vault,address distributor,address rewardAsset)"
    );
    bytes32 public constant HOLDER_WINDOW_TYPEHASH = keccak256(
        "CompdHolderRewardWindow(bytes32 domainSeparator,uint256 activationBlock,bytes32 activationBlockHash,uint64 activationTimestamp,uint64 windowStart,uint64 windowEnd)"
    );
    bytes32 public constant HOLDER_DISTRIBUTION_TYPEHASH = keccak256(
        "CompdHolderRewardDistribution(bytes32 domainSeparator,bytes32 windowId)"
    );

    address public constant GUARDIAN = 0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    address public constant RECOVERY_WALLET = 0xFa8706AA97B07cb29096381f9101784bA0d1332b;
    address public constant override RECOVERY_TREASURY = 0xFa8706AA97B07cb29096381f9101784bA0d1332b;
    address public constant AUTOMATION_EXECUTOR = 0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;
    address public constant COMPD_TOKEN = 0x7b7Af51136574c91A12988989c0a08E98aE97777;
    address public constant BUYBACK_ADMIN = 0x29BB16dB8e9f2371255BA75aF83aECaFB2CC00BA;

    bytes32 public constant PROTOCOL_RESERVE_SPENDER_ROLE = keccak256("PROTOCOL_RESERVE_SPENDER_ROLE");
    bytes32 public constant HOLDER_REWARD_SETTLER_ROLE = keccak256("HOLDER_REWARD_SETTLER_ROLE");

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidLifecycle();
    error AccountingInvariant();
    error InsufficientFreeCapital();
    error InvalidRun();
    error InvalidAmount();
    error ShutdownNotReady();
    error OutstandingLiabilities();
    error NotSurplus();
    error InvalidRecipient();
    error HolderRewardsNotConfigured();
    error InvalidHolderContext();
    error HolderEntryUnavailable();
    error HolderReviewActive();
    error HolderReconciliationIncomplete();
    error HolderGraceActive();
    error EmergencyModeActive();
    error EmergencyAssetUnknown();
    error InvalidEmergencyConfiguration();
    error TokenCallFailed();

    address public immutable override quoteToken;
    address public immutable override compdToken = CompdV2KnownRoles.RESERVED_COMPD_IDENTITY;
    address public immutable configurationAdmin;
    address public immutable override emergencyRecoveryAuthority;
    address public immutable override emergencyRecoveryWallet;
    CompdV2Types.Lifecycle public override lifecycle = CompdV2Types.Lifecycle.PAUSED;
    address public strategyExecutor;
    address public buybackExecutor;
    address public receiverFactory;
    address public flapReceiver;
    address public override holderWorkflow;
    address public override holderLiability;
    address public override emergencyRegistry;
    bytes32 public immutable override expectedHolderWorkflowRuntimeCodeHash;
    bytes32 public immutable override expectedHolderLiabilityRuntimeCodeHash;
    bytes32 public immutable override expectedEmergencyRegistryRuntimeCodeHash;

    // Live accounting buckets. Strategy Capital includes principal currently allocated to open positions.
    uint256 public strategyCapital;
    uint256 public activePrincipal;
    uint256 public buybackReserve;
    uint256 public protocolReserve;
    uint256 public holderRewardReserve;
    uint256 public accountedQuote;
    uint256 public activeStrategyRuns;

    // Lifetime totals remain available after recovery; they are never cleared by the recovery path.
    uint256 public cumulativeRevenue;
    uint256 public cumulativeRealizedProfit;
    uint256 public cumulativeRealizedLoss;
    uint256 public recoveredStrategyCapital;
    uint256 public recoveredBuybackReserve;
    uint256 public recoveredProtocolReserve;
    uint256 public recoveredHolderRewards;
    mapping(address => uint256) public recoveredSurplus;
    mapping(address => uint256) public recoveredOtherAssets;

    uint64 public shutdownStartedAt;
    uint64 public shutdownAt;
    mapping(uint256 => uint256) public runPrincipal;
    mapping(uint256 => bool) public runUsed;
    mapping(address => bool) public allowedProtocolRecipient;
    mapping(address => uint256) public quarantinedSurplus;

    // ABI compatibility view only; entry storage belongs exclusively to Liability.
    enum HolderEntryStatus {
        NONE,
        CANDIDATE_REVIEW,
        COMMITTED_UNPAID,
        FAILED_PENDING_MANUAL,
        TERMINAL_PENDING,
        TERMINAL_EXPIRED,
        PAID
    }

    struct HolderEntry {
        address recipient;
        uint256 amount;
        uint64 terminalGraceStartAt;
        uint32 version;
        HolderEntryStatus status;
        bool manualSettlementAvailable;
    }

    address public holderRewardsDistributor;
    uint256 public holderRewardsActivationBlock;
    bytes32 public holderRewardsActivationBlockHash;
    uint64 public holderRewardsActivationTimestamp;
    bool public holderRewardsActivationConfigured;
    // All per-window pools, candidates, entries and terminal/recovery records live in the bound components.

    address[] private _assetManifest;
    mapping(address => bool) private _assetRegistered;
    mapping(uint8 => mapping(address => CompdV2Types.EmergencyAssetRecord)) private _emergencyAssetRecords;
    mapping(bytes32 => uint32) private _emergencyAttemptCounts;
    mapping(bytes32 => mapping(uint32 => CompdV2Types.EmergencyAttempt)) private _emergencyAttempts;
    mapping(uint8 => mapping(address => uint256[2])) private _emergencyOutflow;
    mapping(uint8 => mapping(address => uint32)) private _emergencyFailures;
    mapping(uint256 => CompdV2Types.EmergencyRunStatus) private _emergencyRunStatuses;
    uint64 private _snapshotNonce;
    bytes32 private _snapshotId;
    uint64 private _emergencyStartedAt;
    uint64 private _emergencyStartedBlock;
    address private _emergencyInitiatedBy;
    CompdV2Types.EmergencyProcessingStatus private _emergencyProcessingStatus;
    CompdV2Types.EmergencySnapshot private _emergencySnapshot;
    CompdV2Types.EmergencyReconciliation private _emergencyReconciliation;
    uint256 private _preEmergencyHolderDeficit;
    uint256 public cumulativeQuoteEmergencyOutflow;
    uint256[] private _activeRunIds;
    mapping(uint256 => uint256) private _activeRunIndexPlusOne;

    event RevenueReceived(uint256 amount, uint256 strategy, uint256 buyback, uint256 protocol);
    event RealizedProfitRouted(
        uint256 indexed runId,
        uint256 profit,
        uint256 compound,
        uint256 buyback,
        uint256 holderReward,
        uint256 protocol,
        bytes32 indexed windowId,
        uint64 windowStart,
        uint64 windowEnd
    );
    event HolderRewardsActivationConfigured(uint256 activationBlock, bytes32 activationBlockHash, uint64 activationTimestamp);
    event HolderRewardsDistributorBound(address indexed distributor);
    event HolderPoolAccrued(
        uint256 indexed runId,
        bytes32 indexed windowId,
        uint64 windowStart,
        uint64 windowEnd,
        uint256 realizedProfit,
        uint256 holderAllocation
    );
    event HolderDistributionReserved(
        bytes32 indexed distributionId, bytes32 indexed windowId, uint32 version, uint256 totalPayable, uint64 acceptedAt, uint64 executableAfter
    );
    event HolderLiabilityRegistered(
        bytes32 indexed distributionId, bytes32 indexed windowId, uint32 version, uint16 recipientIndex, address recipient, uint256 amount
    );
    event HolderDistributionFinalized(bytes32 indexed distributionId, uint32 version, uint256 totalPayable);
    event HolderDistributionCorrected(
        bytes32 indexed distributionId,
        bytes32 indexed windowId,
        uint32 oldVersion,
        uint32 newVersion,
        uint64 acceptedAt,
        uint64 executableAfter,
        uint256 replacementTotal,
        uint16 expectedEntryCount
    );
    event HolderPayoutSucceeded(
        bytes32 indexed distributionId, bytes32 indexed windowId, uint32 version, uint16 recipientIndex, address recipient, uint256 amount, bool manual
    );
    event HolderPayoutFailed(bytes32 indexed distributionId, bytes32 indexed windowId, uint32 version, uint16 recipientIndex, address recipient, uint256 amount);
    event HolderManualSettlementAvailable(bytes32 indexed distributionId, uint32 version, bytes32 indexed windowId, uint16 recipientIndex);
    event HolderTerminalPending(bytes32 indexed distributionId, bytes32 indexed windowId, uint32 version, uint16 recipientIndex, uint64 graceStartAt, uint64 deadline);
    event HolderLiabilityExpired(bytes32 indexed distributionId, bytes32 indexed windowId, uint32 version, uint16 recipientIndex, uint256 amount);
    event HolderWindowClassifiedUnallocated(bytes32 indexed windowId, uint256 amount);
    event HolderRecoveryEligibilityClassified(uint256 amount);
    event HolderRewardsRecovered(uint256 amount, address indexed recoveryTreasury);
    event RealizedLossRecorded(uint256 indexed runId, uint256 loss, uint256 remainingStrategyCapital);
    event StrategyPrincipalAllocated(uint256 indexed runId, uint256 amount);
    event StrategyPositionSettled(uint256 indexed runId, uint256 principal, uint256 returnedAmount);
    event ExecutorBound(bytes32 indexed executorType, address indexed executor);
    event ReceiverFactoryBound(address indexed factory);
    event FlapReceiverRegistered(address indexed receiver);
    event ProtocolRecipientUpdated(address indexed recipient, bool allowed);
    event ProtocolReserveSpent(address indexed recipient, uint256 amount, bytes32 indexed category);
    event LifecycleChanged(CompdV2Types.Lifecycle indexed previousState, CompdV2Types.Lifecycle indexed newState);
    event ShutdownInitiated(uint64 startedAt, uint64 shutdownAt);
    event ShutdownExtended(uint64 newShutdownAt);
    event ShutdownTerminated(uint64 terminatedAt);
    event SurplusQuarantined(address indexed asset, uint256 amount, uint256 totalQuarantined);
    event TerminationRecovery(address indexed asset, uint256 amount, uint256 strategy, uint256 buyback, uint256 protocol, uint256 surplus);
    event EmptyCandidateSubmitted(bytes32 indexed windowId, bytes32 indexed distributionId, uint32 version, uint256 amount, uint64 acceptedAt, uint64 executableAfter, bytes32 evidenceHash);
    event EmptyCandidateCorrected(bytes32 indexed windowId, uint32 oldVersion, uint32 newVersion, bytes32 reasonHash, uint64 acceptedAt, uint64 executableAfter);
    event EmptyCandidateFinalized(bytes32 indexed windowId, uint32 version, uint256 amount, bytes32 evidenceHash);
    event EmptyNoRecipientPoolRecoveryEligible(bytes32 indexed windowId, uint256 amount, bytes32 evidenceHash);
    event NoRecipientPoolRecovered(bytes32 indexed windowId, uint256 amount, address indexed treasury);
    event EmergencyAssetDiscovered(bytes32 indexed snapshotId, address indexed asset, uint64 discoveredAt, uint64 discoveredBlock);
    event EmergencyAssetWithdrawalAttempted(bytes32 indexed snapshotId, bytes32 indexed attemptId, address indexed asset, uint32 attemptNumber, uint256 beforeBalance);
    event EmergencyAssetWithdrawalResult(bytes32 indexed snapshotId, bytes32 indexed attemptId, address indexed asset, uint256 amountDebited, uint256 amountCredited, CompdV2Types.EmergencyAttemptOutcome outcome, bytes32 failureCode, bytes32 revertDataHash);

    modifier onlyGuardian() {
        if (msg.sender != GUARDIAN) revert Unauthorized();
        _;
    }

    modifier onlyConfigAdmin() {
        _checkRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _;
    }

    modifier onlyLifecycle(CompdV2Types.Lifecycle requiredState) {
        if (lifecycle != requiredState) revert InvalidLifecycle();
        _;
    }

    constructor(
        address quoteToken_,
        address configurationAdmin_,
        address emergencyAuthority_,
        address emergencyWallet_,
        bytes32 expectedHolderWorkflowRuntimeCodeHash_,
        bytes32 expectedHolderLiabilityRuntimeCodeHash_,
        bytes32 expectedEmergencyRegistryRuntimeCodeHash_
    ) {
        if (configurationAdmin_ == address(0) || emergencyAuthority_ == address(0) || emergencyWallet_ == address(0)) {
            revert CompdV2Errors.InvalidImmutableConfiguration();
        }
        if (emergencyAuthority_ == emergencyWallet_ || configurationAdmin_ == emergencyAuthority_ || configurationAdmin_ == emergencyWallet_) {
            revert CompdV2Errors.InvalidImmutableConfiguration();
        }
        if (_forbiddenEmergencyRole(emergencyAuthority_) || _forbiddenEmergencyRole(emergencyWallet_)) {
            revert CompdV2Errors.InvalidImmutableConfiguration();
        }
        if (quoteToken_ != address(0) && quoteToken_.code.length == 0) revert InvalidConfiguration();
        if (
            expectedHolderWorkflowRuntimeCodeHash_ == bytes32(0)
                || expectedHolderLiabilityRuntimeCodeHash_ == bytes32(0)
                || expectedEmergencyRegistryRuntimeCodeHash_ == bytes32(0)
        ) revert CompdV2Errors.InvalidImmutableConfiguration();
        quoteToken = quoteToken_;
        configurationAdmin = configurationAdmin_;
        emergencyRecoveryAuthority = emergencyAuthority_;
        emergencyRecoveryWallet = emergencyWallet_;
        expectedHolderWorkflowRuntimeCodeHash = expectedHolderWorkflowRuntimeCodeHash_;
        expectedHolderLiabilityRuntimeCodeHash = expectedHolderLiabilityRuntimeCodeHash_;
        expectedEmergencyRegistryRuntimeCodeHash = expectedEmergencyRegistryRuntimeCodeHash_;
        _grantRole(DEFAULT_ADMIN_ROLE, configurationAdmin_);
        _addInitialEmergencyAsset(quoteToken_);
        _addInitialEmergencyAsset(COMPD_TOKEN);
        if (quoteToken_ != address(0)) _addInitialEmergencyAsset(address(0));
    }

    receive() external payable {
        // Direct native transfers are unaccounted surplus. Flap revenue is credited only
        // through registerFlapRevenue from the bound, separately deployed receiver.
    }

    function bindStrategyExecutor(address executor) external onlyConfigAdmin onlyLifecycle(CompdV2Types.Lifecycle.PAUSED) {
        if (strategyExecutor != address(0) || executor.code.length == 0) revert InvalidConfiguration();
        if (ICompdEmergencyModuleV2(executor).vault() != address(this)) revert InvalidConfiguration();
        strategyExecutor = executor;
        _addInitialEmergencyAsset(address(0));
        emit ExecutorBound(keccak256("STRATEGY"), executor);
    }

    function bindBuybackExecutor(address executor) external onlyConfigAdmin onlyLifecycle(CompdV2Types.Lifecycle.PAUSED) {
        if (buybackExecutor != address(0) || executor.code.length == 0) revert InvalidConfiguration();
        if (ICompdEmergencyModuleV2(executor).vault() != address(this)) revert InvalidConfiguration();
        buybackExecutor = executor;
        _addInitialEmergencyAsset(address(0));
        emit ExecutorBound(keccak256("BUYBACK"), executor);
    }

    function bindReceiverFactory(address factory) external onlyConfigAdmin onlyLifecycle(CompdV2Types.Lifecycle.PAUSED) {
        if (receiverFactory != address(0) || factory.code.length == 0) revert InvalidConfiguration();
        ICompdProductionVaultFactoryView candidate = ICompdProductionVaultFactoryView(factory);
        if (candidate.productionVault() != address(this) || candidate.COMPD_TOKEN() != COMPD_TOKEN) {
            revert InvalidConfiguration();
        }
        receiverFactory = factory;
        emit ReceiverFactoryBound(factory);
    }

    /// @notice Called by the bound Flap factory after its new receiver has been deployed.
    function registerFlapReceiver(address receiver) external {
        if (msg.sender != receiverFactory || receiverFactory == address(0)) revert Unauthorized();
        if (lifecycle != CompdV2Types.Lifecycle.PAUSED) revert InvalidLifecycle();
        if (flapReceiver != address(0) || receiver.code.length == 0) revert InvalidConfiguration();
        if (strategyExecutor == address(0) || buybackExecutor == address(0)) revert InvalidConfiguration();
        ICompdFlapReceiverView candidate = ICompdFlapReceiverView(receiver);
        if (
            candidate.productionVault() != address(this) || candidate.factory() != receiverFactory
                || candidate.taxToken() != COMPD_TOKEN
        ) {
            revert InvalidConfiguration();
        }
        if (candidate.vaultQuoteToken() != quoteToken) revert InvalidConfiguration();
        flapReceiver = receiver;
        emit FlapReceiverRegistered(receiver);
    }

    function setProtocolRecipient(address recipient, bool allowed)
        external
        onlyConfigAdmin
        onlyLifecycle(CompdV2Types.Lifecycle.PAUSED)
    {
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        allowedProtocolRecipient[recipient] = allowed;
        emit ProtocolRecipientUpdated(recipient, allowed);
    }

    function grantRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        if (lifecycle != CompdV2Types.Lifecycle.PAUSED) revert InvalidLifecycle();
        super.grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        if (lifecycle != CompdV2Types.Lifecycle.PAUSED) revert InvalidLifecycle();
        super.revokeRole(role, account);
    }

    function resume() external onlyGuardian onlyLifecycle(CompdV2Types.Lifecycle.PAUSED) {
        ActivationReadiness memory readiness = _activationReadiness();
        (,, bool holderInvariant) = holderPartitionInvariant();
        if (
            strategyExecutor == address(0) || buybackExecutor == address(0) || flapReceiver == address(0)
                || !holderRewardsActivationConfigured || holderRewardsDistributor == address(0)
                || block.timestamp < _firstHolderWindowStart()
                || !readiness.holderWorkflowIdentityValid || !readiness.holderLiabilityIdentityValid
                || !readiness.registryIdentityValid || !readiness.requiredRolesConfigured
                || !readiness.immutableDestinationsValid || !holderInvariant
        ) {
            revert InvalidConfiguration();
        }
        _assertAccounting();
        _setLifecycle(CompdV2Types.Lifecycle.ACTIVE);
    }

    /// @notice One-time deployment fact supplied from the independently verified canonical token checkpoint.
    /// @dev This is immutable after setup. External finality/reorg verification remains a deployment gate.
    function configureHolderRewardsActivation(uint256 activationBlock, bytes32 activationBlockHash, uint64 activationTimestamp)
        external
        onlyConfigAdmin
        onlyLifecycle(CompdV2Types.Lifecycle.PAUSED)
    {
        if (
            holderRewardsActivationConfigured || activationBlock == 0 || activationBlockHash == bytes32(0)
                || activationTimestamp == 0 || activationTimestamp > block.timestamp
        ) revert InvalidHolderContext();
        holderRewardsActivationConfigured = true;
        holderRewardsActivationBlock = activationBlock;
        holderRewardsActivationBlockHash = activationBlockHash;
        holderRewardsActivationTimestamp = activationTimestamp;
        emit HolderRewardsActivationConfigured(activationBlock, activationBlockHash, activationTimestamp);
    }

    /// @notice Irreversible, fail-closed binding. No Distributor address is assigned in this source.
    function bindHolderRewardsDistributor(address distributor) external onlyConfigAdmin onlyLifecycle(CompdV2Types.Lifecycle.PAUSED) {
        if (holderRewardsDistributor != address(0) || distributor.code.length == 0) revert InvalidConfiguration();
        if (ICompdHolderRewardsDistributorV2(distributor).vault() != address(this)) revert InvalidConfiguration();
        holderRewardsDistributor = distributor;
        emit HolderRewardsDistributorBound(distributor);
    }

    function bindHolderWorkflow(address component) external override {
        _requireBindingAuthority();
        if (holderWorkflow != address(0)) revert BindingAlreadySet();
        _validateComponent(component, expectedHolderWorkflowRuntimeCodeHash, keccak256("COMPD_HOLDER_WORKFLOW_V2"));
        holderWorkflow = component;
        emit HolderWorkflowBound(component, expectedHolderWorkflowRuntimeCodeHash);
    }

    function bindHolderLiability(address component) external override {
        _requireBindingAuthority();
        if (holderLiability != address(0)) revert BindingAlreadySet();
        _validateComponent(component, expectedHolderLiabilityRuntimeCodeHash, keccak256("COMPD_HOLDER_LIABILITY_V2"));
        holderLiability = component;
        emit HolderLiabilityBound(component, expectedHolderLiabilityRuntimeCodeHash);
    }

    function bindEmergencyRegistry(address component) external override {
        _requireBindingAuthority();
        if (emergencyRegistry != address(0)) revert BindingAlreadySet();
        _validateComponent(component, expectedEmergencyRegistryRuntimeCodeHash, keccak256("COMPD_EMERGENCY_REGISTRY_V2"));
        emergencyRegistry = component;
        emit EmergencyRegistryBound(component, expectedEmergencyRegistryRuntimeCodeHash);
    }

    function _requireBindingAuthority() private view {
        if (msg.sender != configurationAdmin) revert OnlyConfigurationAdmin();
        if (lifecycle != CompdV2Types.Lifecycle.PAUSED) revert BindingRequiresPaused();
    }

    function _validateComponent(address component, bytes32 expectedHash, bytes32 expectedType) private view {
        if (component == address(0) || component.code.length == 0) revert InvalidComponentAddress();
        if (expectedHash == bytes32(0) || component.codehash != expectedHash) revert ComponentCodeHashMismatch();
        ICompdVaultBoundComponentV2 candidate = ICompdVaultBoundComponentV2(component);
        try candidate.COMPONENT_TYPE_ID() returns (bytes32 typeId) {
            if (typeId != expectedType) revert InvalidComponentType();
        } catch { revert InvalidComponentType(); }
        try candidate.COMPONENT_VERSION() returns (uint32 version) {
            if (version != 2) revert InvalidComponentVersion();
        } catch { revert InvalidComponentVersion(); }
        try candidate.vault() returns (address componentVault) {
            if (componentVault != address(this)) revert InvalidComponentVault();
        } catch { revert InvalidComponentVault(); }
    }

    function activationReadiness() external view override returns (ActivationReadiness memory r) {
        return _activationReadiness();
    }

    function _activationReadiness() private view returns (ActivationReadiness memory r) {
        r.paused = lifecycle == CompdV2Types.Lifecycle.PAUSED;
        r.holderWorkflowBound = holderWorkflow != address(0);
        r.holderLiabilityBound = holderLiability != address(0);
        r.emergencyRegistryBound = emergencyRegistry != address(0);
        r.holderWorkflowRuntimeHashValid = r.holderWorkflowBound && holderWorkflow.codehash == expectedHolderWorkflowRuntimeCodeHash;
        r.holderLiabilityRuntimeHashValid = r.holderLiabilityBound && holderLiability.codehash == expectedHolderLiabilityRuntimeCodeHash;
        r.registryRuntimeHashValid = r.emergencyRegistryBound && emergencyRegistry.codehash == expectedEmergencyRegistryRuntimeCodeHash;
        r.holderWorkflowIdentityValid = r.holderWorkflowRuntimeHashValid && _identityMatches(holderWorkflow, keccak256("COMPD_HOLDER_WORKFLOW_V2"));
        r.holderLiabilityIdentityValid = r.holderLiabilityRuntimeHashValid && _identityMatches(holderLiability, keccak256("COMPD_HOLDER_LIABILITY_V2"));
        r.registryIdentityValid = r.registryRuntimeHashValid && _identityMatches(emergencyRegistry, keccak256("COMPD_EMERGENCY_REGISTRY_V2"));
        r.requiredRolesConfigured = configurationAdmin != address(0) && emergencyRecoveryAuthority != address(0)
            && emergencyRecoveryWallet != address(0) && strategyExecutor != address(0) && buybackExecutor != address(0)
            && flapReceiver != address(0) && holderRewardsDistributor != address(0);
        r.immutableDestinationsValid = RECOVERY_TREASURY == RECOVERY_WALLET
            && emergencyRecoveryWallet != emergencyRecoveryAuthority && emergencyRecoveryWallet != RECOVERY_TREASURY;
    }

    function _identityMatches(address component, bytes32 expectedType) private view returns (bool) {
        if (component == address(0)) return false;
        try ICompdHolderWorkflowV2(component).COMPONENT_TYPE_ID() returns (bytes32 typeId) {
            if (typeId != expectedType) return false;
        } catch { return false; }
        try ICompdHolderWorkflowV2(component).COMPONENT_VERSION() returns (uint32 version) {
            if (version != 2) return false;
        } catch { return false; }
        try ICompdHolderWorkflowV2(component).vault() returns (address componentVault) {
            return componentVault == address(this);
        } catch { return false; }
    }

    function holderPartitionTotals() public view override returns (HolderPartitionTotals memory p) {
        if (holderWorkflow == address(0) || holderLiability == address(0)) revert ActivationGraphIncomplete();
        ICompdHolderWorkflowV2.SourcePartitions memory w = ICompdHolderWorkflowV2(holderWorkflow).sourcePartitions();
        ICompdHolderLiabilityV2.SourcePartitions memory l = ICompdHolderLiabilityV2(holderLiability).sourcePartitions();
        p.unfinalizedWindowPools = w.unfinalizedWindowPools;
        p.normalReviewPools = w.normalReviewPools;
        p.emptyReviewPools = w.emptyReviewPools;
        p.finalizedNoRecipientPools = w.finalizedNoRecipientPools;
        p.noRecipientRecoveryEligible = w.noRecipientRecoveryEligible;
        p.finalizedUnpaidLiabilities = l.finalizedUnpaidLiabilities;
        p.expiredLiabilityRecoveryEligible = l.expiredLiabilityRecoveryEligible;
        p.recoveryEligible = w.noRecipientRecoveryEligible + l.expiredLiabilityRecoveryEligible;
        p.openNormalReviews = w.openNormalReviews;
        p.openEmptyReviews = w.openEmptyReviews;
        p.pendingAutomatic = l.pendingAutomatic;
        p.failedUnavailable = l.failedUnavailable;
        p.finalizedUnpaidRecords = l.finalizedUnpaidRecords;
        p.terminalPendingRecords = l.terminalPendingRecords;
    }

    function holderPartitionInvariant() public view override returns (uint256 reserve, uint256 sum, bool holds) {
        HolderPartitionTotals memory p = holderPartitionTotals();
        reserve = holderRewardReserve;
        sum = p.unfinalizedWindowPools + p.normalReviewPools + p.emptyReviewPools
            + p.finalizedUnpaidLiabilities + p.finalizedNoRecipientPools
            + p.noRecipientRecoveryEligible + p.expiredLiabilityRecoveryEligible;
        holds = reserve == sum;
    }

    function classifyNoRecipientPoolsForRecovery(bytes32[] calldata) external pure override {
        revert CompdV2Errors.ImplementationDeferred();
    }

    function holderDomainSeparator() public view returns (bytes32) {
        if (holderRewardsDistributor == address(0)) revert HolderRewardsNotConfigured();
        return keccak256(
            abi.encode(HOLDER_DOMAIN_TYPEHASH, HOLDER_PROTOCOL_ID, block.chainid, COMPD_TOKEN, address(this), holderRewardsDistributor, quoteToken)
        );
    }

    function holderWindowId(uint64 windowStart, uint64 windowEnd) public view returns (bytes32) {
        if (!holderRewardsActivationConfigured || windowEnd != windowStart + HOLDER_WINDOW_SECONDS || windowStart % HOLDER_WINDOW_SECONDS != 0) {
            revert InvalidHolderContext();
        }
        uint256 firstStart = uint256(holderRewardsActivationTimestamp) / HOLDER_WINDOW_SECONDS * HOLDER_WINDOW_SECONDS;
        if (firstStart < holderRewardsActivationTimestamp) firstStart += HOLDER_WINDOW_SECONDS;
        if (windowStart < firstStart) revert InvalidHolderContext();
        return keccak256(
            abi.encode(
                HOLDER_WINDOW_TYPEHASH,
                holderDomainSeparator(),
                holderRewardsActivationBlock,
                holderRewardsActivationBlockHash,
                holderRewardsActivationTimestamp,
                windowStart,
                windowEnd
            )
        );
    }

    function holderRewardEntry(bytes32 distributionId, uint16 recipientIndex) external view returns (HolderEntry memory) {
        if (holderWorkflow == address(0) || holderLiability == address(0)) return HolderEntry(address(0), 0, 0, 0, HolderEntryStatus.NONE, false);
        ICompdHolderWorkflowV2.DistributionRecord memory d = ICompdHolderWorkflowV2(holderWorkflow).distribution(distributionId);
        if (d.currentVersion == 0) return HolderEntry(address(0), 0, 0, 0, HolderEntryStatus.NONE, false);
        ICompdHolderLiabilityV2.EntryRecord memory e = ICompdHolderLiabilityV2(holderLiability).entry(distributionId, d.currentVersion, recipientIndex);
        HolderEntryStatus status = HolderEntryStatus.NONE;
        if (e.status == ICompdHolderLiabilityV2.EntryStatus.COMMITTED_UNPAID) status = HolderEntryStatus.COMMITTED_UNPAID;
        else if (e.status == ICompdHolderLiabilityV2.EntryStatus.FAILED_PENDING_MANUAL) status = HolderEntryStatus.FAILED_PENDING_MANUAL;
        else if (e.status == ICompdHolderLiabilityV2.EntryStatus.TERMINAL_PENDING) status = HolderEntryStatus.TERMINAL_PENDING;
        else if (e.status == ICompdHolderLiabilityV2.EntryStatus.TERMINAL_EXPIRED) status = HolderEntryStatus.TERMINAL_EXPIRED;
        else if (e.status == ICompdHolderLiabilityV2.EntryStatus.PAID) status = HolderEntryStatus.PAID;
        return HolderEntry(e.recipient, e.amount, e.terminalStartedAt, e.version, status,
            e.manualSettlementStatus == ICompdHolderLiabilityV2.ManualSettlementStatus.AVAILABLE);
    }

    /// @notice Minimal current-version query for the bound Distributor.
    function holderDistributionVersion(bytes32 distributionId) external view returns (uint32) {
        if (holderWorkflow == address(0)) return 0;
        return ICompdHolderWorkflowV2(holderWorkflow).distribution(distributionId).currentVersion;
    }

    function holderRewardPool(bytes32 windowId) external view returns (uint256) {
        if (holderWorkflow == address(0)) return 0;
        return ICompdHolderWorkflowV2(holderWorkflow).windowPool(windowId);
    }

    function holderUnfinalizedWindowPoolTotal() public view returns (uint256) { return holderPartitionTotals().unfinalizedWindowPools; }
    function holderCandidateReviewPoolTotal() public view returns (uint256) { return holderPartitionTotals().normalReviewPools; }
    function emptyCandidateReviewPoolTotal() public view returns (uint256) { return holderPartitionTotals().emptyReviewPools; }
    function holderFinalizedUnpaidLiabilityTotal() public view returns (uint256) { return holderPartitionTotals().finalizedUnpaidLiabilities; }
    function holderUnallocatedNoRecipientPoolTotal() public view returns (uint256) { return holderPartitionTotals().finalizedNoRecipientPools; }
    function holderRecoveryEligibleTotal() public view returns (uint256) { return holderPartitionTotals().recoveryEligible; }
    function holderPendingAutomaticEntryCount() public view returns (uint256) { return holderPartitionTotals().pendingAutomatic; }
    function holderFailedNotAvailableCount() public view returns (uint256) { return holderPartitionTotals().failedUnavailable; }
    function openEmptyReviewCount() public view returns (uint256) { return holderPartitionTotals().openEmptyReviews; }
    function terminalLiabilityCount() public view returns (uint256) { return holderPartitionTotals().terminalPendingRecords; }

    function pause() external onlyGuardian onlyLifecycle(CompdV2Types.Lifecycle.ACTIVE) {
        _setLifecycle(CompdV2Types.Lifecycle.PAUSED);
    }

    function initiateShutdown() external onlyGuardian {
        if (lifecycle != CompdV2Types.Lifecycle.ACTIVE && lifecycle != CompdV2Types.Lifecycle.PAUSED) revert InvalidLifecycle();
        uint64 started = uint64(block.timestamp);
        shutdownStartedAt = started;
        shutdownAt = started + MIN_SHUTDOWN_DELAY;
        _setLifecycle(CompdV2Types.Lifecycle.SHUTDOWN_PENDING);
        emit ShutdownInitiated(started, shutdownAt);
    }

    function extendShutdown(uint64 newShutdownAt) external onlyGuardian onlyLifecycle(CompdV2Types.Lifecycle.SHUTDOWN_PENDING) {
        if (newShutdownAt <= shutdownAt) revert InvalidConfiguration();
        shutdownAt = newShutdownAt;
        emit ShutdownExtended(newShutdownAt);
    }

    function terminate() external onlyGuardian onlyLifecycle(CompdV2Types.Lifecycle.SHUTDOWN_PENDING) {
        if (block.timestamp < shutdownAt) revert ShutdownNotReady();
        if (activePrincipal != 0 || activeStrategyRuns != 0) {
            revert OutstandingLiabilities();
        }
        if (strategyExecutor == address(0) || !ICompdStrategyExecutorView(strategyExecutor).canFinalizeShutdown()) {
            revert OutstandingLiabilities();
        }
        if (flapReceiver != address(0) && ICompdFlapReceiverView(flapReceiver).accountedQuote() != 0) {
            revert OutstandingLiabilities();
        }
        _assertAccounting();
        _setLifecycle(CompdV2Types.Lifecycle.TERMINATED);
        emit ShutdownTerminated(uint64(block.timestamp));
    }

    /// @notice The registered Receiver may forward its reported amount; ERC-20 V3 balance deltas
    ///         cannot prove that an unobserved donation was not included. See integration docs.
    function registerFlapRevenue(uint256 amount) external payable nonReentrant {
        if (msg.sender != flapReceiver || flapReceiver == address(0)) revert Unauthorized();
        if (amount == 0) revert InvalidAmount();
        if (quoteToken == address(0)) {
            if (msg.value != amount) revert InvalidAmount();
        } else {
            if (msg.value != 0) revert InvalidAmount();
            uint256 balance = IERC20(quoteToken).balanceOf(address(this));
            if (balance < accountedQuote + amount) revert InvalidAmount();
        }

        accountedQuote += amount;
        cumulativeRevenue += amount;
        uint256 strategyPart = amount * REVENUE_STRATEGY_BPS / BPS;
        uint256 buybackPart = amount * REVENUE_BUYBACK_BPS / BPS;
        uint256 protocolPart = amount - strategyPart - buybackPart;
        _checkpointBuybackReserve();
        _checkpointStrategyCapital();
        strategyCapital += strategyPart;
        buybackReserve += buybackPart;
        protocolReserve += protocolPart;
        _assertAccounting();
        emit RevenueReceived(amount, strategyPart, buybackPart, protocolPart);
    }

    function allocateStrategyPrincipal(uint256 runId, uint256 amount) external nonReentrant {
        if (msg.sender != strategyExecutor) revert Unauthorized();
        if (lifecycle != CompdV2Types.Lifecycle.ACTIVE) revert InvalidLifecycle();
        if (amount == 0 || runUsed[runId] || _activeRunIds.length >= 3) revert InvalidRun();
        uint256 freeCapital = strategyCapital - activePrincipal;
        if (amount > freeCapital) revert InsufficientFreeCapital();
        runUsed[runId] = true;
        runPrincipal[runId] = amount;
        _activeRunIds.push(runId);
        _activeRunIndexPlusOne[runId] = _activeRunIds.length;
        activePrincipal += amount;
        activeStrategyRuns += 1;
        accountedQuote -= amount;
        if (quoteToken == address(0)) {
            (bool ok,) = payable(strategyExecutor).call{value: amount}("");
            if (!ok) revert InvalidAmount();
        } else {
            uint256 beforeBalance = IERC20(quoteToken).balanceOf(address(this));
            IERC20(quoteToken).safeTransfer(strategyExecutor, amount);
            if (beforeBalance - IERC20(quoteToken).balanceOf(address(this)) != amount) revert InvalidAmount();
        }
        _assertAccounting();
        emit StrategyPrincipalAllocated(runId, amount);
    }

    /// @notice Measures real quote proceeds transferred by the executor at settlement.
    function settleStrategyPrincipal(uint256 runId, uint256 returnedAmount) external payable nonReentrant {
        if (msg.sender != strategyExecutor) revert Unauthorized();
        uint256 principal = runPrincipal[runId];
        if (principal == 0 || !runUsed[runId]) revert InvalidRun();
        if (quoteToken == address(0)) {
            if (msg.value != returnedAmount) revert InvalidAmount();
        } else {
            if (msg.value != 0) revert InvalidAmount();
            uint256 beforeBalance = IERC20(quoteToken).balanceOf(address(this));
            if (returnedAmount != 0) IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), returnedAmount);
            if (IERC20(quoteToken).balanceOf(address(this)) - beforeBalance != returnedAmount) revert InvalidAmount();
        }

        runPrincipal[runId] = 0;
        activePrincipal -= principal;
        activeStrategyRuns -= 1;
        _removeActiveRun(runId);
        accountedQuote += returnedAmount;
        if (returnedAmount < principal) {
            uint256 loss = principal - returnedAmount;
            _checkpointStrategyCapital();
            strategyCapital -= loss;
            cumulativeRealizedLoss += loss;
            emit RealizedLossRecorded(runId, loss, strategyCapital);
        } else if (returnedAmount > principal) {
            uint256 profit = returnedAmount - principal;
            uint256 buybackPart = profit * PROFIT_BUYBACK_BPS / BPS;
            uint256 holderPart = profit * PROFIT_HOLDER_REWARD_BPS / BPS;
            uint256 protocolPart = profit * PROFIT_PROTOCOL_BPS / BPS;
            // All percentage-floor residual is retained in Strategy Capital / Compound.
            uint256 compoundPart = profit - buybackPart - holderPart - protocolPart;
            _checkpointBuybackReserve();
            _checkpointStrategyCapital();
            (bytes32 windowId, uint64 windowStart, uint64 windowEnd) = _holderWindowForTimestamp(uint64(block.timestamp));
            strategyCapital += compoundPart;
            buybackReserve += buybackPart;
            holderRewardReserve += holderPart;
            protocolReserve += protocolPart;
            if (holderPart != 0) {
                if (holderWorkflow == address(0)) revert HolderRewardsNotConfigured();
                uint256 expectedPoolAfter = ICompdHolderWorkflowV2(holderWorkflow).windowPool(windowId) + holderPart;
                ICompdHolderWorkflowV2(holderWorkflow).accrueHolderPool(
                    runId, windowId, windowStart, windowEnd, holderPart, expectedPoolAfter
                );
                _assertHolderPartition();
            }
            cumulativeRealizedProfit += profit;
            emit RealizedProfitRouted(runId, profit, compoundPart, buybackPart, holderPart, protocolPart, windowId, windowStart, windowEnd);
            emit HolderPoolAccrued(runId, windowId, windowStart, windowEnd, profit, holderPart);
        }
        _assertAccounting();
        emit StrategyPositionSettled(runId, principal, returnedAmount);
    }

    /// @notice Reserve one whole, exact finalized window pool for the bound Distributor's review.
    /// @dev The Vault does not validate Merkle proofs or off-chain ranking. It grants no payout authority before binding.
    function reserveFinalizedHolderDistribution(bytes32,bytes32,uint32,uint256,uint16) external pure override {
        revert CompdV2Errors.ImplementationDeferred();
    }

    function correctHolderDistribution(bytes32,uint32,uint16) external pure override {
        revert CompdV2Errors.ImplementationDeferred();
    }

    function registerHolderRewardEntry(bytes32,uint32,bytes32,uint16,address,uint256) external pure override {
        revert CompdV2Errors.ImplementationDeferred();
    }

    function finalizeHolderDistribution(bytes32 distributionId, uint32 version) external override nonReentrant {
        if (msg.sender != holderRewardsDistributor || holderRewardsDistributor == address(0)) revert Unauthorized();
        if (holderWorkflow == address(0) || holderLiability == address(0)) revert ActivationGraphIncomplete();
        ICompdHolderRewardsDistributorV2 d = ICompdHolderRewardsDistributorV2(holderRewardsDistributor);
        ICompdHolderRewardsDistributorV2.CommitmentView memory c = d.candidate(distributionId);
        ICompdHolderWorkflowV2.DistributionRecord memory w = ICompdHolderWorkflowV2(holderWorkflow).distribution(distributionId);
        ICompdHolderLiabilityV2.DistributionSummary memory l = ICompdHolderLiabilityV2(holderLiability).distributionSummary(distributionId, version);
        uint16 expectedCount = c.positiveEntryCount;
        uint256 amount = c.finalizedTotalPayable;
        if (
            c.status != ICompdHolderRewardsDistributorV2.CandidateStatus.REVIEW
                || c.commitmentVersion != version
                || c.domainSeparator != d.domainSeparator() || c.windowId != w.windowId
                || c.windowStart != w.windowStart || c.windowEnd != w.windowEnd
                || c.rewardAsset != quoteToken || c.windowPool != amount || amount == 0
                || c.recipientCount == 0 || c.recipientCount > 30 || expectedCount == 0
                || expectedCount > c.recipientCount || c.materializedEntryCount != expectedCount
                || c.materializedAmount != amount || block.timestamp < c.executableAfter
                || d.rootByVersion(distributionId, version) != c.root
                || d.datasetHashByVersion(distributionId, version) != c.datasetHash
                || d.commitmentHashByVersion(distributionId, version) != w.commitmentHash
                || w.currentVersion != version || w.status != ICompdHolderWorkflowV2.DistributionStatus.REVIEW_PENDING
                || w.root != c.root || w.datasetHash != c.datasetHash
                || w.rewardAsset != quoteToken || w.windowPool != amount || w.totalPayable != amount
                || w.expectedEntryCount != expectedCount || w.executableAfter != c.executableAfter
                || block.timestamp < w.executableAfter || l.finalized || l.superseded
                || l.materializedCount != expectedCount || l.materializedAmount != amount
        ) revert HolderReviewActive();

        ICompdHolderWorkflowV2(holderWorkflow).finalizeWorkflowDistribution(distributionId, version, amount, expectedCount);
        ICompdHolderLiabilityV2(holderLiability).finalizeLiabilityDistribution(distributionId, version, amount, expectedCount);
        _assertHolderPartition();
        _assertAccounting();
    }

    function payCommittedHolderEntry(bytes32,uint32,bytes32,uint16,address,address,uint256) external pure override {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function markHolderEntryFailed(bytes32,uint32,bytes32,uint16,address,address,uint256) external pure {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function markHolderEntryFailed(bytes32,uint32,bytes32,uint16,address,address,uint256,bytes32) external pure override {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function markManualSettlementAvailable(bytes32,uint32,bytes32,uint16) external pure {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function markManualSettlementAvailable(bytes32,uint32,bytes32,uint16,bytes32) external pure override {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function settleFailedHolderEntry(bytes32,uint32,bytes32,uint16,address,address,uint256) external pure override {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function startTerminalHolderLiability(bytes32,uint32,bytes32,uint16) external pure override {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function expireTerminalHolderLiability(bytes32,uint32,bytes32,uint16,address,address,uint256) external pure {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function expireTerminalHolderLiability(bytes32,uint32,bytes32,uint16) external pure override {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function openEmptyCandidate(bytes32,bytes32,uint32,uint256,bytes32,bytes32,bytes32) external pure override {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function correctEmptyCandidate(bytes32,uint32,bytes32,bytes32,bytes32) external pure override {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function finalizeEmptyCandidate(bytes32,uint32) external pure override {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function recoverExpiredHolderLiability(bytes32) external pure override {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function recoverNoRecipientPool(bytes32) external pure override {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function classifyEmptyHolderWindow(bytes32) external pure {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function classifyUnallocatedHolderPoolsForRecovery() external pure {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function recoverEligibleHolderRewards() external pure {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function releaseBuybackReserve(uint256 amount) external nonReentrant {
        if (msg.sender != buybackExecutor) revert Unauthorized();
        if (lifecycle != CompdV2Types.Lifecycle.ACTIVE) revert InvalidLifecycle();
        if (amount == 0 || amount > buybackReserve) revert InvalidAmount();
        _checkpointBuybackReserve();
        buybackReserve -= amount;
        accountedQuote -= amount;
        if (quoteToken == address(0)) {
            (bool ok,) = payable(buybackExecutor).call{value: amount}("");
            if (!ok) revert InvalidAmount();
        } else {
            uint256 beforeBalance = IERC20(quoteToken).balanceOf(address(this));
            IERC20(quoteToken).safeTransfer(buybackExecutor, amount);
            if (beforeBalance - IERC20(quoteToken).balanceOf(address(this)) != amount) revert InvalidAmount();
        }
        _assertAccounting();
    }

    function spendProtocolReserve(address recipient, uint256 amount, bytes32 category)
        external
        nonReentrant
        onlyRole(PROTOCOL_RESERVE_SPENDER_ROLE)
    {
        if (lifecycle != CompdV2Types.Lifecycle.ACTIVE) revert InvalidLifecycle();
        if (!allowedProtocolRecipient[recipient] || recipient == address(0) || amount == 0 || amount > protocolReserve) {
            revert InvalidRecipient();
        }
        if (!_validProtocolCategory(category)) revert InvalidConfiguration();
        protocolReserve -= amount;
        accountedQuote -= amount;
        _transferQuote(recipient, amount);
        _assertAccounting();
        emit ProtocolReserveSpent(recipient, amount, category);
    }

    /// @notice Record physically present, unaccounted surplus without moving it.
    function quarantineSurplus(address asset, uint256 amount) external onlyGuardian {
        if (
            lifecycle != CompdV2Types.Lifecycle.ACTIVE && lifecycle != CompdV2Types.Lifecycle.PAUSED
                && lifecycle != CompdV2Types.Lifecycle.SHUTDOWN_PENDING && lifecycle != CompdV2Types.Lifecycle.TERMINATED
        ) revert InvalidLifecycle();
        uint256 balance = _assetBalance(asset);
        uint256 accounted = asset == quoteToken ? accountedQuote : 0;
        if (balance < accounted || amount == 0) revert NotSurplus();
        uint256 unquarantined;
        unchecked {
            unquarantined = balance - accounted;
        }
        if (quarantinedSurplus[asset] > unquarantined) revert NotSurplus();
        unquarantined -= quarantinedSurplus[asset];
        if (amount > unquarantined) revert NotSurplus();
        quarantinedSurplus[asset] += amount;
        emit SurplusQuarantined(asset, amount, quarantinedSurplus[asset]);
    }

    /// @notice Irreversible post-termination recovery to the fixed recovery wallet.
    /// @dev Live buckets are updated as explicit outflows; cumulative recovery totals and the event preserve history.
    function recoverTerminatedAsset(address asset) external onlyGuardian nonReentrant onlyLifecycle(CompdV2Types.Lifecycle.TERMINATED) {
        uint256 physicalBalance = _assetBalance(asset);
        if (physicalBalance == 0) revert InvalidAmount();
        uint256 amount;
        uint256 strategyPart;
        uint256 buybackPart;
        uint256 protocolPart;
        uint256 surplusPart;
        if (asset == quoteToken) {
            if (
                activePrincipal != 0 || strategyCapital + buybackReserve + protocolReserve + holderRewardReserve != accountedQuote
                    || physicalBalance < accountedQuote
            ) {
                revert AccountingInvariant();
            }
            strategyPart = strategyCapital;
            buybackPart = buybackReserve;
            protocolPart = protocolReserve;
            surplusPart = quarantinedSurplus[asset];
            if (surplusPart > physicalBalance - accountedQuote) revert NotSurplus();
            amount = strategyPart + buybackPart + protocolPart + surplusPart;
            recoveredStrategyCapital += strategyPart;
            recoveredBuybackReserve += buybackPart;
            recoveredProtocolReserve += protocolPart;
            recoveredSurplus[asset] += surplusPart;
            strategyCapital = 0;
            buybackReserve = 0;
            protocolReserve = 0;
            // Holder assets remain physically and economically reserved unless individually
            // reclassified RECOVERY_ELIGIBLE and recovered through its narrow path.
            accountedQuote -= strategyPart + buybackPart + protocolPart;
            quarantinedSurplus[asset] = 0;
        } else {
            amount = quarantinedSurplus[asset];
            if (amount == 0 || amount > physicalBalance) revert NotSurplus();
            surplusPart = amount;
            quarantinedSurplus[asset] -= amount;
            recoveredOtherAssets[asset] += amount;
        }
        if (amount == 0) revert NotSurplus();
        _transferAsset(asset, RECOVERY_WALLET, amount);
        emit TerminationRecovery(asset, amount, strategyPart, buybackPart, protocolPart, surplusPart);
        _assertAccounting();
    }

    // --------------------------- Emergency custody V2 ---------------------------

    function emergencyWithdrawAll() external override nonReentrant {
        if (msg.sender != emergencyRecoveryAuthority) revert CompdV2Errors.UnauthorizedEmergencyAuthority();
        if (_emergencyProcessingStatus != CompdV2Types.EmergencyProcessingStatus.NOT_STARTED) {
            revert CompdV2Errors.EmergencyAlreadyInitiated();
        }
        CompdV2Types.Lifecycle beforeState = lifecycle;
        if (beforeState == CompdV2Types.Lifecycle.EMERGENCY_RECOVERY) revert CompdV2Errors.EmergencyAlreadyInitiated();
        if (beforeState > CompdV2Types.Lifecycle.TERMINATED) revert CompdV2Errors.InvalidLifecycle();
        if (emergencyRecoveryAuthority == address(0) || emergencyRecoveryWallet == address(0)
            || emergencyRecoveryAuthority == emergencyRecoveryWallet || _forbiddenEmergencyRole(emergencyRecoveryAuthority)
            || _forbiddenEmergencyRole(emergencyRecoveryWallet)) revert CompdV2Errors.InvalidImmutableConfiguration();

        // Emergency entry is independent of Holder component availability. Validate only
        // protocol buckets and the physical quote precondition here.
        _assertProtocolAccountingOnly();
        uint256 quoteBalance = _assetBalance(quoteToken);
        HolderPartitionTotals memory hp;
        bool holderDetailsAvailable;
        try this.holderPartitionTotals() returns (HolderPartitionTotals memory observed) {
            hp = observed;
            uint256 holderSum = observed.unfinalizedWindowPools + observed.normalReviewPools
                + observed.emptyReviewPools + observed.finalizedUnpaidLiabilities
                + observed.finalizedNoRecipientPools + observed.noRecipientRecoveryEligible
                + observed.expiredLiabilityRecoveryEligible;
            holderDetailsAvailable = holderSum == holderRewardReserve;
        } catch { }
        uint64 startedAt = uint64(block.timestamp);
        uint64 startedBlock = uint64(block.number);
        uint64 nonce = ++_snapshotNonce;
        bytes32 runsHash = _activeRunInventoryHash();
        bytes32 manifestHash = keccak256(abi.encode(_assetManifest));
        bytes32 accountingHash = keccak256(abi.encode(
            strategyCapital, buybackReserve, protocolReserve, holderRewardReserve, accountedQuote,
            activePrincipal, holderDetailsAvailable ? hp : HolderPartitionTotals(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0),
            cumulativeRevenue, cumulativeRealizedProfit, cumulativeRealizedLoss, quoteBalance
        ));

        _emergencySnapshot = CompdV2Types.EmergencySnapshot({
            snapshotId: bytes32(0), accountingSnapshotHash: accountingHash,
            activeRunInventoryHash: runsHash, assetManifestHash: manifestHash,
            lifecycleBefore: beforeState, initiatedBy: msg.sender, startedAt: startedAt,
            startedBlock: startedBlock, strategyCapital: strategyCapital, buybackReserve: buybackReserve,
            protocolReserve: protocolReserve, holderRewardReserve: holderRewardReserve,
            holderUnfinalizedWindowPool: holderDetailsAvailable ? hp.unfinalizedWindowPools : 0,
            holderNormalReviewPool: holderDetailsAvailable ? hp.normalReviewPools : 0,
            holderEmptyReviewPool: holderDetailsAvailable ? hp.emptyReviewPools : 0,
            holderFinalizedUnpaid: holderDetailsAvailable ? hp.finalizedUnpaidLiabilities : 0,
            holderNoRecipientPool: holderDetailsAvailable ? hp.finalizedNoRecipientPools : 0,
            holderRecoveryEligible: holderDetailsAvailable ? hp.recoveryEligible : 0, accountedQuote: accountedQuote,
            activePrincipal: activePrincipal, finalizedUnpaidTotal: holderDetailsAvailable ? hp.finalizedUnpaidLiabilities : 0,
            cumulativeRevenue: cumulativeRevenue, cumulativeRealizedProfit: cumulativeRealizedProfit,
            cumulativeRealizedLoss: cumulativeRealizedLoss, vaultQuoteBalance: quoteBalance,
            activeRunCount: uint32(_activeRunIds.length), holderPendingAutomaticCount: holderDetailsAvailable ? hp.pendingAutomatic : 0,
            holderFailedNotAvailableCount: holderDetailsAvailable ? hp.failedUnavailable : 0,
            openNormalReviewCount: holderDetailsAvailable ? hp.openNormalReviews : 0,
            openEmptyReviewCount: holderDetailsAvailable ? hp.openEmptyReviews : 0,
            terminalPendingCount: holderDetailsAvailable ? hp.terminalPendingRecords : 0,
            recoveryEligibleLiabilityCount: 0,
            registeredModuleCount: _boundModuleCount(), registeredAssetCount: uint16(_assetManifest.length),
            snapshotStatus: holderDetailsAvailable ? CompdV2Types.EmergencySnapshotCellStatus.RECORDED
                : CompdV2Types.EmergencySnapshotCellStatus.UNAVAILABLE
        });
        _snapshotId = keccak256(abi.encode(
            block.chainid, address(this), nonce, msg.sender, beforeState, startedAt, startedBlock,
            accountingHash, runsHash, manifestHash
        ));
        _emergencySnapshot.snapshotId = _snapshotId;
        _emergencyStartedAt = startedAt;
        _emergencyStartedBlock = startedBlock;
        _emergencyInitiatedBy = msg.sender;
        _preEmergencyHolderDeficit = _holderBackingView(quoteBalance).holderBackingDeficit;
        lifecycle = CompdV2Types.Lifecycle.EMERGENCY_RECOVERY;
        _emergencyProcessingStatus = CompdV2Types.EmergencyProcessingStatus.IN_PROGRESS;
        for (uint256 i; i < _activeRunIds.length; ++i) {
            _emergencyRunStatuses[_activeRunIds[i]] = CompdV2Types.EmergencyRunStatus.EXIT_REQUIRED;
        }
        _snapshotBoundModules();
        _emergencyReconciliation.lifecycle = lifecycle;
        _emergencyReconciliation.processingStatus = _emergencyProcessingStatus;
        _emergencyReconciliation.registeredModuleCount = _boundModuleCount();
        _emergencyReconciliation.registeredAssetCount = uint16(_assetManifest.length);
        _emergencyReconciliation.manifestCoverageHash = keccak256(abi.encode(manifestHash, _snapshotId));
        emit EmergencyRecoveryInitiated(
            _snapshotId, msg.sender, emergencyRecoveryWallet, beforeState, startedAt, startedBlock,
            accountingHash, runsHash, manifestHash
        );
    }

    function emergencyWithdrawAsset(address asset) external override nonReentrant {
        if (msg.sender != emergencyRecoveryAuthority) revert CompdV2Errors.UnauthorizedEmergencyAuthority();
        if (lifecycle != CompdV2Types.Lifecycle.EMERGENCY_RECOVERY) revert CompdV2Errors.EmergencyNotInitiated();
        if (!_assetRegistered[asset]) revert CompdV2Errors.EmergencyAssetNotRegistered();
        _withdrawVaultAsset(asset);
    }

    function emergencyRecoverModuleAsset(CompdV2Types.ModuleId moduleId, address asset) external pure override {
        moduleId; asset; revert CompdV2Errors.ImplementationDeferred();
    }
    function emergencyExitRun(uint256 runId) external pure override { runId; revert CompdV2Errors.ImplementationDeferred(); }
    function emergencyRetryAsset(CompdV2Types.ModuleId moduleId, address asset) external pure override {
        moduleId; asset; revert CompdV2Errors.ImplementationDeferred();
    }
    function emergencyRetryRun(uint256 runId) external pure override { runId; revert CompdV2Errors.ImplementationDeferred(); }

    function registerDiscoveredEmergencyAsset(address asset) external override {
        if (msg.sender != emergencyRecoveryAuthority) revert CompdV2Errors.UnauthorizedEmergencyAuthority();
        if (lifecycle != CompdV2Types.Lifecycle.EMERGENCY_RECOVERY) revert CompdV2Errors.EmergencyNotInitiated();
        if (asset == address(0) || _assetRegistered[asset]) return;
        _addEmergencyAsset(asset);
        CompdV2Types.EmergencyAssetRecord storage record = _emergencyAssetRecords[uint8(CompdV2Types.ModuleId.VAULT)][asset];
        record.moduleId = CompdV2Types.ModuleId.VAULT;
        record.module = address(this);
        record.asset = asset;
        record.status = CompdV2Types.EmergencyAssetStatus.DISCOVERED_AFTER_INITIATION;
        record.snapshotStatus = CompdV2Types.EmergencySnapshotCellStatus.NOT_RECORDED;
        emit EmergencyAssetDiscovered(_snapshotId, asset, uint64(block.timestamp), uint64(block.number));
        _reopenEmergencyProcessing();
    }

    function emergencyRefreshCompletion() external override {
        if (lifecycle != CompdV2Types.Lifecycle.EMERGENCY_RECOVERY) revert CompdV2Errors.EmergencyNotInitiated();
        // Module snapshots/exit and sweep implementations are not yet complete. Never claim clean
        // completion from their identity scaffolds; later phases must supply authoritative statuses.
        _emergencyProcessingStatus = CompdV2Types.EmergencyProcessingStatus.IN_PROGRESS;
        _emergencyReconciliation.lifecycle = lifecycle;
        _emergencyReconciliation.processingStatus = _emergencyProcessingStatus;
        _emergencyReconciliation.reconciledAt = uint64(block.timestamp);
        _emergencyReconciliation.cumulativeQuoteEmergencyOutflow = cumulativeQuoteEmergencyOutflow;
        _emergencyReconciliation.holderBacking = _holderBackingView(_safeAssetBalance(quoteToken));
    }

    function emergencyRecoveryState() external view override returns (
        CompdV2Types.Lifecycle, CompdV2Types.EmergencyProcessingStatus, bytes32, uint64, uint64, address
    ) { return (lifecycle, _emergencyProcessingStatus, _snapshotId, _emergencyStartedAt, _emergencyStartedBlock, _emergencyInitiatedBy); }
    function emergencyAccountingSnapshot() external view override returns (CompdV2Types.EmergencySnapshot memory) { return _emergencySnapshot; }
    function emergencyReconciliation() external view override returns (CompdV2Types.EmergencyReconciliation memory) { return _emergencyReconciliation; }
    function emergencyAssetStatus(CompdV2Types.ModuleId moduleId, address asset)
        external view override returns (CompdV2Types.EmergencyAssetRecord memory)
    { return _emergencyAssetRecords[uint8(moduleId)][asset]; }
    function emergencyAttemptCount(bytes32 subjectId) external view override returns (uint32) { return _emergencyAttemptCounts[subjectId]; }
    function emergencyAttemptAt(bytes32 subjectId, uint32 attemptNumber)
        external view override returns (CompdV2Types.EmergencyAttempt memory)
    { return _emergencyAttempts[subjectId][attemptNumber]; }
    function emergencyOutflowByModuleAsset(CompdV2Types.ModuleId moduleId, address asset)
        external view override returns (uint256, uint256)
    { uint256[2] storage values = _emergencyOutflow[uint8(moduleId)][asset]; return (values[0], values[1]); }
    function emergencyFailureCountByModuleAsset(CompdV2Types.ModuleId moduleId, address asset)
        external view override returns (uint32)
    { return _emergencyFailures[uint8(moduleId)][asset]; }
    function emergencyHolderBackingState() external view override returns (CompdV2Types.EmergencyHolderBacking memory) {
        return _holderBackingView(_safeAssetBalance(quoteToken));
    }
    function emergencyAssetCount() external view override returns (uint256) { return _assetManifest.length; }
    function emergencyAssetAt(uint256 index) external view override returns (address) { return _assetManifest[index]; }
    function emergencyModuleAddress(CompdV2Types.ModuleId moduleId) external view override returns (address) {
        return _moduleAddress(moduleId);
    }

    function _withdrawVaultAsset(address asset) private {
        uint8 moduleKey = uint8(CompdV2Types.ModuleId.VAULT);
        CompdV2Types.EmergencyAssetRecord storage record = _emergencyAssetRecords[moduleKey][asset];
        bytes32 subjectId = keccak256(abi.encode(moduleKey, asset));
        uint32 number = ++_emergencyAttemptCounts[subjectId];
        bytes32 attemptId = keccak256(abi.encode(_snapshotId, subjectId, number, msg.sender, block.number));
        uint256 beforeBalance = _safeAssetBalance(asset);
        uint256 walletBefore = _safeAssetBalanceAt(asset, emergencyRecoveryWallet);
        record.moduleId = CompdV2Types.ModuleId.VAULT;
        record.module = address(this);
        record.asset = asset;
        record.attemptCount = number;
        record.lastAttemptAt = uint64(block.timestamp);
        record.lastAttemptBlock = uint64(block.number);
        record.lastBalanceBefore = beforeBalance;
        record.status = beforeBalance == 0 ? CompdV2Types.EmergencyAssetStatus.ZERO_BALANCE : CompdV2Types.EmergencyAssetStatus.FAILED_RETRYABLE;
        emit EmergencyAssetWithdrawalAttempted(_snapshotId, attemptId, asset, number, beforeBalance);
        CompdV2Types.EmergencyAttempt memory attempt;
        attempt.attemptId = attemptId;
        attempt.attemptNumber = number;
        attempt.moduleId = CompdV2Types.ModuleId.VAULT;
        attempt.asset = asset;
        attempt.caller = msg.sender;
        attempt.timestamp = uint64(block.timestamp);
        attempt.blockNumber = uint64(block.number);
        attempt.balanceBefore = beforeBalance;
        attempt.walletBalanceBefore = walletBefore;
        if (beforeBalance == 0) {
            attempt.outcome = CompdV2Types.EmergencyAttemptOutcome.NO_BALANCE;
            record.lastBalanceAfter = 0;
            record.status = CompdV2Types.EmergencyAssetStatus.ZERO_BALANCE;
            _emergencyAttempts[subjectId][number] = attempt;
            emit EmergencyAssetWithdrawalResult(_snapshotId, attemptId, asset, 0, 0, attempt.outcome, bytes32(0), bytes32(0));
            return;
        }
        try this.performFixedEmergencyTransfer(asset, beforeBalance) returns (uint256 debited, uint256 credited, uint256 afterBalance, uint256 walletAfter) {
            attempt.balanceAfter = afterBalance;
            attempt.walletBalanceAfter = walletAfter;
            attempt.amountDebited = debited;
            attempt.amountCredited = credited;
            attempt.outcome = CompdV2Types.EmergencyAttemptOutcome.SUCCESS;
            record.lastBalanceAfter = afterBalance;
            record.amountDebited += debited;
            record.amountCredited += credited;
            record.lastFailureCode = bytes32(0);
            record.lastRevertDataHash = bytes32(0);
            record.status = CompdV2Types.EmergencyAssetStatus.RECOVERED;
            _emergencyOutflow[moduleKey][asset][0] += debited;
            _emergencyOutflow[moduleKey][asset][1] += credited;
            if (asset == quoteToken) cumulativeQuoteEmergencyOutflow += debited;
            emit EmergencyAssetWithdrawalResult(_snapshotId, attemptId, asset, debited, credited, attempt.outcome, bytes32(0), bytes32(0));
            if (asset == quoteToken) emit EmergencyBackingDeficitUpdated(
                _snapshotId, holderRewardReserve, _holderUnpaidOrZero(),
                _holderBackingView(afterBalance).holderBackingAvailable,
                _holderBackingView(afterBalance).holderBackingDeficit, _preEmergencyHolderDeficit,
                _holderBackingView(afterBalance).holderBackingDeficit > _preEmergencyHolderDeficit
                    ? _holderBackingView(afterBalance).holderBackingDeficit - _preEmergencyHolderDeficit : 0,
                cumulativeQuoteEmergencyOutflow, uint64(block.timestamp)
            );
        } catch (bytes memory reason) {
            attempt.balanceAfter = _safeAssetBalance(asset);
            attempt.walletBalanceAfter = _safeAssetBalanceAt(asset, emergencyRecoveryWallet);
            attempt.outcome = CompdV2Types.EmergencyAttemptOutcome.FAILED_RETRYABLE;
            attempt.failureCode = keccak256("VAULT_ASSET_TRANSFER_FAILED");
            attempt.revertDataHash = keccak256(reason);
            record.lastBalanceAfter = attempt.balanceAfter;
            record.lastFailureCode = attempt.failureCode;
            record.lastRevertDataHash = attempt.revertDataHash;
            record.status = CompdV2Types.EmergencyAssetStatus.FAILED_RETRYABLE;
            ++_emergencyFailures[moduleKey][asset];
            emit EmergencyAssetWithdrawalResult(_snapshotId, attemptId, asset, 0, 0, attempt.outcome, attempt.failureCode, attempt.revertDataHash);
        }
        _emergencyAttempts[subjectId][number] = attempt;
        _emergencyReconciliation.cumulativeQuoteEmergencyOutflow = cumulativeQuoteEmergencyOutflow;
    }

    function performFixedEmergencyTransfer(address asset, uint256 amount)
        external returns (uint256 debited, uint256 credited, uint256 afterBalance, uint256 walletAfter)
    {
        if (msg.sender != address(this) || lifecycle != CompdV2Types.Lifecycle.EMERGENCY_RECOVERY) revert Unauthorized();
        if (asset == address(0)) {
            uint256 senderBefore = address(this).balance;
            uint256 recipientBefore = emergencyRecoveryWallet.balance;
            (bool ok,) = payable(emergencyRecoveryWallet).call{value: amount, gas: 50_000}("");
            if (!ok) revert TokenCallFailed();
            afterBalance = address(this).balance;
            walletAfter = emergencyRecoveryWallet.balance;
            if (afterBalance > senderBefore || walletAfter < recipientBefore) revert AccountingInvariant();
            debited = senderBefore - afterBalance;
            credited = walletAfter - recipientBefore;
        } else {
            uint256 senderBefore = IERC20(asset).balanceOf(address(this));
            uint256 recipientBefore = IERC20(asset).balanceOf(emergencyRecoveryWallet);
            IERC20(asset).safeTransfer(emergencyRecoveryWallet, amount);
            afterBalance = IERC20(asset).balanceOf(address(this));
            walletAfter = IERC20(asset).balanceOf(emergencyRecoveryWallet);
            if (afterBalance > senderBefore || walletAfter < recipientBefore) revert AccountingInvariant();
            debited = senderBefore - afterBalance;
            credited = walletAfter - recipientBefore;
        }
    }

    function _snapshotBoundModules() private {
        for (uint256 i; i < _assetManifest.length; ++i) {
            address asset = _assetManifest[i];
            (bool available, uint256 value) = _tryBalance(asset, address(this));
            CompdV2Types.EmergencyAssetRecord storage vaultRecord = _emergencyAssetRecords[uint8(CompdV2Types.ModuleId.VAULT)][asset];
            vaultRecord.moduleId = CompdV2Types.ModuleId.VAULT;
            vaultRecord.module = address(this);
            vaultRecord.asset = asset;
            vaultRecord.snapshotStatus = available ? CompdV2Types.EmergencySnapshotCellStatus.RECORDED : CompdV2Types.EmergencySnapshotCellStatus.UNAVAILABLE;
            if (available) vaultRecord.balanceAtSnapshot = value;
            for (uint8 raw = 1; raw <= uint8(CompdV2Types.ModuleId.THIN_FLAP_RECEIVER); ++raw) {
                CompdV2Types.ModuleId id = CompdV2Types.ModuleId(raw);
                address module = _moduleAddress(id);
                CompdV2Types.EmergencyAssetRecord storage moduleRecord = _emergencyAssetRecords[raw][asset];
                moduleRecord.moduleId = id;
                moduleRecord.module = module;
                moduleRecord.asset = asset;
                if (module == address(0)) {
                    moduleRecord.snapshotStatus = CompdV2Types.EmergencySnapshotCellStatus.UNAVAILABLE;
                    continue;
                }
                try ICompdEmergencyModuleV2(module).snapshotEmergencyBalance{gas: 60_000}(_snapshotId, asset)
                    returns (bool moduleAvailable, uint256 moduleBalance)
                {
                    moduleRecord.snapshotStatus = moduleAvailable ? CompdV2Types.EmergencySnapshotCellStatus.RECORDED : CompdV2Types.EmergencySnapshotCellStatus.UNAVAILABLE;
                    if (moduleAvailable) moduleRecord.balanceAtSnapshot = moduleBalance;
                } catch {
                    moduleRecord.snapshotStatus = CompdV2Types.EmergencySnapshotCellStatus.UNAVAILABLE;
                }
            }
        }
    }

    function _holderBackingView(uint256 physicalQuote) private view returns (CompdV2Types.EmergencyHolderBacking memory result) {
        if (accountedQuote < holderRewardReserve) revert AccountingInvariant();
        uint256 nonHolder = accountedQuote - holderRewardReserve;
        uint256 availablePhysical = physicalQuote > nonHolder ? physicalQuote - nonHolder : 0;
        uint256 backing = availablePhysical < holderRewardReserve ? availablePhysical : holderRewardReserve;
        result = CompdV2Types.EmergencyHolderBacking({
            holderRewardReserve: holderRewardReserve, accountedQuote: accountedQuote,
            vaultQuoteBalance: physicalQuote, nonHolderQuoteObligations: nonHolder,
            holderBackingAvailable: backing, holderBackingDeficit: holderRewardReserve - backing,
            holderUnpaidTotal: _holderUnpaidOrZero(),
            preEmergencyDeficit: _preEmergencyHolderDeficit,
            emergencyCausedDeficit: holderRewardReserve - backing > _preEmergencyHolderDeficit
                ? holderRewardReserve - backing - _preEmergencyHolderDeficit : 0
        });
    }

    function _holderUnpaidOrZero() private view returns (uint256 amount) {
        try this.holderFinalizedUnpaidLiabilityTotal() returns (uint256 value) { return value; }
        catch { return 0; }
    }

    function _safeAssetBalance(address asset) private view returns (uint256 balance) {
        (bool ok, uint256 value) = _tryBalance(asset, address(this));
        if (!ok) revert AccountingInvariant();
        return value;
    }

    function _safeAssetBalanceAt(address asset, address owner) private view returns (uint256 balance) {
        (bool ok, uint256 value) = _tryBalance(asset, owner);
        if (!ok) revert AccountingInvariant();
        return value;
    }

    function _tryBalance(address asset, address owner) private view returns (bool ok, uint256 value) {
        if (asset == address(0)) return (true, owner.balance);
        bytes memory data;
        (ok, data) = asset.staticcall{gas: 40_000}(abi.encodeWithSelector(IERC20.balanceOf.selector, owner));
        if (!ok || data.length != 32) return (false, 0);
        value = abi.decode(data, (uint256));
    }

    function _addInitialEmergencyAsset(address asset) private {
        if (_assetRegistered[asset]) return;
        if (_assetManifest.length >= LOCAL_ASSET_MANIFEST_CAP_CANDIDATE) revert CompdV2Errors.EmergencyManifestCapacityReached();
        _assetRegistered[asset] = true;
        _assetManifest.push(asset);
    }

    function _addEmergencyAsset(address asset) private {
        if (_assetManifest.length >= LOCAL_ASSET_MANIFEST_CAP_CANDIDATE) revert CompdV2Errors.EmergencyManifestCapacityReached();
        _assetRegistered[asset] = true;
        _assetManifest.push(asset);
    }

    function _moduleAddress(CompdV2Types.ModuleId moduleId) private view returns (address) {
        if (moduleId == CompdV2Types.ModuleId.VAULT) return address(this);
        if (moduleId == CompdV2Types.ModuleId.STRATEGY_EXECUTOR) return strategyExecutor;
        if (moduleId == CompdV2Types.ModuleId.BUYBACK_EXECUTOR) return buybackExecutor;
        if (moduleId == CompdV2Types.ModuleId.THIN_FLAP_RECEIVER) return flapReceiver;
        revert CompdV2Errors.InvalidModuleId();
    }

    function _boundModuleCount() private view returns (uint16 count) {
        count = 1;
        if (strategyExecutor != address(0)) ++count;
        if (buybackExecutor != address(0)) ++count;
        if (flapReceiver != address(0)) ++count;
    }

    function _activeRunInventoryHash() private view returns (bytes32) {
        bytes32 hash = keccak256(abi.encode(_activeRunIds.length));
        for (uint256 i; i < _activeRunIds.length; ++i) hash = keccak256(abi.encode(hash, _activeRunIds[i], runPrincipal[_activeRunIds[i]]));
        return hash;
    }

    function _removeActiveRun(uint256 runId) private {
        uint256 indexPlusOne = _activeRunIndexPlusOne[runId];
        if (indexPlusOne == 0) return;
        uint256 index = indexPlusOne - 1;
        uint256 last = _activeRunIds.length - 1;
        if (index != last) {
            uint256 moved = _activeRunIds[last];
            _activeRunIds[index] = moved;
            _activeRunIndexPlusOne[moved] = index + 1;
        }
        _activeRunIds.pop();
        delete _activeRunIndexPlusOne[runId];
    }

    function _reopenEmergencyProcessing() private {
        if (_emergencyProcessingStatus != CompdV2Types.EmergencyProcessingStatus.IN_PROGRESS) {
            CompdV2Types.EmergencyProcessingStatus previous = _emergencyProcessingStatus;
            _emergencyProcessingStatus = CompdV2Types.EmergencyProcessingStatus.IN_PROGRESS;
            emit EmergencyProcessingStatusChanged(_snapshotId, previous, _emergencyProcessingStatus, keccak256("NEW_DISCOVERED_ASSET"), uint64(block.timestamp));
        }
    }

    function totalAccountedBuckets() external view returns (uint256) {
        return strategyCapital + buybackReserve + protocolReserve + holderRewardReserve;
    }

    function freeStrategyCapital() external view returns (uint256) {
        return strategyCapital - activePrincipal;
    }

    function _setLifecycle(CompdV2Types.Lifecycle next) private {
        CompdV2Types.Lifecycle previous = lifecycle;
        lifecycle = next;
        emit LifecycleChanged(previous, next);
    }

    function _checkpointBuybackReserve() private {
        if (buybackExecutor != address(0)) {
            ICompdBuybackReserveObserver(buybackExecutor).checkpointReserveBeforeChange(buybackReserve);
        }
    }

    function _checkpointStrategyCapital() private {
        if (strategyExecutor != address(0)) {
            ICompdStrategyCapitalObserver(strategyExecutor).checkpointCapitalBeforeChange(strategyCapital);
        }
    }

    function _assertAccounting() private view {
        _assertProtocolAccountingOnly();
        // Accounted quote must remain physically present in the Vault. Principal
        // outside the Vault is represented separately by activePrincipal.
        if (lifecycle != CompdV2Types.Lifecycle.EMERGENCY_RECOVERY && _assetBalance(quoteToken) < accountedQuote) {
            revert AccountingInvariant();
        }
        _assertHolderPartition();
    }

    function _assertProtocolAccountingOnly() private view {
        if (strategyCapital + buybackReserve + protocolReserve + holderRewardReserve != accountedQuote + activePrincipal) {
            revert AccountingInvariant();
        }
        if (lifecycle != CompdV2Types.Lifecycle.EMERGENCY_RECOVERY && _assetBalance(quoteToken) < accountedQuote) {
            revert AccountingInvariant();
        }
    }

    function _assertHolderPartition() private view {
        (,, bool holds) = holderPartitionInvariant();
        if (!holds) revert HolderPartitionInvariant();
    }

    function _holderWindowForTimestamp(uint64 timestamp) private view returns (bytes32 id, uint64 start, uint64 end) {
        if (!holderRewardsActivationConfigured || holderRewardsDistributor == address(0)) revert HolderRewardsNotConfigured();
        uint256 start256 = uint256(timestamp) / HOLDER_WINDOW_SECONDS * HOLDER_WINDOW_SECONDS;
        uint256 end256 = start256 + HOLDER_WINDOW_SECONDS;
        if (end256 > type(uint64).max) revert InvalidHolderContext();
        start = uint64(start256);
        end = uint64(end256);
        id = holderWindowId(start, end);
    }

    function _firstHolderWindowStart() private view returns (uint256 firstStart) {
        firstStart = uint256(holderRewardsActivationTimestamp) / HOLDER_WINDOW_SECONDS * HOLDER_WINDOW_SECONDS;
        if (firstStart < holderRewardsActivationTimestamp) firstStart += HOLDER_WINDOW_SECONDS;
    }

    // Detailed Holder state is deliberately absent from the Vault; all transitions
    // are delegated to the bound Workflow and Liability components.

    function _validProtocolCategory(bytes32 category) private pure returns (bool) {
        return category == keccak256("OPERATIONS") || category == keccak256("SECURITY")
            || category == keccak256("INFRASTRUCTURE") || category == keccak256("AUDIT")
            || category == keccak256("LEGAL") || category == keccak256("PARTNERSHIPS");
    }

    function _forbiddenEmergencyRole(address value) private pure returns (bool) {
        return value == GUARDIAN || value == RECOVERY_WALLET || value == AUTOMATION_EXECUTOR
            || value == COMPD_TOKEN || value == BUYBACK_ADMIN;
    }

    function _assetBalance(address asset) private view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        return IERC20(asset).balanceOf(address(this));
    }

    function _transferQuote(address recipient, uint256 amount) private {
        if (quoteToken == address(0)) {
            uint256 senderBefore = address(this).balance;
            uint256 recipientBefore = recipient.balance;
            (bool ok,) = payable(recipient).call{value: amount}("");
            uint256 senderAfter = address(this).balance;
            uint256 recipientAfter = recipient.balance;
            if (
                !ok || senderAfter > senderBefore || senderBefore - senderAfter != amount
                    || recipientAfter < recipientBefore || recipientAfter - recipientBefore != amount
            ) revert InvalidAmount();
        } else {
            uint256 senderBefore = IERC20(quoteToken).balanceOf(address(this));
            uint256 recipientBefore = IERC20(quoteToken).balanceOf(recipient);
            IERC20(quoteToken).safeTransfer(recipient, amount);
            uint256 senderAfter = IERC20(quoteToken).balanceOf(address(this));
            uint256 recipientAfter = IERC20(quoteToken).balanceOf(recipient);
            if (
                senderAfter > senderBefore || senderBefore - senderAfter != amount || recipientAfter < recipientBefore
                    || recipientAfter - recipientBefore != amount
            ) revert InvalidAmount();
        }
    }

    function _transferAsset(address asset, address recipient, uint256 amount) private {
        if (asset == address(0)) {
            uint256 senderBefore = address(this).balance;
            uint256 recipientBefore = recipient.balance;
            (bool ok,) = payable(recipient).call{value: amount}("");
            uint256 senderAfter = address(this).balance;
            uint256 recipientAfter = recipient.balance;
            if (
                !ok || senderAfter > senderBefore || senderBefore - senderAfter != amount
                    || recipientAfter < recipientBefore || recipientAfter - recipientBefore != amount
            ) revert InvalidAmount();
        } else {
            uint256 senderBefore = IERC20(asset).balanceOf(address(this));
            uint256 recipientBefore = IERC20(asset).balanceOf(recipient);
            IERC20(asset).safeTransfer(recipient, amount);
            uint256 senderAfter = IERC20(asset).balanceOf(address(this));
            uint256 recipientAfter = IERC20(asset).balanceOf(recipient);
            if (
                senderAfter > senderBefore || senderBefore - senderAfter != amount || recipientAfter < recipientBefore
                    || recipientAfter - recipientBefore != amount
            ) revert InvalidAmount();
        }
    }
}
