// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
} from "./ICompdProductionInterfaces.sol";

/// @notice Production accounting vault for COMPD. It is not the Flap receiver.
/// @dev A zero quote token denotes native BNB. Both approved accounting splits are fixed.
contract CompdProductionVault is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
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
    bytes32 public constant HOLDER_PROTOCOL_ID = keccak256("COMPD_HOLDER_REWARDS_V1");
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
    address public constant AUTOMATION_EXECUTOR = 0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;
    address public constant COMPD_TOKEN = 0x7b7Af51136574c91A12988989c0a08E98aE97777;
    address public constant BUYBACK_ADMIN = 0x29BB16dB8e9f2371255BA75aF83aECaFB2CC00BA;

    bytes32 public constant PROTOCOL_RESERVE_SPENDER_ROLE = keccak256("PROTOCOL_RESERVE_SPENDER_ROLE");
    bytes32 public constant HOLDER_REWARD_SETTLER_ROLE = keccak256("HOLDER_REWARD_SETTLER_ROLE");

    enum Lifecycle {
        ACTIVE,
        PAUSED,
        SHUTDOWN_PENDING,
        TERMINATED
    }

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

    address public immutable quoteToken;
    Lifecycle public lifecycle = Lifecycle.PAUSED;
    address public strategyExecutor;
    address public buybackExecutor;
    address public receiverFactory;
    address public flapReceiver;

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

    struct HolderDistribution {
        bytes32 windowId;
        uint32 version;
        uint64 acceptedAt;
        uint64 executableAfter;
        uint256 totalPayable;
        uint256 entriesRegistered;
        uint256 entryCount;
        uint16 expectedEntryCount;
        bool finalized;
        bool exists;
        bool correctionLocked;
    }

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
    uint256 public holderUnfinalizedWindowPoolTotal;
    uint256 public holderCandidateReviewPoolTotal;
    uint256 public holderFinalizedUnpaidLiabilityTotal;
    uint256 public holderUnallocatedNoRecipientPoolTotal;
    uint256 public holderRecoveryEligibleTotal;
    uint256 public holderPendingAutomaticEntryCount;
    uint256 public holderFailedNotAvailableCount;
    mapping(bytes32 => uint256) public holderRewardPool;
    mapping(bytes32 => uint64) public holderWindowStart;
    mapping(bytes32 => uint64) public holderWindowEnd;
    mapping(bytes32 => bool) public holderWindowClassified;
    mapping(bytes32 => HolderDistribution) private _holderDistributions;
    mapping(bytes32 => bytes32) public holderWindowDistribution;
    mapping(bytes32 => mapping(uint16 => HolderEntry)) private _holderEntries;

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
    event LifecycleChanged(Lifecycle indexed previousState, Lifecycle indexed newState);
    event ShutdownInitiated(uint64 startedAt, uint64 shutdownAt);
    event ShutdownExtended(uint64 newShutdownAt);
    event ShutdownTerminated(uint64 terminatedAt);
    event SurplusQuarantined(address indexed asset, uint256 amount, uint256 totalQuarantined);
    event TerminationRecovery(address indexed asset, uint256 amount, uint256 strategy, uint256 buyback, uint256 protocol, uint256 surplus);

    modifier onlyGuardian() {
        if (msg.sender != GUARDIAN) revert Unauthorized();
        _;
    }

    modifier onlyConfigAdmin() {
        _checkRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _;
    }

    modifier onlyLifecycle(Lifecycle requiredState) {
        if (lifecycle != requiredState) revert InvalidLifecycle();
        _;
    }

    constructor(address quoteToken_, address configurationAdmin) {
        if (configurationAdmin == address(0)) revert InvalidConfiguration();
        if (quoteToken_ != address(0) && quoteToken_.code.length == 0) revert InvalidConfiguration();
        quoteToken = quoteToken_;
        _grantRole(DEFAULT_ADMIN_ROLE, configurationAdmin);
    }

    receive() external payable {
        // Direct native transfers are unaccounted surplus. Flap revenue is credited only
        // through registerFlapRevenue from the bound, separately deployed receiver.
    }

    function bindStrategyExecutor(address executor) external onlyConfigAdmin onlyLifecycle(Lifecycle.PAUSED) {
        if (strategyExecutor != address(0) || executor.code.length == 0) revert InvalidConfiguration();
        ICompdStrategyExecutorIdentity candidate = ICompdStrategyExecutorIdentity(executor);
        if (
            candidate.vault() != address(this) || candidate.AUTOMATION_EXECUTOR() != AUTOMATION_EXECUTOR
                || candidate.GUARDIAN() != GUARDIAN
        ) {
            revert InvalidConfiguration();
        }
        if (ICompdProductionVaultView(candidate.vault()).quoteToken() != quoteToken) revert InvalidConfiguration();
        strategyExecutor = executor;
        emit ExecutorBound(keccak256("STRATEGY"), executor);
    }

    function bindBuybackExecutor(address executor) external onlyConfigAdmin onlyLifecycle(Lifecycle.PAUSED) {
        if (buybackExecutor != address(0) || executor.code.length == 0) revert InvalidConfiguration();
        ICompdBuybackExecutorIdentity candidate = ICompdBuybackExecutorIdentity(executor);
        if (
            candidate.vault() != address(this) || candidate.AUTOMATION_EXECUTOR() != AUTOMATION_EXECUTOR
                || candidate.COMPD_TOKEN() != COMPD_TOKEN || candidate.PROTOCOL_BUYBACK_ADMIN() != BUYBACK_ADMIN
        ) revert InvalidConfiguration();
        if (ICompdProductionVaultView(candidate.vault()).quoteToken() != quoteToken) revert InvalidConfiguration();
        buybackExecutor = executor;
        emit ExecutorBound(keccak256("BUYBACK"), executor);
    }

    function bindReceiverFactory(address factory) external onlyConfigAdmin onlyLifecycle(Lifecycle.PAUSED) {
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
        if (lifecycle != Lifecycle.PAUSED) revert InvalidLifecycle();
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
        onlyLifecycle(Lifecycle.PAUSED)
    {
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        allowedProtocolRecipient[recipient] = allowed;
        emit ProtocolRecipientUpdated(recipient, allowed);
    }

    function grantRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        if (lifecycle != Lifecycle.PAUSED) revert InvalidLifecycle();
        super.grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        if (lifecycle != Lifecycle.PAUSED) revert InvalidLifecycle();
        super.revokeRole(role, account);
    }

    function resume() external onlyGuardian onlyLifecycle(Lifecycle.PAUSED) {
        if (
            strategyExecutor == address(0) || buybackExecutor == address(0) || flapReceiver == address(0)
                || !holderRewardsActivationConfigured || holderRewardsDistributor == address(0)
                || block.timestamp < _firstHolderWindowStart()
        ) {
            revert InvalidConfiguration();
        }
        _setLifecycle(Lifecycle.ACTIVE);
    }

    /// @notice One-time deployment fact supplied from the independently verified canonical token checkpoint.
    /// @dev This is immutable after setup. External finality/reorg verification remains a deployment gate.
    function configureHolderRewardsActivation(uint256 activationBlock, bytes32 activationBlockHash, uint64 activationTimestamp)
        external
        onlyConfigAdmin
        onlyLifecycle(Lifecycle.PAUSED)
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
    function bindHolderRewardsDistributor(address distributor) external onlyConfigAdmin onlyLifecycle(Lifecycle.PAUSED) {
        if (holderRewardsDistributor != address(0) || distributor.code.length == 0) revert InvalidConfiguration();
        holderRewardsDistributor = distributor;
        emit HolderRewardsDistributorBound(distributor);
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
        return _holderEntries[distributionId][recipientIndex];
    }

    /// @notice Minimal current-version query for the bound Distributor.
    function holderDistributionVersion(bytes32 distributionId) external view returns (uint32) {
        return _holderDistributions[distributionId].version;
    }

    function pause() external onlyGuardian onlyLifecycle(Lifecycle.ACTIVE) {
        _setLifecycle(Lifecycle.PAUSED);
    }

    function initiateShutdown() external onlyGuardian {
        if (lifecycle != Lifecycle.ACTIVE && lifecycle != Lifecycle.PAUSED) revert InvalidLifecycle();
        uint64 started = uint64(block.timestamp);
        shutdownStartedAt = started;
        shutdownAt = started + MIN_SHUTDOWN_DELAY;
        _setLifecycle(Lifecycle.SHUTDOWN_PENDING);
        emit ShutdownInitiated(started, shutdownAt);
    }

    function extendShutdown(uint64 newShutdownAt) external onlyGuardian onlyLifecycle(Lifecycle.SHUTDOWN_PENDING) {
        if (newShutdownAt <= shutdownAt) revert InvalidConfiguration();
        shutdownAt = newShutdownAt;
        emit ShutdownExtended(newShutdownAt);
    }

    function terminate() external onlyGuardian onlyLifecycle(Lifecycle.SHUTDOWN_PENDING) {
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
        _setLifecycle(Lifecycle.TERMINATED);
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
        if (lifecycle != Lifecycle.ACTIVE) revert InvalidLifecycle();
        if (amount == 0 || runUsed[runId]) revert InvalidRun();
        uint256 freeCapital = strategyCapital - activePrincipal;
        if (amount > freeCapital) revert InsufficientFreeCapital();
        runUsed[runId] = true;
        runPrincipal[runId] = amount;
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
                holderRewardPool[windowId] += holderPart;
                holderWindowStart[windowId] = windowStart;
                holderWindowEnd[windowId] = windowEnd;
                holderUnfinalizedWindowPoolTotal += holderPart;
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
    function reserveFinalizedHolderDistribution(
        bytes32 distributionId,
        bytes32 windowId,
        uint32 commitmentVersion,
        uint256 totalPayable,
        uint16 expectedEntryCount
    ) external {
        _onlyHolderDistributor();
        if (
            commitmentVersion != 1 || totalPayable == 0 || expectedEntryCount == 0 || expectedEntryCount > 30
                || holderWindowClassified[windowId]
        ) revert InvalidHolderContext();
        uint256 pool = holderRewardPool[windowId];
        if (pool == 0 || pool != totalPayable || holderWindowDistribution[windowId] != bytes32(0)) {
            revert InvalidHolderContext();
        }
        (uint64 windowStart, uint64 windowEnd) = _windowBoundsForId(windowId);
        if (distributionId != _holderDistributionId(windowId)) revert InvalidHolderContext();

        if (block.timestamp < windowEnd) revert InvalidHolderContext();
        uint64 acceptedAt = uint64(block.timestamp);
        uint64 executableAfter = acceptedAt + 1_800;
        holderWindowDistribution[windowId] = distributionId;
        _holderDistributions[distributionId] = HolderDistribution({
            windowId: windowId,
            version: commitmentVersion,
            acceptedAt: acceptedAt,
            executableAfter: executableAfter,
            totalPayable: totalPayable,
            entriesRegistered: 0,
            entryCount: 0,
            expectedEntryCount: expectedEntryCount,
            finalized: false,
            exists: true,
            correctionLocked: false
        });
        holderRewardPool[windowId] = 0;
        holderUnfinalizedWindowPoolTotal -= pool;
        holderCandidateReviewPoolTotal += pool;
        emit HolderDistributionReserved(distributionId, windowId, commitmentVersion, totalPayable, acceptedAt, executableAfter);
        _assertAccounting();
        // Bounds were checked by _windowBoundsForId and are emitted on accrual.
        windowStart;
    }

    /// @notice Replace only the current candidate for the same distribution and economic pool.
    /// @dev Old entry slots remain as audit data and become inert through their version tag.
    function correctHolderDistribution(
        bytes32 distributionId,
        uint32 newVersion,
        uint16 expectedEntryCount
    ) external {
        _onlyHolderDistributor();
        HolderDistribution storage distribution = _holderDistributions[distributionId];
        uint32 oldVersion = distribution.version;
        if (
            !distribution.exists || distribution.correctionLocked || oldVersion == type(uint32).max
                || newVersion != oldVersion + 1
                || expectedEntryCount == 0 || expectedEntryCount > 30
        ) revert InvalidHolderContext();

        if (distribution.finalized) {
            // A successful or failed payout attempt locks correction before this point.
            // Hence all active entries are still unpaid and counted as automatic liabilities.
            holderFinalizedUnpaidLiabilityTotal -= distribution.totalPayable;
            holderPendingAutomaticEntryCount -= distribution.entryCount;
            holderCandidateReviewPoolTotal += distribution.totalPayable;
            distribution.finalized = false;
        }

        uint64 acceptedAt = uint64(block.timestamp);
        uint64 executableAfter = acceptedAt + 1_800;
        distribution.version = newVersion;
        distribution.acceptedAt = acceptedAt;
        distribution.executableAfter = executableAfter;
        distribution.entriesRegistered = 0;
        distribution.entryCount = 0;
        distribution.expectedEntryCount = expectedEntryCount;
        emit HolderDistributionCorrected(
            distributionId,
            distribution.windowId,
            oldVersion,
            newVersion,
            acceptedAt,
            executableAfter,
            distribution.totalPayable,
            expectedEntryCount
        );
        _assertAccounting();
    }

    function registerHolderRewardEntry(
        bytes32 distributionId,
        uint32 commitmentVersion,
        bytes32 windowId,
        uint16 recipientIndex,
        address recipient,
        uint256 amount
    ) external {
        _onlyHolderDistributor();
        HolderDistribution storage distribution = _holderDistributions[distributionId];
        if (
            !distribution.exists || distribution.finalized || distribution.version != commitmentVersion
                || distribution.windowId != windowId || recipientIndex >= 30 || recipient == address(0) || amount == 0
        ) revert InvalidHolderContext();
        HolderEntry storage entry = _holderEntries[distributionId][recipientIndex];
        if (
            (entry.version == commitmentVersion && entry.status != HolderEntryStatus.NONE)
                || distribution.entriesRegistered + amount > distribution.totalPayable
        ) {
            revert InvalidHolderContext();
        }
        entry.recipient = recipient;
        entry.amount = amount;
        entry.version = commitmentVersion;
        entry.status = HolderEntryStatus.CANDIDATE_REVIEW;
        distribution.entriesRegistered += amount;
        distribution.entryCount += 1;
        emit HolderLiabilityRegistered(distributionId, windowId, commitmentVersion, recipientIndex, recipient, amount);
        _assertHolderPartition();
    }

    function finalizeHolderDistribution(bytes32 distributionId, uint32 commitmentVersion) external {
        _onlyHolderDistributor();
        HolderDistribution storage distribution = _holderDistributions[distributionId];
        if (
            !distribution.exists || distribution.finalized || distribution.version != commitmentVersion
                || block.timestamp < distribution.executableAfter || distribution.entriesRegistered != distribution.totalPayable
                || distribution.entryCount != distribution.expectedEntryCount
        ) revert HolderReviewActive();
        uint256 committedEntries;
        for (uint16 recipientIndex; recipientIndex < 30; ++recipientIndex) {
            HolderEntry storage entry = _holderEntries[distributionId][recipientIndex];
            if (entry.version == commitmentVersion && entry.status == HolderEntryStatus.CANDIDATE_REVIEW) {
                entry.status = HolderEntryStatus.COMMITTED_UNPAID;
                ++committedEntries;
            }
        }
        if (committedEntries != distribution.entryCount) revert HolderReviewActive();
        distribution.finalized = true;
        holderCandidateReviewPoolTotal -= distribution.totalPayable;
        holderFinalizedUnpaidLiabilityTotal += distribution.totalPayable;
        holderPendingAutomaticEntryCount += distribution.entryCount;
        emit HolderDistributionFinalized(distributionId, commitmentVersion, distribution.totalPayable);
        _assertAccounting();
    }

    function payCommittedHolderEntry(
        bytes32 distributionId,
        uint32 commitmentVersion,
        bytes32 windowId,
        uint16 recipientIndex,
        address recipient,
        address rewardAsset,
        uint256 amount
    ) external nonReentrant {
        _onlyHolderDistributor();
        _payHolderEntry(distributionId, commitmentVersion, windowId, recipientIndex, recipient, rewardAsset, amount, false, false);
    }

    /// @notice Persist failure only after a caller has caught the reverted exact payout subcall.
    function markHolderEntryFailed(
        bytes32 distributionId,
        uint32 commitmentVersion,
        bytes32 windowId,
        uint16 recipientIndex,
        address recipient,
        address rewardAsset,
        uint256 amount
    ) external {
        _onlyHolderDistributor();
        HolderEntry storage entry = _checkedHolderEntry(
            distributionId, commitmentVersion, windowId, recipientIndex, recipient, rewardAsset, amount
        );
        if (entry.status != HolderEntryStatus.COMMITTED_UNPAID) revert HolderEntryUnavailable();
        entry.status = HolderEntryStatus.FAILED_PENDING_MANUAL;
        _holderDistributions[distributionId].correctionLocked = true;
        holderPendingAutomaticEntryCount -= 1;
        holderFailedNotAvailableCount += 1;
        emit HolderPayoutFailed(distributionId, windowId, commitmentVersion, recipientIndex, recipient, amount);
        _assertHolderPartition();
    }

    function markManualSettlementAvailable(
        bytes32 distributionId,
        uint32 commitmentVersion,
        bytes32 windowId,
        uint16 recipientIndex
    ) external onlyRole(HOLDER_REWARD_SETTLER_ROLE) {
        HolderEntry storage entry = _holderEntries[distributionId][recipientIndex];
        if (
            entry.version != commitmentVersion || entry.status != HolderEntryStatus.FAILED_PENDING_MANUAL
                || entry.manualSettlementAvailable
                || _holderDistributions[distributionId].version != commitmentVersion
                || _holderDistributions[distributionId].windowId != windowId
        ) revert HolderEntryUnavailable();
        entry.manualSettlementAvailable = true;
        holderFailedNotAvailableCount -= 1;
        emit HolderManualSettlementAvailable(distributionId, commitmentVersion, windowId, recipientIndex);
    }

    function settleFailedHolderEntry(
        bytes32 distributionId,
        uint32 commitmentVersion,
        bytes32 windowId,
        uint16 recipientIndex,
        address recipient,
        address rewardAsset,
        uint256 amount
    ) external nonReentrant onlyRole(HOLDER_REWARD_SETTLER_ROLE) {
        HolderEntry storage entry = _checkedHolderEntry(
            distributionId, commitmentVersion, windowId, recipientIndex, recipient, rewardAsset, amount
        );
        if (
            (entry.status != HolderEntryStatus.FAILED_PENDING_MANUAL && entry.status != HolderEntryStatus.TERMINAL_PENDING)
                || !entry.manualSettlementAvailable
                || (entry.status == HolderEntryStatus.TERMINAL_PENDING && block.timestamp >= entry.terminalGraceStartAt + TERMINAL_GRACE_SECONDS)
        ) revert HolderEntryUnavailable();
        _completeHolderPayment(distributionId, windowId, commitmentVersion, recipientIndex, recipient, amount, true, entry.status);
    }

    function startTerminalHolderLiability(
        bytes32 distributionId,
        uint32 commitmentVersion,
        bytes32 windowId,
        uint16 recipientIndex
    ) external {
        _onlyHolderDistributor();
        HolderDistribution storage distribution = _holderDistributions[distributionId];
        HolderEntry storage entry = _holderEntries[distributionId][recipientIndex];
        if (
            entry.version != commitmentVersion || entry.status != HolderEntryStatus.FAILED_PENDING_MANUAL
                || !entry.manualSettlementAvailable
        ) revert HolderEntryUnavailable();
        if (
            lifecycle != Lifecycle.TERMINATED || !distribution.finalized || distribution.version != commitmentVersion
                || distribution.windowId != windowId || holderUnfinalizedWindowPoolTotal != 0
                || holderCandidateReviewPoolTotal != 0 || holderPendingAutomaticEntryCount != 0
                || holderFailedNotAvailableCount != 0
        ) revert HolderReconciliationIncomplete();
        uint64 start = uint64(block.timestamp);
        entry.terminalGraceStartAt = start;
        entry.status = HolderEntryStatus.TERMINAL_PENDING;
        distribution.correctionLocked = true;
        emit HolderTerminalPending(distributionId, windowId, commitmentVersion, recipientIndex, start, start + TERMINAL_GRACE_SECONDS);
        _assertHolderPartition();
    }

    function expireTerminalHolderLiability(
        bytes32 distributionId,
        uint32 commitmentVersion,
        bytes32 windowId,
        uint16 recipientIndex,
        address recipient,
        address rewardAsset,
        uint256 amount
    ) external {
        HolderEntry storage entry = _checkedHolderEntry(
            distributionId, commitmentVersion, windowId, recipientIndex, recipient, rewardAsset, amount
        );
        if (entry.status != HolderEntryStatus.TERMINAL_PENDING) revert HolderEntryUnavailable();
        if (block.timestamp < entry.terminalGraceStartAt + TERMINAL_GRACE_SECONDS) revert HolderGraceActive();
        entry.status = HolderEntryStatus.TERMINAL_EXPIRED;
        holderFinalizedUnpaidLiabilityTotal -= amount;
        holderRecoveryEligibleTotal += amount;
        emit HolderLiabilityExpired(distributionId, windowId, commitmentVersion, recipientIndex, amount);
        _assertAccounting();
    }

    function classifyEmptyHolderWindow(bytes32 windowId) external {
        _onlyHolderDistributor();
        if (holderWindowClassified[windowId] || holderWindowDistribution[windowId] != bytes32(0)) revert InvalidHolderContext();
        (uint64 start, uint64 end) = _windowBoundsForId(windowId);
        if (block.timestamp < end) revert InvalidHolderContext();
        start;
        uint256 pool = holderRewardPool[windowId];
        if (pool == 0) revert InvalidHolderContext();
        holderWindowClassified[windowId] = true;
        holderRewardPool[windowId] = 0;
        holderUnfinalizedWindowPoolTotal -= pool;
        holderUnallocatedNoRecipientPoolTotal += pool;
        emit HolderWindowClassifiedUnallocated(windowId, pool);
        _assertAccounting();
    }

    function classifyUnallocatedHolderPoolsForRecovery() external {
        if (
            lifecycle != Lifecycle.TERMINATED || holderUnfinalizedWindowPoolTotal != 0 || holderCandidateReviewPoolTotal != 0
                || holderFinalizedUnpaidLiabilityTotal != 0 || holderPendingAutomaticEntryCount != 0
                || holderFailedNotAvailableCount != 0
        ) revert HolderReconciliationIncomplete();
        uint256 amount = holderUnallocatedNoRecipientPoolTotal;
        if (amount == 0) revert InvalidAmount();
        holderUnallocatedNoRecipientPoolTotal = 0;
        holderRecoveryEligibleTotal += amount;
        emit HolderRecoveryEligibilityClassified(amount);
        _assertAccounting();
    }

    function recoverEligibleHolderRewards() external onlyGuardian nonReentrant onlyLifecycle(Lifecycle.TERMINATED) {
        uint256 amount = holderRecoveryEligibleTotal;
        if (amount == 0 || amount > holderRewardReserve) revert NotSurplus();
        holderRecoveryEligibleTotal = 0;
        holderRewardReserve -= amount;
        accountedQuote -= amount;
        _transferQuote(RECOVERY_WALLET, amount);
        _assertAccounting();
        emit HolderRewardsRecovered(amount, RECOVERY_WALLET);
    }

    function releaseBuybackReserve(uint256 amount) external nonReentrant {
        if (msg.sender != buybackExecutor) revert Unauthorized();
        if (lifecycle != Lifecycle.ACTIVE) revert InvalidLifecycle();
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
        if (lifecycle != Lifecycle.ACTIVE) revert InvalidLifecycle();
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
            lifecycle != Lifecycle.ACTIVE && lifecycle != Lifecycle.PAUSED
                && lifecycle != Lifecycle.SHUTDOWN_PENDING && lifecycle != Lifecycle.TERMINATED
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
    function recoverTerminatedAsset(address asset) external onlyGuardian nonReentrant onlyLifecycle(Lifecycle.TERMINATED) {
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

    function totalAccountedBuckets() external view returns (uint256) {
        return strategyCapital + buybackReserve + protocolReserve + holderRewardReserve;
    }

    function freeStrategyCapital() external view returns (uint256) {
        return strategyCapital - activePrincipal;
    }

    function _setLifecycle(Lifecycle next) private {
        Lifecycle previous = lifecycle;
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
        if (strategyCapital + buybackReserve + protocolReserve + holderRewardReserve != accountedQuote + activePrincipal) {
            revert AccountingInvariant();
        }
        // Accounted quote must remain physically present in the Vault. Principal
        // outside the Vault is represented separately by activePrincipal.
        if (_assetBalance(quoteToken) < accountedQuote) revert AccountingInvariant();
        _assertHolderPartition();
    }

    function _assertHolderPartition() private view {
        if (
            holderUnfinalizedWindowPoolTotal + holderCandidateReviewPoolTotal + holderFinalizedUnpaidLiabilityTotal
                + holderUnallocatedNoRecipientPoolTotal + holderRecoveryEligibleTotal != holderRewardReserve
        ) revert AccountingInvariant();
    }

    function _onlyHolderDistributor() private view {
        if (holderRewardsDistributor == address(0) || msg.sender != holderRewardsDistributor) revert Unauthorized();
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

    function _windowBoundsForId(bytes32 windowId) private view returns (uint64 start, uint64 end) {
        start = holderWindowStart[windowId];
        end = holderWindowEnd[windowId];
        if (start == 0 || end != start + HOLDER_WINDOW_SECONDS || holderWindowId(start, end) != windowId) {
            revert InvalidHolderContext();
        }
    }

    function _holderDistributionId(bytes32 windowId) private view returns (bytes32) {
        return keccak256(abi.encode(HOLDER_DISTRIBUTION_TYPEHASH, holderDomainSeparator(), windowId));
    }

    function _checkedHolderEntry(
        bytes32 distributionId,
        uint32 commitmentVersion,
        bytes32 windowId,
        uint16 recipientIndex,
        address recipient,
        address rewardAsset,
        uint256 amount
    ) private view returns (HolderEntry storage entry) {
        HolderDistribution storage distribution = _holderDistributions[distributionId];
        entry = _holderEntries[distributionId][recipientIndex];
        if (
            !distribution.exists || !distribution.finalized || distribution.version != commitmentVersion
                || distribution.windowId != windowId || recipient == address(0) || entry.recipient != recipient
                || entry.version != commitmentVersion || rewardAsset != quoteToken || amount == 0
                || entry.amount != amount
                || block.timestamp < distribution.executableAfter
        ) revert InvalidHolderContext();
    }

    function _payHolderEntry(
        bytes32 distributionId,
        uint32 commitmentVersion,
        bytes32 windowId,
        uint16 recipientIndex,
        address recipient,
        address rewardAsset,
        uint256 amount,
        bool manual,
        bool allowFailed
    ) private {
        HolderEntry storage entry = _checkedHolderEntry(
            distributionId, commitmentVersion, windowId, recipientIndex, recipient, rewardAsset, amount
        );
        if (
            entry.status != HolderEntryStatus.COMMITTED_UNPAID
                && !(allowFailed && entry.status == HolderEntryStatus.FAILED_PENDING_MANUAL)
                && entry.status != HolderEntryStatus.TERMINAL_PENDING
        ) revert HolderEntryUnavailable();
        if (entry.status == HolderEntryStatus.FAILED_PENDING_MANUAL && !entry.manualSettlementAvailable) {
            revert HolderEntryUnavailable();
        }
        if (
            entry.status == HolderEntryStatus.TERMINAL_PENDING
                && block.timestamp >= entry.terminalGraceStartAt + TERMINAL_GRACE_SECONDS
        ) revert HolderGraceActive();
        _completeHolderPayment(distributionId, windowId, commitmentVersion, recipientIndex, recipient, amount, manual, entry.status);
    }

    function _completeHolderPayment(
        bytes32 distributionId,
        bytes32 windowId,
        uint32 commitmentVersion,
        uint16 recipientIndex,
        address recipient,
        uint256 amount,
        bool manual,
        HolderEntryStatus previousStatus
    ) private {
        HolderEntry storage entry = _holderEntries[distributionId][recipientIndex];
        if (previousStatus == HolderEntryStatus.COMMITTED_UNPAID) holderPendingAutomaticEntryCount -= 1;
        _holderDistributions[distributionId].correctionLocked = true;
        entry.status = HolderEntryStatus.PAID;
        holderFinalizedUnpaidLiabilityTotal -= amount;
        holderRewardReserve -= amount;
        accountedQuote -= amount;
        _transferQuote(recipient, amount);
        _assertAccounting();
        emit HolderPayoutSucceeded(distributionId, windowId, commitmentVersion, recipientIndex, recipient, amount, manual);
    }

    function _validProtocolCategory(bytes32 category) private pure returns (bool) {
        return category == keccak256("OPERATIONS") || category == keccak256("SECURITY")
            || category == keccak256("INFRASTRUCTURE") || category == keccak256("AUDIT")
            || category == keccak256("LEGAL") || category == keccak256("PARTNERSHIPS");
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
