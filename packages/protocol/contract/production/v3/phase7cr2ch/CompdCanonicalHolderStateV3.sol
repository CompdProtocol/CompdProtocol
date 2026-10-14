// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {C2G2BTypes as T} from "../../v2/phase7ar2/C2G2BTypesR2.sol";
import {CompdHolderCandidateTypesV3 as H} from "./CompdHolderCandidateTypesV3.sol";

interface IHolderKernelStateV3 {
    function lifecycle() external view returns(T.Lifecycle);
    function holderRewardReserve() external view returns(uint256);
    function eligibleWindowHR() external view returns(uint256);
    function protocolReserve() external view returns(uint256);
    function nonStrategyTreasuryPrincipal() external view returns(uint256);
    function shutdownAt() external view returns(uint64);
    function holderPaid(bytes32) external view returns(bool);
    function failedHolder(bytes32) external view returns(bytes32,address,uint256,bytes32);
    function deriveWindow(uint64) external view returns(bytes32,bytes32,uint64,uint256,bool);
}
interface IHolderCandidateModuleV3 {
    function candidate(bytes32,uint32) external view returns(H.Candidate memory);
    function candidateEvidence(bytes32,uint32) external view returns(H.CandidateEvidence memory);
    function candidateEvidenceCommitment(bytes32,uint32) external view returns(bytes32);
    function finalizedCandidate(bytes32,uint32) external view returns(H.Candidate memory,bytes32);
    function currentVersion(bytes32) external view returns(uint32);
    function openReviewCount() external view returns(uint256);
    function pendingCandidateReserve() external view returns(uint256);
    function reconciliationDigest() external view returns(bytes32);
    function emptyRecord(bytes32) external view returns(uint64,uint64,uint64,uint32,uint256,bytes32,bool);
}

/// @notice Canonical liability and payment lifecycle state; candidate history lives in the pinned V3 module.
contract CompdCanonicalHolderStateV3 {
    // Seven days from the successful failed-payment terminalize() transition.
    uint64 public constant TERMINAL_GRACE=604_800;
    uint8 private constant NORMAL=1;
    uint8 private constant TERMINAL=2;
    address public immutable kernel;
    address public immutable distributor;
    address public immutable liability;
    address public immutable recoveryEvidence;
    address public immutable finalizer;
    address public immutable candidateModule;
    bytes32 public immutable candidateModuleCodeHash;
    bytes32 public immutable domainSeparator;

    struct PaymentRecord { T.HolderPayment payment; uint64 terminalStartedAt; uint64 terminalExpiresAt; uint8 acknowledgementMask; bool materialized; bool terminalized; bool consumed; bool recovered; }
    struct EmptyLiability { uint256 amount; uint32 version; bytes32 commitment; bool finalized; bool consumed; }
    mapping(bytes32=>PaymentRecord) private _payments;
    mapping(bytes32=>mapping(uint32=>mapping(uint16=>bytes32))) private _leafAt;
    mapping(bytes32=>uint16) public materializedCount;
    mapping(bytes32=>uint256) public materializedTotal;
    mapping(bytes32=>bytes32) public finalizedIdentity;
    mapping(bytes32=>EmptyLiability) private _emptyLiability;
    mapping(bytes32=>bytes32) private _windowByEmptyRecoveryId;
    mapping(bytes32=>bytes32) private _leafByExpiredRecoveryId;
    mapping(bytes32=>bool) private _recoveryConsumed;
    mapping(bytes32=>bool) private _bucketConsumed;
    uint256 public unresolvedOrdinary;
    uint256 public terminalOutstanding;
    uint256 public outstandingHolderLiability;
    bytes32 public reconciliationDigest;

    error Unauthorized(); error InvalidCandidate(); error InvalidProof(); error InvalidPayment(); error InvalidTransition(); error Replay(); error ChangedCode();
    event LeafMaterialized(bytes32 indexed leafId,bytes32 indexed useId,address recipient,uint256 amount);
    event CandidateRegistered(bytes32 indexed distributionId,bytes32 indexed windowId,uint32 version,uint256 amount,uint16 recipients);
    event EmptyLiabilityRegistered(bytes32 indexed windowId,uint32 version,uint256 amount,bytes32 commitment);
    event Terminalized(bytes32 indexed leafId,bytes32 indexed useId,uint64 startedAt,uint64 expiresAt);
    event PaymentAcknowledged(bytes32 indexed leafId,uint8 mask,bool consumed);
    event RecoveryConsumed(bytes32 indexed id,uint8 indexed kind,uint256 amount);

    modifier onlyCandidate(){if(msg.sender!=candidateModule)revert Unauthorized();_;}
    modifier onlyEvidence(){if(msg.sender!=recoveryEvidence)revert Unauthorized();_;}

    constructor(address kernel_,address distributor_,address liability_,address evidence_,address finalizer_,address candidateModule_,address eligibilityToken_,bytes32 candidateCodeHash_){
        if(kernel_==address(0)||distributor_==address(0)||liability_==address(0)||evidence_==address(0)||finalizer_==address(0)||candidateModule_==address(0)||eligibilityToken_==address(0)||candidateCodeHash_==0)revert Unauthorized();
        if(candidateModule_.code.length==0||_hash(candidateModule_)!=candidateCodeHash_)revert ChangedCode();
        kernel=kernel_;distributor=distributor_;liability=liability_;recoveryEvidence=evidence_;finalizer=finalizer_;candidateModule=candidateModule_;candidateModuleCodeHash=candidateCodeHash_;
        domainSeparator=keccak256(abi.encode(keccak256("CompdHolderRewardsDomain(bytes32 protocolId,uint256 chainId,address compdToken,address vault,address distributor,address rewardAsset)"),keccak256("COMPD_HOLDER_REWARDS_V3"),block.chainid,eligibilityToken_,kernel_,distributor_,address(0)));
        reconciliationDigest=keccak256(abi.encode(keccak256("COMPD_HOLDER_REWARDS_V3"),block.chainid,kernel_,address(this)));
    }
    function _checkCandidate() private view {if(candidateModule.code.length==0||_hash(candidateModule)!=candidateModuleCodeHash)revert ChangedCode();}
    function pendingCandidateReserve() external view returns(uint256){_checkCandidate();return IHolderCandidateModuleV3(candidateModule).pendingCandidateReserve();}
    function openReviewCount() external view returns(uint256){return _openReviewCount();}
    function _openReviewCount() private view returns(uint256){_checkCandidate();return IHolderCandidateModuleV3(candidateModule).openReviewCount();}
    function materializationSummary(bytes32 id,uint32 version) external view returns(uint16,uint256){H.Candidate memory c=IHolderCandidateModuleV3(candidateModule).candidate(id,version);return(materializedCount[_candidateKey(id,version)],materializedTotal[_candidateKey(id,version)]);}

    function materializeCandidatePayment(T.HolderPayment calldata p) external onlyCandidate {
        _checkCandidate();H.Candidate memory c=IHolderCandidateModuleV3(candidateModule).candidate(p.distributionId,p.version);bytes32 key=_candidateKey(p.distributionId,p.version);
        if(c.finalized||c.empty||IHolderCandidateModuleV3(candidateModule).currentVersion(c.windowId)!=p.version||p.leafId==0||p.useId==0||p.recipient==address(0)||p.asset!=address(0)||p.amount==0||p.index>=c.recipientCount||p.root!=c.root||p.windowId!=c.windowId||p.amount>c.windowPool||_leafAt[p.distributionId][p.version][p.index]!=0||_payments[p.leafId].materialized)revert InvalidPayment();
        _payments[p.leafId].payment=p;_payments[p.leafId].materialized=true;_leafAt[p.distributionId][p.version][p.index]=p.leafId;++materializedCount[key];materializedTotal[key]+=p.amount;if(materializedTotal[key]>c.payableTotal)revert InvalidPayment();emit LeafMaterialized(p.leafId,p.useId,p.recipient,p.amount);
    }
    function registerFinalizedDistribution(bytes32 id,uint32 version,bytes32 commitment) external onlyCandidate {
        _checkCandidate();(H.Candidate memory c,bytes32 storedCommitment)=IHolderCandidateModuleV3(candidateModule).finalizedCandidate(id,version);(bytes32 wid,bytes32 did,uint64 end,uint256 pool,bool eligible)=IHolderKernelStateV3(kernel).deriveWindow(c.windowStart);
        bytes32 key=_candidateKey(id,version);if(!eligible||!c.finalized||storedCommitment!=commitment||wid!=c.windowId||did!=id||end!=c.windowEnd||pool!=c.windowPool||c.payableTotal!=pool||finalizedIdentity[c.windowId]!=0||materializedCount[key]!=c.recipientCount||materializedTotal[key]!=c.payableTotal)revert InvalidCandidate();
        finalizedIdentity[c.windowId]=commitment;unresolvedOrdinary+=c.recipientCount;outstandingHolderLiability+=c.payableTotal;
        for(uint16 i;i<c.recipientCount;++i){bytes32 leafId=_leafAt[id][version][i];if(leafId==0||!_payments[leafId].materialized)revert InvalidCandidate();_payments[leafId].payment.finalizedAt=uint64(block.timestamp);}
        reconciliationDigest=keccak256(abi.encode(reconciliationDigest,id,wid,version,commitment,c.payableTotal));emit CandidateRegistered(id,wid,version,c.payableTotal,c.recipientCount);
    }
    function registerFinalizedEmptyWindow(bytes32 windowId,uint32 version,uint256 amount,bytes32 commitment) external onlyCandidate {
        _checkCandidate();(uint64 start,uint64 accepted,uint64 finalizedAt,uint32 v,uint256 candidateAmount,bytes32 candidateCommitment,bool finalized)=IHolderCandidateModuleV3(candidateModule).emptyRecord(windowId);(bytes32 wid,,uint64 end,uint256 pool,bool eligible)=IHolderKernelStateV3(kernel).deriveWindow(start);
        if(!finalized||v!=version||candidateAmount!=amount||candidateCommitment!=commitment||wid!=windowId||!eligible||amount!=pool||_emptyLiability[windowId].finalized)revert InvalidCandidate();
        _emptyLiability[windowId]=EmptyLiability(amount,version,commitment,true,false);outstandingHolderLiability+=amount;bytes32 id=emptyRecoveryId(windowId);_windowByEmptyRecoveryId[id]=windowId;reconciliationDigest=keccak256(abi.encode(reconciliationDigest,windowId,version,amount,commitment,accepted,finalizedAt,end));emit EmptyLiabilityRegistered(windowId,version,amount,commitment);
    }
    function emptyRecoveryId(bytes32 windowId) public view returns(bytes32){EmptyLiability storage e=_emptyLiability[windowId];if(!e.finalized)return 0;return keccak256(abi.encode(keccak256("COMPD_RECOVERY_ID_V3"),block.chainid,kernel,uint8(1),address(this),keccak256("NO_RECIPIENT"),windowId,e.version,e.commitment,e.amount));}
    function expiredHolderRecoveryId(bytes32 leafId) public view returns(bytes32){PaymentRecord storage r=_payments[leafId];if(!r.terminalized)return 0;return keccak256(abi.encode(keccak256("COMPD_RECOVERY_ID_V3"),block.chainid,kernel,uint8(2),address(this),keccak256("EXPIRED_HOLDER"),leafId,r.payment.useId,_digest(r.payment)));}

    function terminalize(bytes32 leafId) external {
        PaymentRecord storage r=_payments[leafId];T.HolderPayment storage p=r.payment;H.Candidate memory c=IHolderCandidateModuleV3(candidateModule).candidate(p.distributionId,p.version);
        if(!r.materialized||!c.finalized||r.terminalized||r.consumed||r.recovered||IHolderKernelStateV3(kernel).lifecycle()!=T.Lifecycle.SHUTDOWN_PENDING||IHolderKernelStateV3(kernel).holderPaid(p.useId))revert InvalidTransition();
        (bytes32 d,address recipient,uint256 amount,bytes32 failedLeaf)=IHolderKernelStateV3(kernel).failedHolder(p.useId);if(d!=_digest(p)||recipient!=p.recipient||amount!=p.amount||failedLeaf!=leafId)revert InvalidPayment();
        if(_consumed(leafId)||(p.expiresAt!=0&&block.timestamp>p.expiresAt))revert InvalidPayment();r.terminalized=true;r.terminalStartedAt=uint64(block.timestamp);r.terminalExpiresAt=uint64(block.timestamp)+TERMINAL_GRACE;--unresolvedOrdinary;++terminalOutstanding;reconciliationDigest=keccak256(abi.encode(reconciliationDigest,leafId,p.useId,r.terminalStartedAt,r.terminalExpiresAt));_leafByExpiredRecoveryId[expiredHolderRecoveryId(leafId)]=leafId;emit Terminalized(leafId,p.useId,r.terminalStartedAt,r.terminalExpiresAt);
    }
    function paymentData(bytes32 leafId) external view returns(T.HolderPayment memory p,bool proofValid){PaymentRecord storage r=_payments[leafId];p=r.payment;if(!r.materialized)return(p,false);H.Candidate memory c=IHolderCandidateModuleV3(candidateModule).candidate(p.distributionId,p.version);proofValid=c.finalized&&finalizedIdentity[p.windowId]==IHolderCandidateModuleV3(candidateModule).candidateEvidenceCommitment(p.distributionId,p.version)&&!_consumed(leafId);}
    function paymentDigest(bytes32 leafId) external view returns(bytes32){PaymentRecord storage r=_payments[leafId];if(!r.materialized)return 0;return _digest(r.payment);}
    function paymentWindowStart(bytes32 leafId) external view returns(uint64){PaymentRecord storage r=_payments[leafId];if(!r.materialized)return 0;H.Candidate memory c=IHolderCandidateModuleV3(candidateModule).candidate(r.payment.distributionId,r.payment.version);return c.windowStart;}
    function recoveryWindowStart(bytes32 id,uint8 kind) external view returns(uint64){if(kind==1){bytes32 w=_windowByEmptyRecoveryId[id];if(w==0)return 0;(uint64 start,,,,,,)=IHolderCandidateModuleV3(candidateModule).emptyRecord(w);return start;}if(kind==2){bytes32 leafId=_leafByExpiredRecoveryId[id];if(leafId==0)return 0;PaymentRecord storage r=_payments[leafId];H.Candidate memory c=IHolderCandidateModuleV3(candidateModule).candidate(r.payment.distributionId,r.payment.version);return c.windowStart;}return 0;}
    function canonicalPayment(bytes32 leafId) external view returns(bytes32 digest,address recipient,address asset,uint256 amount,uint8 status,bool payableNow){PaymentRecord storage r=_payments[leafId];T.HolderPayment storage p=r.payment;if(!r.materialized)return(0,address(0),address(0),0,0,false);digest=_digest(p);recipient=p.recipient;asset=p.asset;amount=p.amount;status=r.terminalized?TERMINAL:NORMAL;T.Lifecycle life=IHolderKernelStateV3(kernel).lifecycle();bool lifecycleOk=r.terminalized?(life==T.Lifecycle.SHUTDOWN_PENDING||life==T.Lifecycle.TERMINATED)&&block.timestamp<r.terminalExpiresAt:(life==T.Lifecycle.ACTIVE||life==T.Lifecycle.SHUTDOWN_PENDING);H.Candidate memory c=IHolderCandidateModuleV3(candidateModule).candidate(p.distributionId,p.version);payableNow=c.finalized&&finalizedIdentity[p.windowId]==IHolderCandidateModuleV3(candidateModule).candidateEvidenceCommitment(p.distributionId,p.version)&&!_consumed(leafId)&&!r.recovered&&lifecycleOk&&(p.expiresAt==0||block.timestamp<=p.expiresAt);}
    function terminalStatus(bytes32 leafId) external view returns(bool,uint64,uint64,bytes32){PaymentRecord storage r=_payments[leafId];return(r.terminalized,r.terminalStartedAt,r.terminalExpiresAt,r.payment.useId);}
    function terminalReconciliation() external view returns(bytes32,uint256){_checkCandidate();return(keccak256(abi.encode(reconciliationDigest,IHolderCandidateModuleV3(candidateModule).reconciliationDigest())),unresolvedOrdinary+_openReviewCount());}
    function recoveryReconciliationComplete() external view returns(bool){T.Lifecycle life=IHolderKernelStateV3(kernel).lifecycle();if((life!=T.Lifecycle.SHUTDOWN_PENDING&&life!=T.Lifecycle.TERMINATED)||_openReviewCount()!=0||unresolvedOrdinary!=0||outstandingHolderLiability!=IHolderKernelStateV3(kernel).eligibleWindowHR())return false;return true;}

    function noRecipientRecovery(bytes32 id) external view returns(bool,uint256){bytes32 windowId=_windowByEmptyRecoveryId[id];EmptyLiability storage e=_emptyLiability[windowId];bool ok=windowId!=0&&id==emptyRecoveryId(windowId)&&e.finalized&&!e.consumed&&IHolderKernelStateV3(kernel).lifecycle()==T.Lifecycle.TERMINATED&&_openReviewCount()==0&&unresolvedOrdinary==0;return(ok,ok?e.amount:0);}
    function expiredHolderRecovery(bytes32 id) external view returns(bool eligible,uint256 amount){bytes32 leafId=_leafByExpiredRecoveryId[id];PaymentRecord storage r=_payments[leafId];T.HolderPayment storage p=r.payment;eligible=leafId!=0&&id==expiredHolderRecoveryId(leafId)&&r.materialized&&r.terminalized&&!r.consumed&&!r.recovered&&!IHolderKernelStateV3(kernel).holderPaid(p.useId)&&IHolderKernelStateV3(kernel).lifecycle()==T.Lifecycle.TERMINATED&&block.timestamp>=r.terminalExpiresAt;amount=eligible?p.amount:0;}
    function bucketRecoveryId(uint8 kind) external view returns(bytes32){if(kind!=0&&kind!=3)return 0;uint256 amount=kind==0?IHolderKernelStateV3(kernel).protocolReserve():IHolderKernelStateV3(kernel).nonStrategyTreasuryPrincipal();return _bucketId(kind,amount,IHolderKernelStateV3(kernel).shutdownAt());}
    function protocolReserveRecovery(bytes32 id) external view returns(bool,uint256){return _bucketRecovery(id,0);}
    function treasuryPrincipalRecovery(bytes32 id) external view returns(bool,uint256){return _bucketRecovery(id,3);}
    function consumeNoRecipient(bytes32 id) external onlyEvidence{bytes32 w=_windowByEmptyRecoveryId[id];EmptyLiability storage e=_emptyLiability[w];if(w==0||id!=emptyRecoveryId(w)||!e.finalized||e.consumed)revert Replay();e.consumed=true;outstandingHolderLiability-=e.amount;emit RecoveryConsumed(id,1,e.amount);}
    function consumeExpiredHolder(bytes32 id) external onlyEvidence{bytes32 leafId=_leafByExpiredRecoveryId[id];PaymentRecord storage r=_payments[leafId];if(leafId==0||id!=expiredHolderRecoveryId(leafId)||!r.terminalized||r.consumed||r.recovered||block.timestamp<r.terminalExpiresAt||IHolderKernelStateV3(kernel).lifecycle()!=T.Lifecycle.TERMINATED)revert InvalidTransition();r.recovered=true;--terminalOutstanding;outstandingHolderLiability-=r.payment.amount;emit RecoveryConsumed(id,2,r.payment.amount);}
    function consumeProtocolReserve(bytes32 id) external onlyEvidence{_consumeBucket(id,0);}
    function consumeTreasuryPrincipal(bytes32 id) external onlyEvidence{_consumeBucket(id,3);}
    function _consumeBucket(bytes32 id,uint8 kind) private{(bool ok,uint256 amount)=_bucketRecovery(id,kind);if(!ok||_bucketConsumed[id])revert InvalidTransition();_bucketConsumed[id]=true;emit RecoveryConsumed(id,kind,amount);}
    function _bucketRecovery(bytes32 id,uint8 kind) private view returns(bool,uint256){if(IHolderKernelStateV3(kernel).lifecycle()!=T.Lifecycle.TERMINATED||_openReviewCount()!=0||unresolvedOrdinary!=0)return(false,0);uint256 amount=kind==0?IHolderKernelStateV3(kernel).protocolReserve():IHolderKernelStateV3(kernel).nonStrategyTreasuryPrincipal();bytes32 expected=_bucketId(kind,amount,IHolderKernelStateV3(kernel).shutdownAt());return(id==expected&&amount!=0&&!_bucketConsumed[id],amount);}
    function _bucketId(uint8 kind,uint256 amount,uint64 deadline) private view returns(bytes32){return keccak256(abi.encode(keccak256("COMPD_RECOVERY_ID_V3"),block.chainid,kernel,kind,address(this),deadline,kind==0?keccak256("PROTOCOL_RESERVE"):keccak256("TREASURY_PRINCIPAL"),amount));}
    function acknowledgePayment(bytes32 leafId,bytes32 digest) external{PaymentRecord storage r=_payments[leafId];T.HolderPayment storage p=r.payment;H.Candidate memory c=IHolderCandidateModuleV3(candidateModule).candidate(p.distributionId,p.version);if(!r.materialized||digest!=_digest(p)||r.consumed||r.recovered||!c.finalized||finalizedIdentity[p.windowId]!=IHolderCandidateModuleV3(candidateModule).candidateEvidenceCommitment(p.distributionId,p.version))revert InvalidPayment();if(r.terminalized?block.timestamp>=r.terminalExpiresAt:(IHolderKernelStateV3(kernel).lifecycle()!=T.Lifecycle.ACTIVE&&IHolderKernelStateV3(kernel).lifecycle()!=T.Lifecycle.SHUTDOWN_PENDING))revert InvalidTransition();uint8 bit=msg.sender==distributor?1:msg.sender==liability?2:0;if(bit==0||(r.acknowledgementMask&bit)!=0)revert Unauthorized();r.acknowledgementMask|=bit;bool done=r.acknowledgementMask==3;if(done){r.consumed=true;outstandingHolderLiability-=p.amount;if(r.terminalized)--terminalOutstanding;else --unresolvedOrdinary;}emit PaymentAcknowledged(leafId,r.acknowledgementMask,done);}
    function consumption(bytes32 id) external view returns(uint8,bool){PaymentRecord storage r=_payments[id];return(r.acknowledgementMask,r.consumed);}
    function candidate(bytes32 id,uint32 version) external view returns(H.Candidate memory){_checkCandidate();return IHolderCandidateModuleV3(candidateModule).candidate(id,version);}
    function candidateEvidence(bytes32 id,uint32 version) external view returns(H.CandidateEvidence memory){_checkCandidate();return IHolderCandidateModuleV3(candidateModule).candidateEvidence(id,version);}

    function _consumed(bytes32 leafId) private view returns(bool){PaymentRecord storage r=_payments[leafId];return r.consumed||r.recovered||r.acknowledgementMask!=0;}
    function _candidateKey(bytes32 id,uint32 version) private pure returns(bytes32){return keccak256(abi.encode(id,version));}
    function _digest(T.HolderPayment storage p) private view returns(bytes32){return keccak256(abi.encode(keccak256("COMPD_HOLDER_PAYMENT_V2"),block.chainid,kernel,p.windowId,p.distributionId,p.version,p.index,p.root,p.lineage,p.leafId,p.recipient,p.asset,p.amount,p.distributionStatus,p.liabilityStatus,p.finalizedAt,p.expiresAt,p.recoveryStatus,p.useId));}
    function _hash(address a) private view returns(bytes32 h){assembly{h:=extcodehash(a)}}
}
