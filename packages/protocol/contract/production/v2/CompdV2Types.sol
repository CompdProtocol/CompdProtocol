// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

/// @notice ABI identities shared by the fresh, non-proxy Production V2 graph.
library CompdV2Types {
    // Numeric values 0..3 are frozen by V1. Emergency recovery is an appended state.
    enum Lifecycle {
        ACTIVE,
        PAUSED,
        SHUTDOWN_PENDING,
        TERMINATED,
        EMERGENCY_RECOVERY
    }

    enum EmergencyProcessingStatus {
        NOT_STARTED,
        IN_PROGRESS,
        COMPLETE_WITHIN_REGISTERED_SCOPE,
        COMPLETE_WITH_UNRESOLVED
    }

    /// @dev Identity order is an ABI/event identity. Distributor and Factory hold no protocol assets.
    enum ModuleId {
        VAULT,
        STRATEGY_EXECUTOR,
        BUYBACK_EXECUTOR,
        THIN_FLAP_RECEIVER
    }

    enum EmergencyRunStatus {
        EXIT_REQUIRED,
        EXIT_ATTEMPTED,
        EXIT_SETTLED,
        EXIT_BLOCKED,
        ASYNC_EXIT_PENDING
    }

    enum EmergencyAssetStatus {
        UNREGISTERED,
        REGISTERED,
        DISCOVERED_AFTER_INITIATION,
        ZERO_BALANCE,
        RECOVERED,
        FAILED_RETRYABLE,
        UNSUPPORTED,
        BLOCKED,
        TRANSFERRED_UNVERIFIED
    }

    enum EmergencyAttemptOutcome {
        NONE,
        SUCCESS,
        NO_BALANCE,
        FAILED_RETRYABLE,
        UNSUPPORTED,
        BLOCKED,
        TRANSFERRED_UNVERIFIED
    }

    enum EmergencySnapshotCellStatus {
        NOT_RECORDED,
        RECORDED,
        UNAVAILABLE
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

    enum EmptyCandidateStatus {
        NONE,
        REVIEW_PENDING,
        FINALIZED_NO_RECIPIENT,
        SUPERSEDED,
        RECOVERY_ELIGIBLE,
        RECOVERED
    }

    /// @dev Scalar snapshot only. Per-module/per-asset observations are indexed records.
    struct EmergencySnapshot {
        bytes32 snapshotId;
        bytes32 accountingSnapshotHash;
        bytes32 activeRunInventoryHash;
        bytes32 assetManifestHash;
        Lifecycle lifecycleBefore;
        address initiatedBy;
        uint64 startedAt;
        uint64 startedBlock;
        uint256 strategyCapital;
        uint256 buybackReserve;
        uint256 protocolReserve;
        uint256 holderRewardReserve;
        uint256 holderUnfinalizedWindowPool;
        uint256 holderNormalReviewPool;
        uint256 holderEmptyReviewPool;
        uint256 holderFinalizedUnpaid;
        uint256 holderNoRecipientPool;
        uint256 holderRecoveryEligible;
        uint256 accountedQuote;
        uint256 activePrincipal;
        uint256 finalizedUnpaidTotal;
        uint256 cumulativeRevenue;
        uint256 cumulativeRealizedProfit;
        uint256 cumulativeRealizedLoss;
        uint256 vaultQuoteBalance;
        uint32 activeRunCount;
        uint32 holderPendingAutomaticCount;
        uint32 holderFailedNotAvailableCount;
        uint32 openNormalReviewCount;
        uint32 openEmptyReviewCount;
        uint32 terminalPendingCount;
        uint32 recoveryEligibleLiabilityCount;
        uint16 registeredModuleCount;
        uint16 registeredAssetCount;
        EmergencySnapshotCellStatus snapshotStatus;
    }

    /// @dev One bounded module/asset status record; failures retain only a hash, never revert payload.
    struct EmergencyAssetRecord {
        ModuleId moduleId;
        address module;
        address asset;
        EmergencyAssetStatus status;
        EmergencySnapshotCellStatus snapshotStatus;
        uint32 attemptCount;
        uint64 lastAttemptAt;
        uint64 lastAttemptBlock;
        uint256 balanceAtSnapshot;
        uint256 lastBalanceBefore;
        uint256 lastBalanceAfter;
        uint256 amountDebited;
        uint256 amountCredited;
        bytes32 lastFailureCode;
        bytes32 lastRevertDataHash;
    }

    /// @dev Indexed attempt history ABI; persistent implementation arrives after this foundation stage.
    struct EmergencyAttempt {
        bytes32 attemptId;
        uint32 attemptNumber;
        ModuleId moduleId;
        address asset;
        uint256 runId;
        address caller;
        uint64 timestamp;
        uint64 blockNumber;
        uint256 balanceBefore;
        uint256 balanceAfter;
        uint256 walletBalanceBefore;
        uint256 walletBalanceAfter;
        uint256 amountDebited;
        uint256 amountCredited;
        EmergencyAttemptOutcome outcome;
        bytes32 failureCode;
        bytes32 revertDataHash;
    }

    /// @dev Pool-level overlay; this is not an individual Holder priority allocation.
    struct EmergencyHolderBacking {
        uint256 holderRewardReserve;
        uint256 accountedQuote;
        uint256 vaultQuoteBalance;
        uint256 nonHolderQuoteObligations;
        uint256 holderBackingAvailable;
        uint256 holderBackingDeficit;
        uint256 holderUnpaidTotal;
        uint256 preEmergencyDeficit;
        uint256 emergencyCausedDeficit;
    }

    /// @dev Bounded scalar reconciliation summary. Detailed history is exposed by indexed getters.
    struct EmergencyReconciliation {
        Lifecycle lifecycle;
        EmergencyProcessingStatus processingStatus;
        uint64 reconciledAt;
        uint32 unresolvedRunCount;
        uint32 unresolvedAssetAttemptCount;
        uint32 unavailableSnapshotCellCount;
        uint16 registeredModuleCount;
        uint16 registeredAssetCount;
        uint256 recognizedReceiverRevenuePending;
        uint256 cumulativeQuoteEmergencyOutflow;
        EmergencyHolderBacking holderBacking;
        bytes32 manifestCoverageHash;
        uint256 strategyCapital;
        uint256 buybackReserve;
        uint256 protocolReserve;
        uint256 holderRewardReserve;
        uint256 accountedQuote;
        uint256 activePrincipal;
        uint256 holderUnfinalizedWindowPool;
        uint256 holderNormalReviewPool;
        uint256 holderEmptyReviewPool;
        uint256 holderFinalizedUnpaid;
        uint256 holderNoRecipientPool;
        uint256 holderRecoveryEligible;
    }

    /// @notice Local implementation candidate only; final cap requires gas measurement before freeze.
    uint16 internal constant LOCAL_ASSET_MANIFEST_CAP_CANDIDATE = 16;

    function canAppendManifestEntry(uint256 currentLength) internal pure returns (bool) {
        return currentLength < LOCAL_ASSET_MANIFEST_CAP_CANDIDATE;
    }
}

/// @notice V2 known role identities used for constructor-time emergency-role anti-aliasing.
/// @dev Unresolved Finalizer/Settler/config role addresses must be checked in the deployment manifest.
library CompdV2KnownRoles {
    address internal constant GUARDIAN = 0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    address internal constant RECOVERY_TREASURY = 0xFa8706AA97B07cb29096381f9101784bA0d1332b;
    address internal constant AUTOMATION_EXECUTOR = 0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;
    address internal constant RESERVED_COMPD_IDENTITY = 0x7b7Af51136574c91A12988989c0a08E98aE97777;
    address internal constant BUYBACK_ADMIN = 0x29BB16dB8e9f2371255BA75aF83aECaFB2CC00BA;
    address internal constant DEV_CREATOR = 0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;
}

library CompdV2Errors {
    error UnauthorizedEmergencyAuthority();
    error EmergencyAlreadyInitiated();
    error EmergencyNotInitiated();
    error InvalidLifecycle();
    error InvalidImmutableConfiguration();
    error InvalidModuleId();
    error EmergencyAssetNotRegistered();
    error EmergencyManifestCapacityReached();
    error UnknownEmergencyRun();
    error EmergencyRunAlreadySettled();
    error EmergencyOperationUnsupported();
    error InvalidEmergencySnapshot();
    error EmergencyRetryNotAllowed();
    error EmergencyInvariantFailure();
    error FixedEmergencyDestinationMismatch();
    error ImplementationDeferred();
}
