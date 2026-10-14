// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {C2G2BTypes as T} from "../../v2/phase7ar2/C2G2BTypesR2.sol";

interface IHolderKernelStateV3 {
    function lifecycle() external view returns (T.Lifecycle);
    function holderRewardReserve() external view returns (uint256);
    function eligibleWindowHR() external view returns(uint256);
    function holderPaid(bytes32 useId) external view returns (bool);
    function failedHolder(bytes32 useId) external view returns (bytes32,address,uint256,bytes32);
    function eligibilityToken() external view returns(address);
    function activationBlock() external view returns(uint64);
    function activationTimestamp() external view returns(uint64);
    function activationBlockHash() external view returns(bytes32);
    function activationContextHash() external view returns(bytes32);
    function firstEligibleWindowStart() external view returns(uint64);
    function activationSealed() external view returns(bool);
    function activationSealFailed() external view returns(bool);
    function activationExclusionSetHash() external view returns(bytes32);
    function exclusionSetVersion() external view returns(uint32);
    function deriveWindow(uint64) external view returns(bytes32,bytes32,uint64,uint256,bool);
}

/// @notice Single immutable-code source of Holder distribution, payment and terminal truth.
/// @dev DistributionFinalizer trust is inherited from Phase 6B; this contract adds no signer.
contract CompdCanonicalHolderStateV3 {
    bytes32 public constant PROTOCOL_ID = keccak256(bytes("COMPD_HOLDER_REWARDS_V3"));
    bytes32 public constant DOMAIN_TYPEHASH = keccak256(bytes("CompdHolderRewardsDomain(bytes32 protocolId,uint256 chainId,address compdToken,address vault,address distributor,address rewardAsset)"));
    bytes32 public constant DATASET_TYPEHASH = keccak256(bytes("CompdHolderRewardDataset(bytes32 domainSeparator,bytes32 distributionId,bytes32 windowId,uint64 windowStart,uint64 windowEnd,uint256 windowPool,uint256 finalizedTotalPayable,uint16 recipientCount,uint32 algorithmVersion,uint32 exclusionSetVersion,bytes32 exclusionSetHash,uint256 activationBlock,bytes32 activationBlockHash,uint64 activationTimestamp,uint256 sourceStartBlock,uint256 finalityBlock,bytes32 finalityBlockHash,bytes32 entriesHash)"));
    bytes32 public constant ENTRIES_TYPEHASH = keccak256(bytes("CompdHolderRewardEntries(uint16[] recipientIndices,address[] recipients,uint256[] weights,uint256[] floorQuotients,uint256[] remainderNumerators,uint256[] finalPayouts)"));
    bytes32 public constant EVIDENCE_TYPEHASH = keccak256(bytes("CompdHolderRewardEvidenceV3(bytes32 domainSeparator,bytes32 distributionId,bytes32 windowId,uint32 version,bytes32 datasetHash,bytes32 manifestHash,bytes32 entriesHash,bytes32 activationContextHash,uint256 snapshotBlock,bytes32 snapshotBlockHash,uint256 sourceStartBlock,uint256 closeBlock,bytes32 closeBlockHash,uint256 finalityBlock,bytes32 finalityBlockHash,uint32 exclusionSetVersion,bytes32 exclusionSetHash,uint32 algorithmVersion,bytes32 replayCodeHash,bytes32 root,uint16 recipientCount,uint256 exactPool,bytes32 previousCommitment,bytes32 correctionReasonHash)"));
    bytes32 public constant LEAF_TYPEHASH = keccak256(bytes("CompdHolderRewardLeaf(bytes32 domainSeparator,bytes32 distributionId,uint32 commitmentVersion,bytes32 windowId,uint64 windowStart,uint64 windowEnd,address rewardAsset,uint256 windowPool,uint256 finalizedTotalPayable,uint16 recipientIndex,address recipient,uint256 amount,bytes32 datasetHash,uint32 algorithmVersion)"));
    bytes32 public constant PADDING_TYPEHASH = keccak256(bytes("CompdHolderRewardPadding(bytes32 domainSeparator,bytes32 distributionId,uint32 commitmentVersion,uint16 paddedIndex)"));
    bytes32 public constant NODE_TYPEHASH = keccak256(bytes("CompdHolderRewardNode(bytes32 left,bytes32 right)"));
    uint64 public constant REVIEW_SECONDS = 1_800;
    uint64 public constant TERMINAL_GRACE = 7_776_000;
    uint16 public constant MAX_RECIPIENTS = 30;
    uint8 private constant NORMAL = 1;
    uint8 private constant TERMINAL = 2;

    struct Candidate {
        bytes32 distributionId;
        bytes32 windowId;
        uint64 windowStart;
        uint64 windowEnd;
        address rewardAsset;
        uint256 windowPool;
        uint256 payableTotal;
        uint16 recipientCount;
        bytes32 root;
        bytes32 datasetHash;
        uint32 algorithmVersion;
        uint32 version;
        uint64 acceptedAt;
        uint64 executableAfter;
        bool empty;
        bool finalized;
        bool superseded;
        uint16 materializedCount;
        uint256 materializedTotal;
    }

    struct Leaf {
        bytes32 domainSeparator;
        bytes32 distributionId;
        uint32 commitmentVersion;
        bytes32 windowId;
        uint64 windowStart;
        uint64 windowEnd;
        address rewardAsset;
        uint256 windowPool;
        uint256 finalizedTotalPayable;
        uint16 recipientIndex;
        address recipient;
        uint256 amount;
        bytes32 datasetHash;
        uint32 algorithmVersion;
    }

    struct CandidateEvidence {
        bytes32 manifestHash;
        bytes32 entriesHash;
        uint256 snapshotBlock;
        bytes32 snapshotBlockHash;
        uint256 sourceStartBlock;
        uint256 closeBlock;
        bytes32 closeBlockHash;
        uint256 finalityBlock;
        bytes32 finalityBlockHash;
        uint32 exclusionSetVersion;
        bytes32 exclusionSetHash;
        bytes32 replayCodeHash;
    }

    struct PaymentRecord {
        T.HolderPayment payment;
        uint64 terminalStartedAt;
        uint64 terminalExpiresAt;
        uint8 acknowledgementMask;
        bool materialized;
        bool terminalized;
        bool consumed;
        bool recovered;
    }
    struct EmptyRecord { uint256 amount; uint64 acceptedAt; uint64 finalizedAt; uint32 version; bytes32 commitment; bool finalized; bool consumed; }

    address public immutable kernel;
    address public immutable distributor;
    address public immutable liability;
    address public immutable recoveryEvidence;
    address public immutable finalizer;
    bytes32 public immutable domainSeparator;

    mapping(bytes32 => Candidate) private _candidates;
    mapping(bytes32=>mapping(uint32=>CandidateEvidence)) private _candidateEvidence;
    mapping(bytes32 => mapping(uint32=>bytes32)) public candidateEvidenceCommitment;
    mapping(bytes32 => uint32) public currentVersion;
    mapping(bytes32 => bool) private _windowUsed;
    mapping(bytes32 => mapping(uint32 => mapping(uint16 => bytes32))) private _leafAt;
    mapping(bytes32 => PaymentRecord) private _payments;
    mapping(bytes32 => bool) private _emptyFinalized;
    mapping(bytes32 => bool) private _emptyConsumed;
    mapping(bytes32 => EmptyRecord) private _emptyRecords;
    mapping(bytes32 => bytes32) private _windowByEmptyRecoveryId;
    mapping(bytes32 => bool) private _recoveryConsumed;
    mapping(bytes32 => bytes32) private _leafByExpiredRecoveryId;
    uint256 public unresolvedOrdinary;
    uint256 public terminalOutstanding;
    uint256 public outstandingHolderLiability;
    uint256 public pendingCandidateReserve;
    uint256 public openReviewCount;
    bytes32 public reconciliationDigest;

    error Unauthorized();
    error InvalidCandidate();
    error InvalidProof();
    error InvalidPayment();
    error InvalidTransition();
    error Replay();

    event CandidateSubmitted(bytes32 indexed distributionId, bytes32 indexed windowId, uint32 version, uint64 executableAfter);
    event CandidateCorrected(bytes32 indexed distributionId, uint32 oldVersion, uint32 newVersion, bytes32 reasonHash);
    event LeafMaterialized(bytes32 indexed leafId, bytes32 indexed useId, address recipient, uint256 amount);
    event CandidateFinalized(bytes32 indexed distributionId, uint32 version, uint256 amount, uint16 recipients);
    event EmptyCandidateFinalized(bytes32 indexed windowId, uint32 version, uint256 amount);
    event Terminalized(bytes32 indexed leafId, bytes32 indexed useId, uint64 startedAt, uint64 expiresAt);
    event PaymentAcknowledged(bytes32 indexed leafId, uint8 mask, bool consumed);
    event RecoveryConsumed(bytes32 indexed id, uint8 indexed kind, uint256 amount);

    modifier onlyDistributor() { if (msg.sender != distributor) revert Unauthorized(); _; }
    modifier onlyEvidence() { if (msg.sender != recoveryEvidence) revert Unauthorized(); _; }

    constructor(address kernel_, address distributor_, address liability_, address evidence_, address finalizer_) {
        if (kernel_ == address(0) || distributor_ == address(0) || liability_ == address(0) || evidence_ == address(0) || finalizer_ == address(0)) revert Unauthorized();
        kernel = kernel_; distributor = distributor_; liability = liability_; recoveryEvidence = evidence_; finalizer = finalizer_;
        domainSeparator = keccak256(abi.encode(DOMAIN_TYPEHASH,PROTOCOL_ID,block.chainid,IHolderKernelStateV3(kernel_).eligibilityToken(),kernel_,distributor_,address(0)));
        reconciliationDigest = keccak256(abi.encode(PROTOCOL_ID, block.chainid, kernel_, address(this)));
    }

    function submitCandidate(Candidate calldata c) external onlyDistributor { c; revert InvalidCandidate(); }

    function submitCandidate(Candidate calldata c,CandidateEvidence calldata evidence) external onlyDistributor {
        if(c.empty||c.version!=1||currentVersion[c.windowId]!=0||_windowUsed[c.windowId])revert InvalidCandidate();
        bytes32 commitment=_validateCandidate(c,evidence,bytes32(0),bytes32(0));
        _requireReserve(c.windowPool);bytes32 key=_candidateKey(c.distributionId,c.version);Candidate storage s=_candidates[key];if(s.distributionId!=bytes32(0))revert Replay();
        _storeCandidate(s,c);s.acceptedAt=uint64(block.timestamp);s.executableAfter=uint64(block.timestamp)+REVIEW_SECONDS;
        currentVersion[c.windowId]=c.version;_windowUsed[c.windowId]=true;++openReviewCount;pendingCandidateReserve+=c.windowPool;candidateEvidenceCommitment[c.distributionId][c.version]=commitment;
        _candidateEvidence[c.distributionId][c.version]=evidence;reconciliationDigest=keccak256(abi.encode(reconciliationDigest,c.distributionId,c.windowId,c.version,commitment,s.executableAfter));emit CandidateSubmitted(c.distributionId,c.windowId,c.version,s.executableAfter);
    }

    function correctCandidate(Candidate calldata next,CandidateEvidence calldata evidence,bytes32 reasonHash) external onlyDistributor {
        if(reasonHash==bytes32(0)||next.version<2||next.version!=currentVersion[next.windowId]+1||_candidate(next.distributionId,next.version-1).finalized)revert InvalidCandidate();
        Candidate storage previous=_candidate(next.distributionId,next.version-1);if(currentVersion[previous.windowId]!=previous.version||previous.finalized||block.timestamp>=previous.executableAfter||previous.windowId!=next.windowId)revert InvalidCandidate();
        bytes32 prior=candidateEvidenceCommitment[next.distributionId][next.version-1];bytes32 commitment=_validateCandidate(next,evidence,prior,reasonHash);
        if(next.windowPool!=previous.windowPool||next.windowStart!=previous.windowStart||next.windowEnd!=previous.windowEnd)revert InvalidCandidate();
        bytes32 key=_candidateKey(next.distributionId,next.version);Candidate storage s=_candidates[key];if(s.distributionId!=bytes32(0))revert Replay();
        _storeCandidate(s,next);s.acceptedAt=uint64(block.timestamp);s.executableAfter=uint64(block.timestamp)+REVIEW_SECONDS;currentVersion[next.windowId]=next.version;candidateEvidenceCommitment[next.distributionId][next.version]=commitment;
        _candidateEvidence[next.distributionId][next.version]=evidence;reconciliationDigest=keccak256(abi.encode(reconciliationDigest,next.distributionId,next.version,reasonHash,commitment,s.executableAfter));emit CandidateCorrected(next.distributionId,next.version-1,next.version,reasonHash);
    }

    function _validateCandidate(Candidate calldata c,CandidateEvidence calldata e,bytes32 previous,bytes32 reason) private view returns(bytes32 commitment){
        IHolderKernelStateV3 k=IHolderKernelStateV3(kernel);(bytes32 wid,bytes32 did,uint64 end,uint256 pool,bool eligible)=IHolderKernelStateV3(kernel).deriveWindow(c.windowStart);
        if(!k.activationSealed()||k.activationSealFailed()||k.lifecycle()!=T.Lifecycle.ACTIVE||!eligible||wid!=c.windowId||did!=c.distributionId||end!=c.windowEnd||pool!=c.windowPool||c.windowEnd>=block.timestamp||c.rewardAsset!=address(0)||c.algorithmVersion!=1||c.datasetHash==0||c.root==0||c.recipientCount==0||c.recipientCount>MAX_RECIPIENTS||c.payableTotal!=pool||c.windowStart%28_800!=0||c.windowStart<k.firstEligibleWindowStart())revert InvalidCandidate();
        if(e.manifestHash==0||e.entriesHash==0||e.snapshotBlockHash==0||e.closeBlockHash==0||e.finalityBlockHash==0||e.replayCodeHash==0||e.exclusionSetHash!=k.activationExclusionSetHash()||e.exclusionSetVersion!=k.exclusionSetVersion()||e.sourceStartBlock!=k.activationBlock()||e.snapshotBlock<k.activationBlock()||e.closeBlock<=e.snapshotBlock||e.finalityBlock<e.closeBlock)revert InvalidCandidate();
        bytes32 computedDataset=keccak256(abi.encode(DATASET_TYPEHASH,domainSeparator,c.distributionId,c.windowId,c.windowStart,c.windowEnd,c.windowPool,c.payableTotal,c.recipientCount,c.algorithmVersion,e.exclusionSetVersion,e.exclusionSetHash,uint256(k.activationBlock()),k.activationBlockHash(),k.activationTimestamp(),e.sourceStartBlock,e.finalityBlock,e.finalityBlockHash,e.entriesHash));if(computedDataset!=c.datasetHash)revert InvalidCandidate();
        commitment=keccak256(abi.encode(EVIDENCE_TYPEHASH,domainSeparator,c.distributionId,c.windowId,c.version,c.datasetHash,e.manifestHash,e.entriesHash,k.activationContextHash(),e.snapshotBlock,e.snapshotBlockHash,e.sourceStartBlock,e.closeBlock,e.closeBlockHash,e.finalityBlock,e.finalityBlockHash,e.exclusionSetVersion,e.exclusionSetHash,c.algorithmVersion,e.replayCodeHash,c.root,c.recipientCount,c.windowPool,previous,reason));
    }

    function _storeCandidate(Candidate storage s,Candidate calldata c) private {s.distributionId=c.distributionId;s.windowId=c.windowId;s.windowStart=c.windowStart;s.windowEnd=c.windowEnd;s.rewardAsset=c.rewardAsset;s.windowPool=c.windowPool;s.payableTotal=c.payableTotal;s.recipientCount=c.recipientCount;s.root=c.root;s.datasetHash=c.datasetHash;s.algorithmVersion=c.algorithmVersion;s.version=c.version;s.empty=c.empty;}
    function _candidateKey(bytes32 distributionId,uint32 version) private pure returns(bytes32){return keccak256(abi.encode(distributionId,version));}

    function correctCandidate(bytes32 distributionId, uint32 version, bytes32 reasonHash, bytes32 root, bytes32 datasetHash) external onlyDistributor {
        distributionId;version;reasonHash;root;datasetHash;revert InvalidCandidate();
    }

    function materializeLeaf(bytes32 distributionId, uint32 version, Leaf calldata leaf, bytes32[] calldata proof) external onlyDistributor returns (bytes32 leafId) {
        Candidate storage c = _candidate(distributionId, version);
        if (c.finalized || c.superseded || currentVersion[c.windowId]!=c.version || block.timestamp >= c.executableAfter || leaf.domainSeparator != domainSeparator
            || leaf.distributionId != distributionId || leaf.commitmentVersion != version || leaf.windowId != c.windowId
            || leaf.windowStart != c.windowStart || leaf.windowEnd != c.windowEnd || leaf.rewardAsset != address(0)
            || leaf.windowPool != c.windowPool || leaf.finalizedTotalPayable != c.payableTotal || leaf.datasetHash != c.datasetHash
            || leaf.algorithmVersion != c.algorithmVersion || leaf.recipientIndex >= c.recipientCount || leaf.recipient == address(0) || leaf.amount == 0) revert InvalidCandidate();
        leafId = _hashLeaf(leaf);
        if (_leafAt[distributionId][version][leaf.recipientIndex] != bytes32(0) || !_verify(leafId, leaf.recipientIndex, c.recipientCount, proof, c.root, distributionId, version)) revert InvalidProof();
        bytes32 useId = keccak256(abi.encode(keccak256("COMPD_HOLDER_PAYMENT_USE_V3"), block.chainid, kernel, distributor, distributionId, version, leaf.recipientIndex, leafId));
        T.HolderPayment memory p = T.HolderPayment(c.windowId, distributionId, version, leaf.recipientIndex, c.root,
            keccak256(abi.encode(c.datasetHash,c.algorithmVersion)), leafId, leaf.recipient, address(0), leaf.amount, 1, 1, 0, 0, 0, useId);
        PaymentRecord storage r = _payments[leafId]; if (r.materialized) revert Replay(); r.payment = p; r.materialized = true;
        _leafAt[distributionId][version][leaf.recipientIndex] = leafId; ++c.materializedCount; c.materializedTotal += leaf.amount;
        emit LeafMaterialized(leafId, useId, leaf.recipient, leaf.amount);
    }

    function finalizeCandidate(bytes32 distributionId, uint32 version) external onlyDistributor {
        Candidate storage c = _candidate(distributionId, version);
        if (c.finalized || c.superseded || currentVersion[c.windowId]!=c.version || block.timestamp < c.executableAfter || c.materializedCount != c.recipientCount || c.materializedTotal != c.payableTotal) revert InvalidCandidate();
        c.finalized = true; --openReviewCount; unresolvedOrdinary += c.recipientCount; outstandingHolderLiability += c.payableTotal;
        pendingCandidateReserve -= c.windowPool;
        for (uint16 i; i < c.recipientCount; ++i) { bytes32 id = _leafAt[distributionId][version][i]; if (id == bytes32(0)) revert InvalidCandidate(); _payments[id].payment.finalizedAt = uint64(block.timestamp); }
        reconciliationDigest = keccak256(abi.encode(reconciliationDigest, distributionId, version, c.root, c.payableTotal, c.recipientCount, block.timestamp));
        emit CandidateFinalized(distributionId, version, c.payableTotal, c.recipientCount);
    }

    function terminalize(bytes32 leafId) external {
        PaymentRecord storage r = _payments[leafId]; T.HolderPayment storage p = r.payment;
        if (!r.materialized || !(_candidate(p.distributionId,p.version).finalized) || r.terminalized || r.consumed || r.recovered
            || IHolderKernelStateV3(kernel).lifecycle() != T.Lifecycle.SHUTDOWN_PENDING || IHolderKernelStateV3(kernel).holderPaid(p.useId)) revert InvalidTransition();
        (bytes32 digest,address recipient,uint256 amount,bytes32 failedLeaf) = IHolderKernelStateV3(kernel).failedHolder(p.useId);
        if (digest != _digest(p) || recipient != p.recipient || amount != p.amount || failedLeaf != leafId) revert InvalidPayment();
        if (_consumed(p.leafId) || (p.expiresAt != 0 && block.timestamp > p.expiresAt)) revert InvalidPayment();
        r.terminalized = true; r.terminalStartedAt = uint64(block.timestamp); r.terminalExpiresAt = uint64(block.timestamp) + TERMINAL_GRACE;
        --unresolvedOrdinary; ++terminalOutstanding;
        reconciliationDigest = keccak256(abi.encode(reconciliationDigest, leafId, p.useId, r.terminalStartedAt, r.terminalExpiresAt));
        _leafByExpiredRecoveryId[expiredHolderRecoveryId(leafId)] = leafId;
        emit Terminalized(leafId,p.useId,r.terminalStartedAt,r.terminalExpiresAt);
    }

    function paymentData(bytes32 leafId) external view returns (T.HolderPayment memory payment, bool proofValid) {
        PaymentRecord storage r = _payments[leafId]; payment = r.payment;
        if(!r.materialized)return(payment,false);
        Candidate storage c = _candidate(payment.distributionId,payment.version);
        proofValid = c.finalized && currentVersion[payment.windowId] == payment.version && !_consumed(leafId);
    }
    function paymentDigest(bytes32 leafId) external view returns (bytes32) { PaymentRecord storage r = _payments[leafId]; if (!r.materialized) return bytes32(0); return _digest(r.payment); }
    function paymentWindowStart(bytes32 leafId) external view returns(uint64){PaymentRecord storage r=_payments[leafId];if(!r.materialized)return 0;return _candidate(r.payment.distributionId,r.payment.version).windowStart;}
    function canonicalPayment(bytes32 leafId) external view returns (bytes32 digest,address recipient,address asset,uint256 amount,uint8 status,bool payableNow) {
        PaymentRecord storage r = _payments[leafId]; T.HolderPayment storage p = r.payment; if (!r.materialized) return (0,address(0),address(0),0,0,false);
        digest = _digest(p); recipient = p.recipient; asset = p.asset; amount = p.amount; status = r.terminalized ? TERMINAL : NORMAL;
        bool lifecycleOk = r.terminalized
            ? (IHolderKernelStateV3(kernel).lifecycle() == T.Lifecycle.SHUTDOWN_PENDING || IHolderKernelStateV3(kernel).lifecycle() == T.Lifecycle.TERMINATED)
                && block.timestamp < r.terminalExpiresAt
            : IHolderKernelStateV3(kernel).lifecycle() == T.Lifecycle.ACTIVE;
        payableNow = _candidate(p.distributionId,p.version).finalized && !_consumed(leafId) && !r.recovered && lifecycleOk
            && (p.expiresAt == 0 || block.timestamp <= p.expiresAt);
    }
    function terminalStatus(bytes32 leafId) external view returns(bool terminal,uint64 startedAt,uint64 expiresAt,bytes32 useId) {
        PaymentRecord storage r = _payments[leafId]; return (r.terminalized,r.terminalStartedAt,r.terminalExpiresAt,r.payment.useId);
    }
    function terminalReconciliation() external view returns(bytes32 digest,uint256 unresolved) {
        return (reconciliationDigest, unresolvedOrdinary + openReviewCount);
    }
    function recoveryReconciliationComplete() external view returns (bool) {
        T.Lifecycle current=IHolderKernelStateV3(kernel).lifecycle();
        if ((current != T.Lifecycle.SHUTDOWN_PENDING && current != T.Lifecycle.TERMINATED) || openReviewCount != 0 || unresolvedOrdinary != 0
            || outstandingHolderLiability != IHolderKernelStateV3(kernel).eligibleWindowHR()) return false;
        return true;
    }

    function submitEmptyCandidate(bytes32 windowId,uint32 version,uint256 exactPool,bytes32 evidenceHash) external onlyDistributor {
        windowId;version;exactPool;evidenceHash;revert InvalidCandidate();
    }

    function finalizeEmptyCandidate(bytes32 windowId) external onlyDistributor {
        EmptyRecord storage e=_emptyRecords[windowId];
        if(e.version==0||e.finalized||block.timestamp<uint256(e.acceptedAt)+REVIEW_SECONDS||IHolderKernelStateV3(kernel).lifecycle()!=T.Lifecycle.ACTIVE) revert InvalidCandidate();
        e.finalized=true;e.finalizedAt=uint64(block.timestamp);pendingCandidateReserve-=e.amount;outstandingHolderLiability+=e.amount;--openReviewCount;
        _windowByEmptyRecoveryId[emptyRecoveryId(windowId)]=windowId;
        reconciliationDigest=keccak256(abi.encode(reconciliationDigest,windowId,e.version,e.amount,e.commitment,e.finalizedAt));
        emit EmptyCandidateFinalized(windowId,e.version,e.amount);
    }

    function emptyRecoveryId(bytes32 windowId) public view returns(bytes32) {
        EmptyRecord storage e=_emptyRecords[windowId];if(!e.finalized)return bytes32(0);
        return keccak256(abi.encode(keccak256("COMPD_RECOVERY_ID_V3"),block.chainid,kernel,uint8(1),address(this),keccak256("NO_RECIPIENT"),windowId,e.version,e.commitment,e.amount));
    }
    function expiredHolderRecoveryId(bytes32 leafId) public view returns(bytes32){PaymentRecord storage r=_payments[leafId];if(!r.terminalized)return bytes32(0);return keccak256(abi.encode(keccak256("COMPD_RECOVERY_ID_V3"),block.chainid,kernel,uint8(2),address(this),keccak256("EXPIRED_HOLDER"),leafId,r.payment.useId,_digest(r.payment)));}
    function bucketRecoveryId(uint8 kind) external view returns(bytes32){if(kind!=0&&kind!=3)return bytes32(0);uint256 amount;if(kind==0){(bool ok,bytes memory out)=kernel.staticcall(abi.encodeWithSignature("protocolReserve()"));if(!ok)return bytes32(0);amount=abi.decode(out,(uint256));}else{(bool ok,bytes memory out)=kernel.staticcall(abi.encodeWithSignature("nonStrategyTreasuryPrincipal()"));if(!ok)return bytes32(0);amount=abi.decode(out,(uint256));}(bool ok2,bytes memory out2)=kernel.staticcall(abi.encodeWithSignature("shutdownAt()"));if(!ok2)return bytes32(0);uint64 shutdownAt=abi.decode(out2,(uint64));return keccak256(abi.encode(keccak256("COMPD_RECOVERY_ID_V3"),block.chainid,kernel,kind,address(this),shutdownAt,kind==0?keccak256("PROTOCOL_RESERVE"):keccak256("TREASURY_PRINCIPAL"),amount));}

    function noRecipientRecovery(bytes32 id) external view returns(bool eligible,uint256 amount) {
        bytes32 windowId=_windowByEmptyRecoveryId[id];EmptyRecord storage e=_emptyRecords[windowId];
        eligible=false;amount=0;
        if(windowId!=bytes32(0)&&e.finalized&&id==emptyRecoveryId(windowId)&&!e.consumed&&IHolderKernelStateV3(kernel).lifecycle()==T.Lifecycle.TERMINATED&&openReviewCount==0&&unresolvedOrdinary==0){eligible=true;amount=e.amount;}
    }
    function expiredHolderRecovery(bytes32 id) external view returns(bool eligible,uint256 amount) {
        bytes32 leafId=_leafByExpiredRecoveryId[id];PaymentRecord storage r = _payments[leafId]; T.HolderPayment storage p=r.payment;
        eligible = leafId!=bytes32(0) && id==expiredHolderRecoveryId(leafId) && r.materialized && r.terminalized && !r.consumed && !r.recovered && !IHolderKernelStateV3(kernel).holderPaid(p.useId)
            && IHolderKernelStateV3(kernel).lifecycle()==T.Lifecycle.TERMINATED && block.timestamp>=r.terminalExpiresAt;
        amount = eligible ? p.amount : 0;
    }
    function consumeNoRecipient(bytes32 id) external onlyEvidence { bytes32 windowId=_windowByEmptyRecoveryId[id];EmptyRecord storage e=_emptyRecords[windowId];if(windowId==0||!e.finalized||id!=emptyRecoveryId(windowId)||e.consumed)revert Replay();e.consumed=true;outstandingHolderLiability-=e.amount;emit RecoveryConsumed(id,1,e.amount); }
    function consumeExpiredHolder(bytes32 id) external onlyEvidence { bytes32 leafId=_leafByExpiredRecoveryId[id];PaymentRecord storage r=_payments[leafId];if(leafId==0||id!=expiredHolderRecoveryId(leafId)||!r.terminalized||r.consumed||r.recovered||block.timestamp<r.terminalExpiresAt||IHolderKernelStateV3(kernel).lifecycle()!=T.Lifecycle.TERMINATED) revert InvalidTransition(); r.recovered=true; --terminalOutstanding; outstandingHolderLiability-=r.payment.amount; emit RecoveryConsumed(id,2,r.payment.amount); }
    function consumeProtocolReserve(bytes32 id) external onlyEvidence { _consumeBucket(id,0); }
    function consumeTreasuryPrincipal(bytes32 id) external onlyEvidence { _consumeBucket(id,3); }
    function protocolReserveRecovery(bytes32 id) external view returns(bool,uint256) { return _bucketRecovery(id,0); }
    function treasuryPrincipalRecovery(bytes32 id) external view returns(bool,uint256) { return _bucketRecovery(id,3); }

    function acknowledgePayment(bytes32 leafId,bytes32 digest) external {
        PaymentRecord storage r=_payments[leafId]; T.HolderPayment storage p=r.payment;
        if (!r.materialized || digest!=_digest(p) || r.consumed || r.recovered || !_candidate(p.distributionId,p.version).finalized) revert InvalidPayment();
        if (r.terminalized ? block.timestamp>=r.terminalExpiresAt : IHolderKernelStateV3(kernel).lifecycle()!=T.Lifecycle.ACTIVE) revert InvalidTransition();
        uint8 bit=msg.sender==distributor?1:msg.sender==liability?2:0; if(bit==0||(r.acknowledgementMask&bit)!=0) revert Unauthorized();
        r.acknowledgementMask|=bit;
        bool done=r.acknowledgementMask==3;
        if(done){r.consumed=true;outstandingHolderLiability-=p.amount;if(r.terminalized){--terminalOutstanding;}else{--unresolvedOrdinary;}}
        emit PaymentAcknowledged(leafId,r.acknowledgementMask,done);
    }
    function consumption(bytes32 leafId) external view returns(uint8 mask,bool complete) { PaymentRecord storage r=_payments[leafId]; return(r.acknowledgementMask,r.consumed); }
    function candidate(bytes32 distributionId,uint32 version) external view returns(Candidate memory) { return _candidate(distributionId,version); }
    function candidateEvidence(bytes32 distributionId,uint32 version) external view returns(CandidateEvidence memory){return _candidateEvidence[distributionId][version];}

    function _consumeBucket(bytes32 id,uint8 kind) private { (bool ok,uint256 amount)=_bucketRecovery(id,kind); if(!ok||_recoveryConsumed[id]) revert InvalidTransition(); _recoveryConsumed[id]=true; emit RecoveryConsumed(id,kind,amount); }
    function _bucketRecovery(bytes32 id,uint8 kind) private view returns(bool,uint256) {
        if(IHolderKernelStateV3(kernel).lifecycle()!=T.Lifecycle.TERMINATED||openReviewCount!=0||unresolvedOrdinary!=0) return(false,0);
        uint256 amount; if(kind==0){(bool ok,bytes memory out)=kernel.staticcall(abi.encodeWithSignature("protocolReserve()")); if(!ok)return(false,0); amount=abi.decode(out,(uint256));}
        else {(bool ok,bytes memory out)=kernel.staticcall(abi.encodeWithSignature("nonStrategyTreasuryPrincipal()")); if(!ok)return(false,0); amount=abi.decode(out,(uint256));}
        (bool ok2,bytes memory out2)=kernel.staticcall(abi.encodeWithSignature("shutdownAt()"));if(!ok2)return(false,0);uint64 shutdownAt=abi.decode(out2,(uint64));
        bytes32 expected=keccak256(abi.encode(keccak256("COMPD_RECOVERY_ID_V3"),block.chainid,kernel,kind,address(this),shutdownAt,kind==0?keccak256("PROTOCOL_RESERVE"):keccak256("TREASURY_PRINCIPAL"),amount));
        return (id==expected&&amount!=0&&!_recoveryConsumed[id],amount);
    }
    function _requireReserve(uint256 amount) private view { uint256 newTotal=outstandingHolderLiability+pendingCandidateReserve+amount; if(newTotal>IHolderKernelStateV3(kernel).holderRewardReserve()) revert InvalidCandidate(); }
    function _candidate(bytes32 distributionId,uint32 version) private view returns(Candidate storage c) { c=_candidates[distributionId]; if(c.distributionId==bytes32(0)||c.version!=version) c=_candidates[keccak256(abi.encode(distributionId,version))]; if(c.distributionId==bytes32(0)||c.version!=version) revert InvalidCandidate(); }
    function _consumed(bytes32 leafId) private view returns(bool) { PaymentRecord storage r=_payments[leafId]; return r.consumed||r.recovered||r.acknowledgementMask!=0; }
    function _digest(T.HolderPayment storage p) private view returns(bytes32) { return keccak256(abi.encode(keccak256("COMPD_HOLDER_PAYMENT_V2"),block.chainid,kernel,p.windowId,p.distributionId,p.version,p.index,p.root,p.lineage,p.leafId,p.recipient,p.asset,p.amount,p.distributionStatus,p.liabilityStatus,p.finalizedAt,p.expiresAt,p.recoveryStatus,p.useId)); }
    function _hashLeaf(Leaf calldata l) private pure returns(bytes32) { return keccak256(abi.encode(LEAF_TYPEHASH,l.domainSeparator,l.distributionId,l.commitmentVersion,l.windowId,l.windowStart,l.windowEnd,l.rewardAsset,l.windowPool,l.finalizedTotalPayable,l.recipientIndex,l.recipient,l.amount,l.datasetHash,l.algorithmVersion)); }
    function _verify(bytes32 h,uint16 index,uint16 count,bytes32[] calldata proof,bytes32 root,bytes32 distributionId,uint32 version) private view returns(bool) {
        uint256 width=1; uint256 depth; while(width<count){width<<=1;++depth;} if(proof.length!=depth)return false;
        for(uint256 level;level<depth;++level){h=((uint256(index)>>level)&1)==0?keccak256(abi.encode(NODE_TYPEHASH,h,proof[level])):keccak256(abi.encode(NODE_TYPEHASH,proof[level],h));}
        distributionId;version; return h==root;
    }
}
