// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {C2G2BTypes as T} from "../../v2/phase7ar2/C2G2BTypesR2.sol";
import {CompdHolderCandidateTypesV3 as H} from "./CompdHolderCandidateTypesV3.sol";

interface ICandidateKernelV3 {
    function lifecycle() external view returns(T.Lifecycle);
    function holderRewardReserve() external view returns(uint256);
    function eligibleWindowHR() external view returns(uint256);
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
interface ICandidateStateV3 {
    function kernel() external view returns(address);
    function candidateModule() external view returns(address);
    function outstandingHolderLiability() external view returns(uint256);
    function materializeCandidatePayment(T.HolderPayment calldata) external;
    function registerFinalizedDistribution(bytes32,uint32,bytes32) external;
    function registerFinalizedEmptyWindow(bytes32,uint32,uint256,bytes32) external;
}
interface ICandidateDistributorV3 { function canonicalState() external view returns(address); }

/// @notice Immutable, non-custodial owner of candidate evidence, versions, review and finality.
contract CompdHolderCandidateModuleV3 {
    uint64 public constant REVIEW_SECONDS=1_800;
    uint16 public constant MAX_RECIPIENTS=30;
    bytes32 public constant PROTOCOL_ID=keccak256("COMPD_HOLDER_REWARDS_V3");
    bytes32 public constant DOMAIN_TYPEHASH=keccak256("CompdHolderRewardsDomain(bytes32 protocolId,uint256 chainId,address compdToken,address vault,address distributor,address rewardAsset)");
    bytes32 public constant DATASET_TYPEHASH=keccak256("CompdHolderRewardDataset(bytes32 domainSeparator,bytes32 distributionId,bytes32 windowId,uint64 windowStart,uint64 windowEnd,uint256 windowPool,uint256 finalizedTotalPayable,uint16 recipientCount,uint32 algorithmVersion,uint32 exclusionSetVersion,bytes32 exclusionSetHash,uint256 activationBlock,bytes32 activationBlockHash,uint64 activationTimestamp,uint256 sourceStartBlock,uint256 finalityBlock,bytes32 finalityBlockHash,bytes32 entriesHash)");
    bytes32 public constant EVIDENCE_TYPEHASH=keccak256("CompdHolderRewardEvidenceV3(bytes32 domainSeparator,bytes32 distributionId,bytes32 windowId,uint32 version,bytes32 datasetHash,bytes32 manifestHash,bytes32 entriesHash,bytes32 activationContextHash,uint256 snapshotBlock,bytes32 snapshotBlockHash,uint256 sourceStartBlock,uint256 closeBlock,bytes32 closeBlockHash,uint256 finalityBlock,bytes32 finalityBlockHash,uint32 exclusionSetVersion,bytes32 exclusionSetHash,uint32 algorithmVersion,bytes32 replayCodeHash,bytes32 root,uint16 recipientCount,uint256 exactPool,bytes32 previousCommitment,bytes32 correctionReasonHash)");
    bytes32 public constant EMPTY_EVIDENCE_TYPEHASH=keccak256("CompdHolderEmptyEvidenceV3(bytes32 domainSeparator,bytes32 windowId,bytes32 distributionId,uint32 version,uint256 exactPool,bytes32 manifestHash,bytes32 entriesHash,uint256 snapshotBlock,bytes32 snapshotBlockHash,uint256 sourceStartBlock,uint256 closeBlock,bytes32 closeBlockHash,uint256 finalityBlock,bytes32 finalityBlockHash,uint32 exclusionSetVersion,bytes32 exclusionSetHash,bytes32 replayCodeHash)");
    bytes32 public constant LEAF_TYPEHASH=keccak256("CompdHolderRewardLeaf(bytes32 domainSeparator,bytes32 distributionId,uint32 commitmentVersion,bytes32 windowId,uint64 windowStart,uint64 windowEnd,address rewardAsset,uint256 windowPool,uint256 finalizedTotalPayable,uint16 recipientIndex,address recipient,uint256 amount,bytes32 datasetHash,uint32 algorithmVersion)");
    bytes32 public constant NODE_TYPEHASH=keccak256("CompdHolderRewardNode(bytes32 left,bytes32 right)");
    bytes32 public constant EMPTY_ENTRIES=keccak256("COMPD_HOLDER_EMPTY_ENTRIES_V3");
    uint64 public constant HOLDER_WINDOW_SECONDS=28_800;

    address public immutable kernel;
    address public immutable state;
    address public immutable distributor;
    address public immutable finalizer;
    bytes32 public immutable domainSeparator;
    struct EmptyRecord { uint64 windowStart; uint64 acceptedAt; uint64 finalizedAt; uint32 version; uint256 amount; bytes32 commitment; bool finalized; }
    mapping(bytes32=>mapping(uint32=>H.Candidate)) private _candidates;
    mapping(bytes32=>mapping(uint32=>H.CandidateEvidence)) private _evidence;
    mapping(bytes32=>mapping(uint32=>bytes32)) public candidateEvidenceCommitment;
    mapping(bytes32=>uint32) public currentVersion;
    mapping(bytes32=>bool) private _windowUsed;
    mapping(bytes32=>EmptyRecord) private _empty;
    mapping(bytes32=>H.EmptyEvidence) private _emptyEvidence;
    mapping(bytes32=>bytes32) private _emptyWindowById;
    uint256 public pendingCandidateReserve;
    uint256 public openReviewCount;
    bytes32 public reconciliationDigest;

    error Unauthorized(); error InvalidCandidate(); error InvalidProof(); error Replay(); error ChangedCode();
    event CandidateSubmitted(bytes32 indexed distributionId,bytes32 indexed windowId,uint32 version,uint64 executableAfter);
    event CandidateCorrected(bytes32 indexed distributionId,uint32 oldVersion,uint32 newVersion,bytes32 reasonHash);
    event CandidateFinalized(bytes32 indexed distributionId,uint32 version,uint256 amount,uint16 recipients);
    event EmptyCandidateFinalized(bytes32 indexed windowId,uint32 version,uint256 amount);

    modifier onlyDistributor(){if(msg.sender!=distributor)revert Unauthorized();_;}
    constructor(address kernel_,address state_,address distributor_,address finalizer_,address eligibilityToken_){
        if(kernel_==address(0)||state_==address(0)||distributor_==address(0)||finalizer_==address(0)||eligibilityToken_==address(0))revert Unauthorized();
        kernel=kernel_;state=state_;distributor=distributor_;finalizer=finalizer_;
        domainSeparator=keccak256(abi.encode(DOMAIN_TYPEHASH,PROTOCOL_ID,block.chainid,eligibilityToken_,kernel_,distributor_,address(0)));
        reconciliationDigest=keccak256(abi.encode(PROTOCOL_ID,block.chainid,kernel_,state_));
    }
    function moduleVersion() external pure returns(uint32){return 3;}
    function _checkState() private view {if(state.code.length==0||ICandidateStateV3(state).kernel()!=kernel||ICandidateStateV3(state).candidateModule()!=address(this))revert ChangedCode();}
    function candidate(bytes32 id,uint32 version) external view returns(H.Candidate memory){return _candidate(id,version);}
    function candidateEvidence(bytes32 id,uint32 version) external view returns(H.CandidateEvidence memory){return _evidence[id][version];}
    function emptyEvidence(bytes32 windowId) external view returns(H.EmptyEvidence memory){return _emptyEvidence[_emptyWindowById[windowId]];}
    function emptyRecord(bytes32 windowId) external view returns(EmptyRecord memory){return _empty[_emptyWindowById[windowId]];}
    function finalizedCandidate(bytes32 id,uint32 version) external view returns(H.Candidate memory c,bytes32 commitment){c=_candidate(id,version);if(!c.finalized)revert InvalidCandidate();commitment=candidateEvidenceCommitment[id][version];}

    function submitCandidate(H.Candidate calldata c,H.CandidateEvidence calldata e) external onlyDistributor {
        _checkState();if(c.empty||c.version!=1||currentVersion[c.windowId]!=0||_windowUsed[c.windowId])revert InvalidCandidate();
        bytes32 commitment=_validate(c,e,0,0);_requireReserve(c.windowPool);H.Candidate storage s=_candidates[c.distributionId][1];if(s.distributionId!=0)revert Replay();
        _store(s,c);s.acceptedAt=uint64(block.timestamp);s.executableAfter=uint64(block.timestamp)+REVIEW_SECONDS;currentVersion[c.windowId]=1;_windowUsed[c.windowId]=true;++openReviewCount;pendingCandidateReserve+=c.windowPool;candidateEvidenceCommitment[c.distributionId][1]=commitment;_evidence[c.distributionId][1]=e;
        reconciliationDigest=keccak256(abi.encode(reconciliationDigest,c.distributionId,c.windowId,uint32(1),commitment,s.executableAfter));emit CandidateSubmitted(c.distributionId,c.windowId,1,s.executableAfter);
    }
    function correctCandidate(H.Candidate calldata n,H.CandidateEvidence calldata e,bytes32 reason) external onlyDistributor {
        _checkState();if(reason==0||n.version<2||n.version!=currentVersion[n.windowId]+1)revert InvalidCandidate();H.Candidate storage p=_candidates[n.distributionId][n.version-1];
        if(p.distributionId==0||p.finalized||currentVersion[p.windowId]!=p.version||block.timestamp>=p.executableAfter||p.windowId!=n.windowId||p.windowPool!=n.windowPool||p.windowStart!=n.windowStart||p.windowEnd!=n.windowEnd)revert InvalidCandidate();
        bytes32 prior=candidateEvidenceCommitment[n.distributionId][n.version-1];bytes32 commitment=_validate(n,e,prior,reason);H.Candidate storage s=_candidates[n.distributionId][n.version];if(s.distributionId!=0)revert Replay();_store(s,n);s.acceptedAt=uint64(block.timestamp);s.executableAfter=uint64(block.timestamp)+REVIEW_SECONDS;currentVersion[n.windowId]=n.version;candidateEvidenceCommitment[n.distributionId][n.version]=commitment;_evidence[n.distributionId][n.version]=e;reconciliationDigest=keccak256(abi.encode(reconciliationDigest,n.distributionId,n.version,reason,commitment,s.executableAfter));emit CandidateCorrected(n.distributionId,n.version-1,n.version,reason);
    }
    function materializeLeaf(bytes32 id,uint32 version,H.Leaf calldata l,bytes32[] calldata proof) external onlyDistributor returns(bytes32 leafId){
        _checkState();H.Candidate storage c=_candidateRef(id,version);if(c.finalized||currentVersion[c.windowId]!=version||block.timestamp>=c.executableAfter||l.domainSeparator!=domainSeparator||l.distributionId!=id||l.commitmentVersion!=version||l.windowId!=c.windowId||l.windowStart!=c.windowStart||l.windowEnd!=c.windowEnd||l.rewardAsset!=address(0)||l.windowPool!=c.windowPool||l.finalizedTotalPayable!=c.payableTotal||l.datasetHash!=c.datasetHash||l.algorithmVersion!=c.algorithmVersion||l.recipientIndex>=c.recipientCount||l.recipient==address(0)||l.amount==0)revert InvalidCandidate();
        leafId=_hashLeaf(l);if(!_verify(leafId,l.recipientIndex,c.recipientCount,proof,c.root))revert InvalidProof();bytes32 useId=keccak256(abi.encode(keccak256("COMPD_HOLDER_PAYMENT_USE_V3"),block.chainid,kernel,distributor,id,version,l.recipientIndex,leafId));T.HolderPayment memory p=T.HolderPayment(c.windowId,id,version,l.recipientIndex,c.root,keccak256(abi.encode(c.datasetHash,c.algorithmVersion)),leafId,l.recipient,address(0),l.amount,1,1,0,0,0,useId);ICandidateStateV3(state).materializeCandidatePayment(p);++c.materializedCount;c.materializedTotal+=l.amount;
    }
    function finalizeCandidate(bytes32 id,uint32 version) external {_checkState();H.Candidate storage c=_candidateRef(id,version);if(c.finalized||currentVersion[c.windowId]!=version||block.timestamp<c.executableAfter||c.materializedCount!=c.recipientCount||c.materializedTotal!=c.payableTotal)revert InvalidCandidate();c.finalized=true;--openReviewCount;pendingCandidateReserve-=c.windowPool;bytes32 commitment=candidateEvidenceCommitment[id][version];ICandidateStateV3(state).registerFinalizedDistribution(id,version,commitment);reconciliationDigest=keccak256(abi.encode(reconciliationDigest,id,version,c.root,c.payableTotal,c.recipientCount,block.timestamp));emit CandidateFinalized(id,version,c.payableTotal,c.recipientCount);}

    function submitEmptyCandidate(uint64 start,uint32 version,H.EmptyEvidence calldata e) external onlyDistributor {_checkState();if(version!=1||_empty[keccak256(abi.encode(start))].version!=0||ICandidateKernelV3(kernel).lifecycle()!=T.Lifecycle.ACTIVE)revert InvalidCandidate();(bytes32 wid,bytes32 did,uint64 end,uint256 pool,bool eligible)=ICandidateKernelV3(kernel).deriveWindow(start);if(!eligible||pool==0||wid==0||did==0||end<=start||_windowUsed[wid])revert InvalidCandidate();_validateEmpty(wid,did,version,pool,e);_requireReserve(pool);bytes32 commitment=_emptyCommitment(wid,did,version,pool,e);bytes32 key=keccak256(abi.encode(start));_windowUsed[wid]=true;_empty[key]=EmptyRecord(start,uint64(block.timestamp),0,version,pool,commitment,false);_emptyEvidence[key]=e;_emptyWindowById[wid]=key;pendingCandidateReserve+=pool;++openReviewCount;}
    function finalizeEmptyCandidate(bytes32 windowId) external {_checkState();bytes32 key=_emptyWindowById[windowId];EmptyRecord storage e=_empty[key];T.Lifecycle life=ICandidateKernelV3(kernel).lifecycle();if(key==0||e.version==0||e.finalized||block.timestamp<uint256(e.acceptedAt)+REVIEW_SECONDS||(life!=T.Lifecycle.ACTIVE&&life!=T.Lifecycle.SHUTDOWN_PENDING))revert InvalidCandidate();e.finalized=true;e.finalizedAt=uint64(block.timestamp);pendingCandidateReserve-=e.amount;--openReviewCount;bytes32 digest=e.commitment;ICandidateStateV3(state).registerFinalizedEmptyWindow(windowId,e.version,e.amount,digest);reconciliationDigest=keccak256(abi.encode(reconciliationDigest,windowId,e.version,e.amount,digest,e.finalizedAt));emit EmptyCandidateFinalized(windowId,e.version,e.amount);}
    function emptyRecoveryId(bytes32 windowId) external view returns(bytes32){bytes32 key=_emptyWindowById[windowId];EmptyRecord storage e=_empty[key];if(!e.finalized)return 0;return keccak256(abi.encode(keccak256("COMPD_RECOVERY_ID_V3"),block.chainid,kernel,uint8(1),address(this),keccak256("NO_RECIPIENT"),windowId,e.version,e.commitment,e.amount));}
    mapping(bytes32=>bool) public zeroWindowFinalized;
    event ZeroWindowFinalized(bytes32 indexed windowId,uint64 start,uint64 end);
    /// @notice Closed zero-funded windows have no payable leaf or liability. Finalization is idempotent.
    function finalizeZeroWindow(uint64 start) external {
        _checkState();ICandidateKernelV3 k=ICandidateKernelV3(kernel);
        (bytes32 wid,,uint64 end,uint256 pool,)=k.deriveWindow(start);
        if(!k.activationSealed()||k.activationSealFailed()||k.lifecycle()!=T.Lifecycle.ACTIVE||wid==0||end>block.timestamp||pool!=0)revert InvalidCandidate();
        if(zeroWindowFinalized[wid])return;
        if(_windowUsed[wid])revert Replay();_windowUsed[wid]=true;zeroWindowFinalized[wid]=true;emit ZeroWindowFinalized(wid,start,end);
    }
    function computeActivationContextHash(uint64 activationBlock,bytes32 activationHash,uint64 activationTime,uint64 firstWindow,uint256 chainId,address vault) external pure returns(bytes32){if(activationBlock==0)return 0;return keccak256(abi.encode(keccak256("COMPD_HOLDER_ACTIVATION_CONTEXT_V3"),chainId,vault,activationBlock,activationHash,activationTime,firstWindow));}
    function computeWindowIdentity(uint64 activationBlock,bytes32 activationHash,uint64 activationTime,uint64 windowStart,uint256 chainId,address token,address vault,address distributor_) external pure returns(bytes32 wid,bytes32 did,uint64 end){if(windowStart%HOLDER_WINDOW_SECONDS!=0||windowStart>type(uint64).max-HOLDER_WINDOW_SECONDS)return(0,0,0);end=windowStart+HOLDER_WINDOW_SECONDS;bytes32 domain=keccak256(abi.encode(DOMAIN_TYPEHASH,PROTOCOL_ID,chainId,token,vault,distributor_,address(0)));wid=keccak256(abi.encode(keccak256("CompdHolderRewardWindow(bytes32 domainSeparator,uint256 activationBlock,bytes32 activationBlockHash,uint64 activationTimestamp,uint64 windowStart,uint64 windowEnd)"),domain,activationBlock,activationHash,activationTime,windowStart,end));did=keccak256(abi.encode(keccak256("CompdHolderRewardDistribution(bytes32 domainSeparator,bytes32 windowId)"),domain,wid));}
    function computeLaunchWindowIdentity(uint64 activationBlock,bytes32 activationHash,uint64 launchTime,uint64 start,uint256 chainId,address token,address vault,address distributor_) external pure returns(bytes32 wid,bytes32 did,uint64 end){
        if(launchTime>type(uint64).max-HOLDER_WINDOW_SECONDS-900||start<launchTime)return(0,0,0);
        uint64 firstEnd=launchTime+900;
        if(start==launchTime)end=firstEnd;
        else if(start==firstEnd)end=uint64((uint256(firstEnd)+HOLDER_WINDOW_SECONDS-1)/HOLDER_WINDOW_SECONDS*HOLDER_WINDOW_SECONDS);
        if(end==start||end==0){if(start%HOLDER_WINDOW_SECONDS!=0||start<firstEnd||start>type(uint64).max-HOLDER_WINDOW_SECONDS)return(0,0,0);end=start+HOLDER_WINDOW_SECONDS;}
        bytes32 domain=keccak256(abi.encode(DOMAIN_TYPEHASH,PROTOCOL_ID,chainId,token,vault,distributor_,address(0)));
        wid=keccak256(abi.encode(keccak256("CompdHolderRewardWindow(bytes32 domainSeparator,uint256 activationBlock,bytes32 activationBlockHash,uint64 activationTimestamp,uint64 windowStart,uint64 windowEnd)"),domain,activationBlock,activationHash,launchTime,start,end));
        did=keccak256(abi.encode(keccak256("CompdHolderRewardDistribution(bytes32 domainSeparator,bytes32 windowId)"),domain,wid));
    }
    function computeExclusionSetHash(address[15] calldata addresses_,uint32 version) external pure returns(bytes32){address[15] memory values=addresses_;for(uint256 i=1;i<15;++i){address v=values[i];uint256 j=i;while(j!=0&&uint160(values[j-1])>uint160(v)){values[j]=values[j-1];--j;}values[j]=v;}address[] memory sorted=new address[](15);uint256 count;address previous;for(uint256 i;i<15;++i){address v=values[i];if(v!=address(0)&&v!=previous){sorted[count++]=v;previous=v;}}assembly ("memory-safe"){mstore(sorted,count)}return keccak256(abi.encode(keccak256("CompdHolderRewardExclusionSet(uint32 exclusionSetVersion,address[] sortedExcludedAddresses)"),version,sorted));}

    function _validate(H.Candidate calldata c,H.CandidateEvidence calldata e,bytes32 prior,bytes32 reason) private view returns(bytes32 commitment){ICandidateKernelV3 k=ICandidateKernelV3(kernel);(bytes32 wid,bytes32 did,uint64 end,uint256 pool,bool eligible)=k.deriveWindow(c.windowStart);if(!k.activationSealed()||k.activationSealFailed()||k.lifecycle()!=T.Lifecycle.ACTIVE||!eligible||wid!=c.windowId||did!=c.distributionId||end!=c.windowEnd||pool!=c.windowPool||c.rewardAsset!=address(0)||c.algorithmVersion!=1||c.datasetHash==0||c.root==0||c.recipientCount==0||c.recipientCount>MAX_RECIPIENTS||c.payableTotal!=pool||c.windowEnd>=block.timestamp)revert InvalidCandidate();if(e.manifestHash==0||e.entriesHash==0||e.snapshotBlockHash==0||e.closeBlockHash==0||e.finalityBlockHash==0||e.replayCodeHash==0||e.exclusionSetHash!=k.activationExclusionSetHash()||e.exclusionSetVersion!=k.exclusionSetVersion()||e.sourceStartBlock!=k.activationBlock()||e.snapshotBlock<k.activationBlock()||e.closeBlock<=e.snapshotBlock||e.finalityBlock<e.closeBlock)revert InvalidCandidate();bytes32 dataset=keccak256(abi.encode(DATASET_TYPEHASH,domainSeparator,c.distributionId,c.windowId,c.windowStart,c.windowEnd,c.windowPool,c.payableTotal,c.recipientCount,c.algorithmVersion,e.exclusionSetVersion,e.exclusionSetHash,uint256(k.activationBlock()),k.activationBlockHash(),k.activationTimestamp(),e.sourceStartBlock,e.finalityBlock,e.finalityBlockHash,e.entriesHash));if(dataset!=c.datasetHash)revert InvalidCandidate();commitment=keccak256(abi.encode(EVIDENCE_TYPEHASH,domainSeparator,c.distributionId,c.windowId,c.version,c.datasetHash,e.manifestHash,e.entriesHash,k.activationContextHash(),e.snapshotBlock,e.snapshotBlockHash,e.sourceStartBlock,e.closeBlock,e.closeBlockHash,e.finalityBlock,e.finalityBlockHash,e.exclusionSetVersion,e.exclusionSetHash,c.algorithmVersion,e.replayCodeHash,c.root,c.recipientCount,c.windowPool,prior,reason));}
    function _validateEmpty(bytes32 wid,bytes32 did,uint32 version,uint256 pool,H.EmptyEvidence calldata e) private view {ICandidateKernelV3 k=ICandidateKernelV3(kernel);if(version==0||e.manifestHash==0||e.entriesHash!=EMPTY_ENTRIES||e.snapshotBlockHash==0||e.closeBlockHash==0||e.finalityBlockHash==0||e.replayCodeHash==0||e.exclusionSetHash!=k.activationExclusionSetHash()||e.exclusionSetVersion!=k.exclusionSetVersion()||e.sourceStartBlock!=k.activationBlock()||e.snapshotBlock<k.activationBlock()||e.closeBlock<=e.snapshotBlock||e.finalityBlock<e.closeBlock||wid==0||did==0||pool==0)revert InvalidCandidate();}
    function _emptyCommitment(bytes32 wid,bytes32 did,uint32 version,uint256 pool,H.EmptyEvidence calldata e) private view returns(bytes32){return keccak256(abi.encode(EMPTY_EVIDENCE_TYPEHASH,domainSeparator,wid,did,version,pool,e.manifestHash,e.entriesHash,e.snapshotBlock,e.snapshotBlockHash,e.sourceStartBlock,e.closeBlock,e.closeBlockHash,e.finalityBlock,e.finalityBlockHash,e.exclusionSetVersion,e.exclusionSetHash,e.replayCodeHash));}
    function _requireReserve(uint256 amount) private view {uint256 liab=ICandidateStateV3(state).outstandingHolderLiability();if(liab+pendingCandidateReserve+amount>ICandidateKernelV3(kernel).holderRewardReserve())revert InvalidCandidate();}
    function _candidate(bytes32 id,uint32 v) private view returns(H.Candidate memory c){c=_candidates[id][v];if(c.distributionId==0||c.version!=v)revert InvalidCandidate();}
    function _candidateRef(bytes32 id,uint32 v) private view returns(H.Candidate storage c){c=_candidates[id][v];if(c.distributionId==0||c.version!=v)revert InvalidCandidate();}
    function _store(H.Candidate storage s,H.Candidate calldata c) private {s.distributionId=c.distributionId;s.windowId=c.windowId;s.windowStart=c.windowStart;s.windowEnd=c.windowEnd;s.rewardAsset=c.rewardAsset;s.windowPool=c.windowPool;s.payableTotal=c.payableTotal;s.recipientCount=c.recipientCount;s.root=c.root;s.datasetHash=c.datasetHash;s.algorithmVersion=c.algorithmVersion;s.version=c.version;s.empty=c.empty;}
    function _hashLeaf(H.Leaf calldata l) private pure returns(bytes32){return keccak256(abi.encode(LEAF_TYPEHASH,l.domainSeparator,l.distributionId,l.commitmentVersion,l.windowId,l.windowStart,l.windowEnd,l.rewardAsset,l.windowPool,l.finalizedTotalPayable,l.recipientIndex,l.recipient,l.amount,l.datasetHash,l.algorithmVersion));}
    function _verify(bytes32 h,uint16 index,uint16 count,bytes32[] calldata proof,bytes32 root) private pure returns(bool){uint256 width=1;uint256 depth;while(width<count){width<<=1;++depth;}if(proof.length!=depth)return false;for(uint256 i;i<depth;++i){h=((uint256(index)>>i)&1)==0?keccak256(abi.encode(NODE_TYPEHASH,h,proof[i])):keccak256(abi.encode(NODE_TYPEHASH,proof[i],h));}return h==root;}
}
