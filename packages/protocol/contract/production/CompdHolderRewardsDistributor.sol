// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICompdHolderRewardsVault} from "./ICompdProductionInterfaces.sol";
import {ICompdHolderRewardsDistributor} from "./ICompdHolderRewardsDistributor.sol";

interface ICompdPhase3VaultIdentity {
    function quoteToken() external view returns (address);
    function COMPD_TOKEN() external view returns (address);
    function AUTOMATION_EXECUTOR() external view returns (address);
}

interface ICompdPhase3ActivationView {
    function holderRewardsActivationBlock() external view returns (uint256);
    function holderRewardsActivationBlockHash() external view returns (bytes32);
    function holderRewardsActivationTimestamp() external view returns (uint64);
}

/// @notice Non-custodial, proof-verifying boundary between an approved Holder dataset and the frozen Vault.
/// @dev Ranking, TWAB, exclusions, and Hamilton allocation are deliberately off-chain. Inclusion is not eligibility proof.
contract CompdHolderRewardsDistributor is AccessControl, ReentrancyGuard, ICompdHolderRewardsDistributor {
    bytes32 public constant override DISTRIBUTION_FINALIZER_ROLE = keccak256("DISTRIBUTION_FINALIZER");
    bytes32 public constant PROTOCOL_ID = keccak256(bytes("COMPD_HOLDER_REWARDS_V1"));
    bytes32 public constant DOMAIN_TYPEHASH = keccak256(bytes(
        "CompdHolderRewardsDomain(bytes32 protocolId,uint256 chainId,address compdToken,address vault,address distributor,address rewardAsset)"
    ));
    bytes32 public constant WINDOW_TYPEHASH = keccak256(bytes(
        "CompdHolderRewardWindow(bytes32 domainSeparator,uint256 activationBlock,bytes32 activationBlockHash,uint64 activationTimestamp,uint64 windowStart,uint64 windowEnd)"
    ));
    bytes32 public constant DISTRIBUTION_TYPEHASH = keccak256(bytes(
        "CompdHolderRewardDistribution(bytes32 domainSeparator,bytes32 windowId)"
    ));
    bytes32 public constant LEAF_TYPEHASH = keccak256(bytes(
        "CompdHolderRewardLeaf(bytes32 domainSeparator,bytes32 distributionId,uint32 commitmentVersion,bytes32 windowId,uint64 windowStart,uint64 windowEnd,address rewardAsset,uint256 windowPool,uint256 finalizedTotalPayable,uint16 recipientIndex,address recipient,uint256 amount,bytes32 datasetHash,uint32 algorithmVersion)"
    ));
    bytes32 public constant PADDING_TYPEHASH = keccak256(bytes(
        "CompdHolderRewardPadding(bytes32 domainSeparator,bytes32 distributionId,uint32 commitmentVersion,uint16 paddedIndex)"
    ));
    bytes32 public constant NODE_TYPEHASH = keccak256(bytes("CompdHolderRewardNode(bytes32 left,bytes32 right)"));
    bytes32 public constant COMMITMENT_TYPEHASH = keccak256(bytes(
        "CompdHolderRewardCommitment(bytes32 domainSeparator,bytes32 distributionId,bytes32 windowId,uint64 windowStart,uint64 windowEnd,address rewardAsset,uint256 windowPool,uint256 finalizedTotalPayable,uint16 recipientCount,bytes32 root,bytes32 datasetHash,uint32 algorithmVersion,uint32 commitmentVersion,uint64 acceptedAt,uint64 executableAfter)"
    ));

    uint32 public constant ALGORITHM_VERSION_V1 = 1;
    uint64 public constant REVIEW_SECONDS = 1_800;
    uint16 public constant MAX_RECIPIENTS = 30;

    error InvalidConfiguration();
    error InvalidCandidate();
    error CandidateAlreadyExists();
    error CandidateUnavailable();
    error InvalidProof();
    error DuplicateLeaf();
    error DuplicateRecipient();
    error IncompleteMaterialization();
    error ReviewActive();
    error StaleVaultVersion();
    error LeafUnavailable();
    error CorrectionLocked();

    ICompdHolderRewardsVault private immutable _vault;
    ICompdPhase3VaultIdentity private immutable _vaultView;
    address public immutable automationExecutor;

    struct Commitment {
        bytes32 domainSeparator;
        bytes32 windowId;
        uint64 windowStart;
        uint64 windowEnd;
        address rewardAsset;
        uint256 windowPool;
        uint256 finalizedTotalPayable;
        uint16 recipientCount;
        uint16 positiveEntryCount;
        bytes32 root;
        bytes32 datasetHash;
        uint32 algorithmVersion;
        uint32 commitmentVersion;
        uint64 acceptedAt;
        uint64 executableAfter;
        uint16 verifiedLeafCount;
        uint16 materializedEntryCount;
        uint256 materializedAmount;
        CandidateStatus status;
    }

    mapping(bytes32 distributionId => Commitment) private _commitments;
    mapping(bytes32 distributionId => mapping(uint32 version => bytes32)) public override rootByVersion;
    mapping(bytes32 distributionId => mapping(uint32 version => bytes32)) public override datasetHashByVersion;
    mapping(bytes32 distributionId => mapping(uint32 version => bytes32)) public override commitmentHashByVersion;
    mapping(bytes32 distributionId => mapping(uint32 version => bytes32)) public override correctionReasonHashByVersion;
    mapping(bytes32 distributionId => mapping(uint32 version => mapping(uint16 index => bool))) private _leafMaterialized;
    mapping(bytes32 distributionId => mapping(uint32 version => mapping(uint16 index => bool))) private _positiveLeaf;
    mapping(bytes32 distributionId => mapping(uint32 version => mapping(uint16 index => bool))) private _leafExecuted;
    mapping(bytes32 distributionId => mapping(uint32 version => mapping(uint16 index => bool))) private _leafFailed;
    mapping(bytes32 distributionId => mapping(uint32 version => mapping(uint16 index => bytes32))) private _leafHashes;
    mapping(bytes32 distributionId => mapping(uint32 version => mapping(address recipient => bool))) private _recipientMaterialized;

    event CandidateSubmitted(
        bytes32 indexed distributionId,
        bytes32 indexed windowId,
        uint32 indexed version,
        bytes32 root,
        bytes32 datasetHash,
        bytes32 commitmentHash,
        uint64 acceptedAt,
        uint64 executableAfter,
        uint16 recipientCount,
        uint16 positiveEntryCount
    );
    event CandidateCorrected(
        bytes32 indexed distributionId,
        uint32 indexed oldVersion,
        uint32 indexed newVersion,
        bytes32 oldRoot,
        bytes32 newRoot,
        bytes32 oldCommitmentHash,
        bytes32 newCommitmentHash,
        bytes32 reasonHash,
        uint64 acceptedAt,
        uint64 executableAfter
    );
    event LeafMaterialized(
        bytes32 indexed distributionId,
        uint32 indexed version,
        uint16 indexed recipientIndex,
        bytes32 leafHash,
        address recipient,
        uint256 amount,
        bool vaultLiability
    );
    event CandidateExecutable(bytes32 indexed distributionId, uint32 indexed version, bytes32 root, uint64 executableAfter);
    event AutomaticPayoutSucceeded(
        bytes32 indexed distributionId, uint32 indexed version, uint16 indexed recipientIndex, address recipient, uint256 amount
    );
    event AutomaticPayoutFailed(
        bytes32 indexed distributionId,
        uint32 indexed version,
        uint16 indexed recipientIndex,
        address recipient,
        uint256 amount,
        bytes32 revertDataHash
    );

    constructor(address vault_, address finalizer_) {
        if (vault_.code.length == 0 || finalizer_ == address(0)) revert InvalidConfiguration();
        ICompdPhase3VaultIdentity view_ = ICompdPhase3VaultIdentity(vault_);
        address automation = view_.AUTOMATION_EXECUTOR();
        if (automation == address(0) || automation == finalizer_) revert InvalidConfiguration();
        _vault = ICompdHolderRewardsVault(vault_);
        _vaultView = view_;
        automationExecutor = automation;
        _grantRole(DISTRIBUTION_FINALIZER_ROLE, finalizer_);
    }

    function submitCandidate(CandidateInput calldata candidate_) external override nonReentrant onlyRole(DISTRIBUTION_FINALIZER_ROLE) {
        if (_commitments[candidate_.distributionId].status != CandidateStatus.NONE) revert CandidateAlreadyExists();
        _validateCandidate(candidate_, 1, true);
        uint64 acceptedAt = _timestamp64();
        uint64 executableAfter = acceptedAt + REVIEW_SECONDS;

        _vault.reserveFinalizedHolderDistribution(
            candidate_.distributionId,
            candidate_.windowId,
            1,
            candidate_.finalizedTotalPayable,
            candidate_.positiveEntryCount
        );

        Commitment storage current = _commitments[candidate_.distributionId];
        current.domainSeparator = candidate_.domainSeparator;
        current.windowId = candidate_.windowId;
        current.windowStart = candidate_.windowStart;
        current.windowEnd = candidate_.windowEnd;
        current.rewardAsset = candidate_.rewardAsset;
        current.windowPool = candidate_.windowPool;
        current.finalizedTotalPayable = candidate_.finalizedTotalPayable;
        current.recipientCount = candidate_.recipientCount;
        current.positiveEntryCount = candidate_.positiveEntryCount;
        current.root = candidate_.root;
        current.datasetHash = candidate_.datasetHash;
        current.algorithmVersion = candidate_.algorithmVersion;
        current.commitmentVersion = 1;
        current.acceptedAt = acceptedAt;
        current.executableAfter = executableAfter;
        current.status = CandidateStatus.MATERIALIZING;
        _recordVersion(candidate_.distributionId, current, bytes32(0));
        emit CandidateSubmitted(
            candidate_.distributionId,
            candidate_.windowId,
            1,
            candidate_.root,
            candidate_.datasetHash,
            commitmentHashByVersion[candidate_.distributionId][1],
            acceptedAt,
            executableAfter,
            candidate_.recipientCount,
            candidate_.positiveEntryCount
        );
    }

    function correctCandidate(bytes32 distributionId, ReplacementInput calldata replacement)
        external
        override
        nonReentrant
        onlyRole(DISTRIBUTION_FINALIZER_ROLE)
    {
        Commitment storage current = _commitments[distributionId];
        uint32 oldVersion = current.commitmentVersion;
        if (
            current.status == CandidateStatus.NONE || current.status == CandidateStatus.EXECUTABLE_LOCKED
                || oldVersion == type(uint32).max || replacement.commitmentVersion != oldVersion + 1
                || replacement.root == bytes32(0) || replacement.datasetHash == bytes32(0)
                || replacement.algorithmVersion != ALGORITHM_VERSION_V1 || replacement.recipientCount == 0
                || replacement.recipientCount > MAX_RECIPIENTS || replacement.positiveEntryCount == 0
                || replacement.positiveEntryCount > replacement.recipientCount
                || replacement.correctionReasonHash == bytes32(0)
        ) revert CorrectionLocked();
        if (_vault.holderDistributionVersion(distributionId) != oldVersion) revert StaleVaultVersion();
        if (_canonicalDomain() != current.domainSeparator || _vault.holderDomainSeparator() != current.domainSeparator) {
            revert StaleVaultVersion();
        }
        _rejectAlreadyLockedEntries(distributionId, current);

        uint64 acceptedAt = _timestamp64();
        uint64 executableAfter = acceptedAt + REVIEW_SECONDS;
        bytes32 oldRoot = current.root;
        bytes32 oldCommitmentHash = commitmentHashByVersion[distributionId][oldVersion];

        // The Vault version and Distributor root change in this one transaction. A revert rolls both back.
        _vault.correctHolderDistribution(distributionId, replacement.commitmentVersion, replacement.positiveEntryCount);

        current.recipientCount = replacement.recipientCount;
        current.positiveEntryCount = replacement.positiveEntryCount;
        current.root = replacement.root;
        current.datasetHash = replacement.datasetHash;
        current.algorithmVersion = replacement.algorithmVersion;
        current.commitmentVersion = replacement.commitmentVersion;
        current.acceptedAt = acceptedAt;
        current.executableAfter = executableAfter;
        current.verifiedLeafCount = 0;
        current.materializedEntryCount = 0;
        current.materializedAmount = 0;
        current.status = CandidateStatus.MATERIALIZING;
        _recordVersion(distributionId, current, replacement.correctionReasonHash);
        emit CandidateCorrected(
            distributionId,
            oldVersion,
            replacement.commitmentVersion,
            oldRoot,
            replacement.root,
            oldCommitmentHash,
            commitmentHashByVersion[distributionId][replacement.commitmentVersion],
            replacement.correctionReasonHash,
            acceptedAt,
            executableAfter
        );
    }

    function materializeLeaf(bytes32 distributionId, Leaf calldata leaf, bytes32[] calldata proof)
        external
        override
        nonReentrant
        onlyRole(DISTRIBUTION_FINALIZER_ROLE)
    {
        Commitment storage current = _commitments[distributionId];
        if (current.status != CandidateStatus.MATERIALIZING) revert CandidateUnavailable();
        _requireVaultVersion(distributionId, current.commitmentVersion);
        _validateLeafContext(distributionId, current, leaf);
        if (!_verifyProof(current.root, current.recipientCount, leaf, proof)) revert InvalidProof();
        if (_leafMaterialized[distributionId][current.commitmentVersion][leaf.recipientIndex]) revert DuplicateLeaf();
        if (_recipientMaterialized[distributionId][current.commitmentVersion][leaf.recipient]) revert DuplicateRecipient();

        bytes32 leafHash_ = _hashLeaf(leaf);
        _leafMaterialized[distributionId][current.commitmentVersion][leaf.recipientIndex] = true;
        _recipientMaterialized[distributionId][current.commitmentVersion][leaf.recipient] = true;
        _leafHashes[distributionId][current.commitmentVersion][leaf.recipientIndex] = leafHash_;
        current.verifiedLeafCount += 1;

        bool vaultLiability = leaf.amount != 0;
        if (vaultLiability) {
            uint256 nextAmount = current.materializedAmount + leaf.amount;
            if (nextAmount > current.finalizedTotalPayable) revert IncompleteMaterialization();
            _positiveLeaf[distributionId][current.commitmentVersion][leaf.recipientIndex] = true;
            _vault.registerHolderRewardEntry(
                distributionId,
                current.commitmentVersion,
                current.windowId,
                leaf.recipientIndex,
                leaf.recipient,
                leaf.amount
            );
            current.materializedAmount = nextAmount;
            current.materializedEntryCount += 1;
        }

        emit LeafMaterialized(
            distributionId, current.commitmentVersion, leaf.recipientIndex, leafHash_, leaf.recipient, leaf.amount, vaultLiability
        );
        if (current.verifiedLeafCount == current.recipientCount) {
            if (
                current.materializedEntryCount != current.positiveEntryCount
                    || current.materializedAmount != current.finalizedTotalPayable
            ) revert IncompleteMaterialization();
            current.status = CandidateStatus.REVIEW;
        }
    }

    function finalizeCandidate(bytes32 distributionId)
        external
        override
        nonReentrant
        onlyRole(DISTRIBUTION_FINALIZER_ROLE)
    {
        Commitment storage current = _commitments[distributionId];
        if (
            current.status != CandidateStatus.REVIEW || current.verifiedLeafCount != current.recipientCount
                || current.materializedEntryCount != current.positiveEntryCount
                || current.materializedAmount != current.finalizedTotalPayable
        ) revert IncompleteMaterialization();
        _requireVaultVersion(distributionId, current.commitmentVersion);
        if (block.timestamp < current.executableAfter) revert ReviewActive();
        _vault.finalizeHolderDistribution(distributionId, current.commitmentVersion);
        current.status = CandidateStatus.EXECUTABLE;
        emit CandidateExecutable(distributionId, current.commitmentVersion, current.root, current.executableAfter);
    }

    function executeProof(bytes32 distributionId, Leaf calldata leaf, bytes32[] calldata proof)
        external
        override
        nonReentrant
        returns (bool paid)
    {
        if (msg.sender != automationExecutor) revert InvalidConfiguration();
        Commitment storage current = _commitments[distributionId];
        if (current.status != CandidateStatus.EXECUTABLE && current.status != CandidateStatus.EXECUTABLE_LOCKED) {
            revert CandidateUnavailable();
        }
        _requireVaultVersion(distributionId, current.commitmentVersion);
        _validateLeafContext(distributionId, current, leaf);
        if (!_verifyProof(current.root, current.recipientCount, leaf, proof)) revert InvalidProof();
        uint32 version = current.commitmentVersion;
        uint16 index = leaf.recipientIndex;
        if (
            leaf.amount == 0 || !_leafMaterialized[distributionId][version][index]
                || !_positiveLeaf[distributionId][version][index] || _leafHashes[distributionId][version][index] != _hashLeaf(leaf)
                || _leafExecuted[distributionId][version][index] || _leafFailed[distributionId][version][index]
                || block.timestamp < current.executableAfter
        ) revert LeafUnavailable();
        ICompdHolderRewardsVault.HolderEntry memory stored = _vault.holderRewardEntry(distributionId, index);
        if (
            stored.version != version || stored.status != ICompdHolderRewardsVault.HolderEntryStatus.COMMITTED_UNPAID
                || stored.recipient != leaf.recipient || stored.amount != leaf.amount
        ) revert LeafUnavailable();

        try _vault.payCommittedHolderEntry(
            distributionId, version, leaf.windowId, index, leaf.recipient, leaf.rewardAsset, leaf.amount
        ) {
            _leafExecuted[distributionId][version][index] = true;
            current.status = CandidateStatus.EXECUTABLE_LOCKED;
            emit AutomaticPayoutSucceeded(distributionId, version, index, leaf.recipient, leaf.amount);
            return true;
        } catch (bytes memory reason) {
            // A failed exact Vault subcall is caught and recorded. The entry remains fully backed and is never retried here.
            _vault.markHolderEntryFailed(distributionId, version, leaf.windowId, index, leaf.recipient, leaf.rewardAsset, leaf.amount);
            _leafFailed[distributionId][version][index] = true;
            current.status = CandidateStatus.EXECUTABLE_LOCKED;
            emit AutomaticPayoutFailed(distributionId, version, index, leaf.recipient, leaf.amount, keccak256(reason));
            return false;
        }
    }

    function candidate(bytes32 distributionId) external view override returns (CommitmentView memory result) {
        Commitment storage current = _commitments[distributionId];
        result = CommitmentView({
            domainSeparator: current.domainSeparator,
            windowId: current.windowId,
            windowStart: current.windowStart,
            windowEnd: current.windowEnd,
            rewardAsset: current.rewardAsset,
            windowPool: current.windowPool,
            finalizedTotalPayable: current.finalizedTotalPayable,
            recipientCount: current.recipientCount,
            positiveEntryCount: current.positiveEntryCount,
            root: current.root,
            datasetHash: current.datasetHash,
            algorithmVersion: current.algorithmVersion,
            commitmentVersion: current.commitmentVersion,
            acceptedAt: current.acceptedAt,
            executableAfter: current.executableAfter,
            verifiedLeafCount: current.verifiedLeafCount,
            materializedEntryCount: current.materializedEntryCount,
            materializedAmount: current.materializedAmount,
            status: current.status
        });
    }

    function materializedLeafHash(bytes32 distributionId, uint32 version, uint16 index)
        external
        view
        override
        returns (bytes32)
    {
        return _leafHashes[distributionId][version][index];
    }

    function hashLeaf(Leaf calldata leaf) external pure override returns (bytes32) {
        return _hashLeaf(leaf);
    }

    function hashPadding(bytes32 domainSeparator, bytes32 distributionId, uint32 version, uint16 index)
        external
        pure
        override
        returns (bytes32)
    {
        return keccak256(abi.encode(PADDING_TYPEHASH, domainSeparator, distributionId, version, index));
    }

    function hashNode(bytes32 left, bytes32 right) external pure override returns (bytes32) {
        return keccak256(abi.encode(NODE_TYPEHASH, left, right));
    }

    function _validateCandidate(CandidateInput calldata candidate_, uint32 version, bool initial) private view {
        if (
            candidate_.commitmentVersion != version || candidate_.algorithmVersion != ALGORITHM_VERSION_V1
                || candidate_.root == bytes32(0) || candidate_.datasetHash == bytes32(0)
                || candidate_.recipientCount == 0 || candidate_.recipientCount > MAX_RECIPIENTS
                || candidate_.positiveEntryCount == 0 || candidate_.positiveEntryCount > candidate_.recipientCount
                || candidate_.windowPool == 0 || candidate_.finalizedTotalPayable != candidate_.windowPool
                || candidate_.rewardAsset != _vaultView.quoteToken() || candidate_.windowEnd > block.timestamp
                || candidate_.windowEnd <= candidate_.windowStart
        ) revert InvalidCandidate();
        bytes32 domain = _canonicalDomain();
        if (candidate_.domainSeparator != domain || _vault.holderDomainSeparator() != domain) revert InvalidCandidate();
        bytes32 canonicalWindowId = _canonicalWindowId(candidate_.windowStart, candidate_.windowEnd, domain);
        if (candidate_.windowId != canonicalWindowId || _vault.holderWindowId(candidate_.windowStart, candidate_.windowEnd) != canonicalWindowId) {
            revert InvalidCandidate();
        }
        bytes32 canonicalDistributionId = keccak256(abi.encode(DISTRIBUTION_TYPEHASH, domain, canonicalWindowId));
        if (candidate_.distributionId != canonicalDistributionId) revert InvalidCandidate();
        if (initial && _vault.holderRewardPool(canonicalWindowId) != candidate_.windowPool) revert InvalidCandidate();
    }

    function _canonicalDomain() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                PROTOCOL_ID,
                block.chainid,
                _vaultView.COMPD_TOKEN(),
                address(_vaultView),
                address(this),
                _vaultView.quoteToken()
            )
        );
    }

    function _canonicalWindowId(uint64 start, uint64 end, bytes32 domain) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                WINDOW_TYPEHASH,
                domain,
                ICompdPhase3ActivationView(address(_vault)).holderRewardsActivationBlock(),
                ICompdPhase3ActivationView(address(_vault)).holderRewardsActivationBlockHash(),
                ICompdPhase3ActivationView(address(_vault)).holderRewardsActivationTimestamp(),
                start,
                end
            )
        );
    }

    function _validateLeafContext(bytes32 distributionId, Commitment storage current, Leaf calldata leaf) private view {
        if (
            leaf.domainSeparator != current.domainSeparator || leaf.distributionId != distributionId
                || leaf.commitmentVersion != current.commitmentVersion || leaf.windowId != current.windowId
                || leaf.windowStart != current.windowStart || leaf.windowEnd != current.windowEnd
                || leaf.rewardAsset != current.rewardAsset || leaf.windowPool != current.windowPool
                || leaf.finalizedTotalPayable != current.finalizedTotalPayable || leaf.recipientIndex >= current.recipientCount
                || leaf.recipient == address(0) || leaf.datasetHash != current.datasetHash
                || leaf.algorithmVersion != current.algorithmVersion || _canonicalDomain() != current.domainSeparator
                || _vault.holderDomainSeparator() != current.domainSeparator
                || _vault.holderWindowId(current.windowStart, current.windowEnd) != current.windowId
        ) revert InvalidCandidate();
    }

    function _verifyProof(bytes32 root, uint16 recipientCount, Leaf calldata leaf, bytes32[] calldata proof)
        private
        pure
        returns (bool)
    {
        uint256 width = 1;
        while (width < recipientCount) width <<= 1;
        uint256 depth;
        for (uint256 size = width; size > 1; size >>= 1) ++depth;
        if (proof.length != depth) return false;
        bytes32 computed = _hashLeaf(leaf);
        uint256 index = leaf.recipientIndex;
        for (uint256 level; level < proof.length; ++level) {
            bytes32 sibling = proof[level];
            computed = ((index >> level) & 1) == 0
                ? keccak256(abi.encode(NODE_TYPEHASH, computed, sibling))
                : keccak256(abi.encode(NODE_TYPEHASH, sibling, computed));
        }
        return computed == root;
    }

    function _hashLeaf(Leaf calldata leaf) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                LEAF_TYPEHASH,
                leaf.domainSeparator,
                leaf.distributionId,
                leaf.commitmentVersion,
                leaf.windowId,
                leaf.windowStart,
                leaf.windowEnd,
                leaf.rewardAsset,
                leaf.windowPool,
                leaf.finalizedTotalPayable,
                leaf.recipientIndex,
                leaf.recipient,
                leaf.amount,
                leaf.datasetHash,
                leaf.algorithmVersion
            )
        );
    }

    function _recordVersion(bytes32 distributionId, Commitment storage current, bytes32 reasonHash) private {
        uint32 version = current.commitmentVersion;
        rootByVersion[distributionId][version] = current.root;
        datasetHashByVersion[distributionId][version] = current.datasetHash;
        correctionReasonHashByVersion[distributionId][version] = reasonHash;
        commitmentHashByVersion[distributionId][version] = keccak256(
            abi.encode(
                COMMITMENT_TYPEHASH,
                current.domainSeparator,
                distributionId,
                current.windowId,
                current.windowStart,
                current.windowEnd,
                current.rewardAsset,
                current.windowPool,
                current.finalizedTotalPayable,
                current.recipientCount,
                current.root,
                current.datasetHash,
                current.algorithmVersion,
                current.commitmentVersion,
                current.acceptedAt,
                current.executableAfter
            )
        );
    }

    function _requireVaultVersion(bytes32 distributionId, uint32 version) private view {
        if (_vault.holderDistributionVersion(distributionId) != version) revert StaleVaultVersion();
    }

    function _rejectAlreadyLockedEntries(bytes32 distributionId, Commitment storage current) private view {
        for (uint16 index; index < current.recipientCount; ++index) {
            if (!_positiveLeaf[distributionId][current.commitmentVersion][index]) continue;
            ICompdHolderRewardsVault.HolderEntry memory entry = _vault.holderRewardEntry(distributionId, index);
            if (
                entry.version != current.commitmentVersion
                    || entry.status == ICompdHolderRewardsVault.HolderEntryStatus.PAID
                    || entry.status == ICompdHolderRewardsVault.HolderEntryStatus.FAILED_PENDING_MANUAL
                    || entry.status == ICompdHolderRewardsVault.HolderEntryStatus.TERMINAL_PENDING
                    || entry.status == ICompdHolderRewardsVault.HolderEntryStatus.TERMINAL_EXPIRED
            ) revert CorrectionLocked();
        }
    }

    function _timestamp64() private view returns (uint64 timestamp) {
        if (block.timestamp > type(uint64).max - REVIEW_SECONDS) revert InvalidCandidate();
        timestamp = uint64(block.timestamp);
    }
}
