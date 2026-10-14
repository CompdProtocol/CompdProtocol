// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {CompdV2Types} from "./CompdV2Types.sol";

/// @notice Additive Phase 6C-2B ABI delta; it does not change the existing C1/C2 Vault implementation.
interface ICompdProductionVaultV2Decomposition {
    struct ActivationReadiness {
        bool paused;
        bool holderWorkflowBound;
        bool holderLiabilityBound;
        bool emergencyRegistryBound;
        bool holderWorkflowIdentityValid;
        bool holderLiabilityIdentityValid;
        bool registryIdentityValid;
        bool holderWorkflowRuntimeHashValid;
        bool holderLiabilityRuntimeHashValid;
        bool registryRuntimeHashValid;
        bool requiredRolesConfigured;
        bool immutableDestinationsValid;
    }

    struct HolderPartitionTotals {
        uint256 unfinalizedWindowPools;
        uint256 normalReviewPools;
        uint256 emptyReviewPools;
        uint256 finalizedUnpaidLiabilities;
        uint256 finalizedNoRecipientPools;
        uint256 recoveryEligible;
        uint256 noRecipientRecoveryEligible;
        uint256 expiredLiabilityRecoveryEligible;
        uint256 terminalPendingSubset;
        uint256 terminalExpiredSubset;
        uint256 noRecipientEligibleSubset;
        uint32 openNormalReviews;
        uint32 openEmptyReviews;
        uint32 pendingAutomatic;
        uint32 failedUnavailable;
        uint32 finalizedUnpaidRecords;
        uint32 terminalPendingRecords;
    }

    error OnlyConfigurationAdmin();
    error BindingRequiresPaused();
    error BindingAlreadySet();
    error InvalidComponentAddress();
    error InvalidComponentType();
    error InvalidComponentVersion();
    error InvalidComponentVault();
    error ComponentCodeHashMismatch();
    error ActivationGraphIncomplete();
    error HolderPartitionInvariant();
    error HolderRecoveryClassificationInvalid();
    error DuplicateWindowId(bytes32 windowId);
    error BatchLimitExceeded();

    event HolderWorkflowBound(address indexed component, bytes32 runtimeCodeHash);
    event HolderLiabilityBound(address indexed component, bytes32 runtimeCodeHash);
    event EmergencyRegistryBound(address indexed component, bytes32 runtimeCodeHash);
    event NoRecipientPoolsClassified(bytes32 indexed batchId, uint16 windowCount, uint256 exactTotal);

    /// @notice Deployment-only, config-admin-only, once-only while PAUSED. No unbind/replace exists.
    function bindHolderWorkflow(address component) external;
    function bindHolderLiability(address component) external;
    function bindEmergencyRegistry(address component) external;
    function holderWorkflow() external view returns (address);
    function holderLiability() external view returns (address);
    function emergencyRegistry() external view returns (address);
    function expectedHolderWorkflowRuntimeCodeHash() external view returns (bytes32);
    function expectedHolderLiabilityRuntimeCodeHash() external view returns (bytes32);
    function expectedEmergencyRegistryRuntimeCodeHash() external view returns (bytes32);
    function activationReadiness() external view returns (ActivationReadiness memory);
    function holderPartitionTotals() external view returns (HolderPartitionTotals memory);

    /// @notice Existing owner-approved C2-ABI-02 selector, bounded without a frozen numeric cap.
    function classifyNoRecipientPoolsForRecovery(bytes32[] calldata windowIds) external;

    /// @notice Diagnostic query used at security-critical accounting boundaries; mismatch fails closed.
    function holderPartitionInvariant() external view returns (
        uint256 vaultHolderRewardReserve,
        uint256 componentPartitionSum,
        bool holds
    );
}
