// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICompdProductionVaultView {
    function quoteToken() external view returns (address);
    function lifecycle() external view returns (uint8);
    function strategyCapital() external view returns (uint256);
    function buybackReserve() external view returns (uint256);
    function activePrincipal() external view returns (uint256);
    function holderRewardReserve() external view returns (uint256);
    function allocateStrategyPrincipal(uint256 runId, uint256 amount) external;
    function settleStrategyPrincipal(uint256 runId, uint256 returnedAmount) external payable;
    function releaseBuybackReserve(uint256 amount) external;
}

/// @notice Narrow Vault boundary for the future Holder Rewards Distributor.
/// @dev Every payment/retry repeats the exact committed context; there is no arbitrary recipient/amount transfer.
interface ICompdHolderRewardsVault {
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

    function holderDomainSeparator() external view returns (bytes32);
    function holderWindowId(uint64 windowStart, uint64 windowEnd) external view returns (bytes32);
    function holderRewardPool(bytes32 windowId) external view returns (uint256);
    function holderDistributionVersion(bytes32 distributionId) external view returns (uint32);
    function holderRewardEntry(bytes32 distributionId, uint16 recipientIndex) external view returns (HolderEntry memory);
    function reserveFinalizedHolderDistribution(
        bytes32 distributionId,
        bytes32 windowId,
        uint32 commitmentVersion,
        uint256 totalPayable,
        uint16 expectedEntryCount
    ) external;
    function correctHolderDistribution(bytes32 distributionId, uint32 newVersion, uint16 expectedEntryCount) external;
    function registerHolderRewardEntry(
        bytes32 distributionId,
        uint32 commitmentVersion,
        bytes32 windowId,
        uint16 recipientIndex,
        address recipient,
        uint256 amount
    ) external;
    function finalizeHolderDistribution(bytes32 distributionId, uint32 commitmentVersion) external;
    function payCommittedHolderEntry(
        bytes32 distributionId,
        uint32 commitmentVersion,
        bytes32 windowId,
        uint16 recipientIndex,
        address recipient,
        address rewardAsset,
        uint256 amount
    ) external;
    function markHolderEntryFailed(
        bytes32 distributionId,
        uint32 commitmentVersion,
        bytes32 windowId,
        uint16 recipientIndex,
        address recipient,
        address rewardAsset,
        uint256 amount
    ) external;
    function markManualSettlementAvailable(
        bytes32 distributionId, uint32 commitmentVersion, bytes32 windowId, uint16 recipientIndex
    ) external;
    function settleFailedHolderEntry(
        bytes32 distributionId,
        uint32 commitmentVersion,
        bytes32 windowId,
        uint16 recipientIndex,
        address recipient,
        address rewardAsset,
        uint256 amount
    ) external;
    function startTerminalHolderLiability(
        bytes32 distributionId, uint32 commitmentVersion, bytes32 windowId, uint16 recipientIndex
    ) external;
    function expireTerminalHolderLiability(
        bytes32 distributionId,
        uint32 commitmentVersion,
        bytes32 windowId,
        uint16 recipientIndex,
        address recipient,
        address rewardAsset,
        uint256 amount
    ) external;
    function classifyEmptyHolderWindow(bytes32 windowId) external;
    function classifyUnallocatedHolderPoolsForRecovery() external;
    function recoverEligibleHolderRewards() external;
}

interface ICompdProductionVaultReceiver is ICompdProductionVaultView {
    function registerFlapRevenue(uint256 amount) external payable;
    function registerFlapReceiver(address receiver) external;
}

interface ICompdFlapReceiverView {
    function productionVault() external view returns (address);
    function factory() external view returns (address);
    function taxToken() external view returns (address);
    function vaultQuoteToken() external view returns (address);
    function accountedQuote() external view returns (uint256);
}

interface ICompdProductionVaultFactoryView {
    function productionVault() external view returns (address);
    function COMPD_TOKEN() external view returns (address);
}

interface ICompdStrategyExecutorIdentity {
    function vault() external view returns (address);
    function AUTOMATION_EXECUTOR() external view returns (address);
    function GUARDIAN() external view returns (address);
}

interface ICompdBuybackExecutorIdentity {
    function vault() external view returns (address);
    function AUTOMATION_EXECUTOR() external view returns (address);
    function COMPD_TOKEN() external view returns (address);
    function PROTOCOL_BUYBACK_ADMIN() external view returns (address);
}

interface ICompdStrategyExecutorView {
    function activePositionCount() external view returns (uint256);
    function outstandingPrincipal() external view returns (uint256);
    function canFinalizeShutdown() external view returns (bool);
}

interface ICompdBuybackReserveObserver {
    function checkpointReserveBeforeChange(uint256 reserveBefore) external;
}

interface ICompdStrategyCapitalObserver {
    function checkpointCapitalBeforeChange(uint256 capitalBefore) external;
}

interface ICompdStrategyAdapter {
    /// @dev The adapter must spend exactly `amount` of quote asset to open a spot-only position.
    function openPosition(uint256 runId, bytes32 market, address asset, uint256 amount, uint256 declaredMaxLoss)
        external
        payable;

    /// @dev Close one position and return proceeds in the vault's quote asset to the caller.
    function closePosition(uint256 runId) external returns (uint256 quoteReturned);
}

interface ICompdEquityOracle {
    /// @dev Must value free strategy capital, open spot positions, and unsettled receivables in quote units.
    function strategyEquity() external view returns (uint256 quoteValue, uint256 updatedAt);
}

interface ICompdBurnSink {
    /// @dev Receives purchased COMPD for the separately approved burn mechanism.
    function receiveBuyback(uint256 amount) external;
}
