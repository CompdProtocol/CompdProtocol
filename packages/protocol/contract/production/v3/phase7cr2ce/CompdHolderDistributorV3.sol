// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {C2G2BTypes as T,IC2G2BHolderDistributor} from "../../v2/phase7ar2/C2G2BTypesR2.sol";
import {CompdHolderCandidateTypesV3 as H} from "./CompdHolderCandidateTypesV3.sol";
import {CompdCanonicalHolderStateV3 as State} from "./CompdCanonicalHolderStateV3.sol";
import {CompdHolderCandidateModuleV3 as Candidate} from "./CompdHolderCandidateModuleV3.sol";

/// @notice Fixed, non-custodial candidate/payment facade; shares liability state with the Liability facade.
contract CompdHolderDistributorV3 is IC2G2BHolderDistributor {
    address public immutable kernel;
    address public immutable finalizer;
    address public immutable state;
    address public immutable candidateModule;
    bytes32 public immutable stateCodeHash;
    bytes32 public immutable candidateCodeHash;
    error Unauthorized(); error ChangedCode();
    constructor(address kernel_,address state_,address candidate_,address finalizer_){if(kernel_==address(0)||state_.code.length==0||candidate_.code.length==0||finalizer_==address(0))revert Unauthorized();kernel=kernel_;state=state_;candidateModule=candidate_;finalizer=finalizer_;stateCodeHash=_hash(state_);candidateCodeHash=_hash(candidate_);if(State(state_).kernel()!=kernel_||State(state_).finalizer()!=finalizer_||State(state_).candidateModule()!=candidate_)revert Unauthorized();}
    function canonicalState() external view returns(address){return state;}
    function _check() private view {if(_hash(state)!=stateCodeHash||_hash(candidateModule)!=candidateCodeHash)revert ChangedCode();}
    function submitCandidate(H.Candidate calldata c,H.CandidateEvidence calldata e) external {if(msg.sender!=finalizer)revert Unauthorized();_check();Candidate(candidateModule).submitCandidate(c,e);}
    function correctCandidate(H.Candidate calldata c,H.CandidateEvidence calldata e,bytes32 reason) external {if(msg.sender!=finalizer)revert Unauthorized();_check();Candidate(candidateModule).correctCandidate(c,e,reason);}
    function materializeLeaf(bytes32 distributionId,uint32 version,H.Leaf calldata leaf,bytes32[] calldata proof) external returns(bytes32){if(msg.sender!=finalizer)revert Unauthorized();_check();return Candidate(candidateModule).materializeLeaf(distributionId,version,leaf,proof);}
    function finalizeCandidate(bytes32 distributionId,uint32 version) external {_check();Candidate(candidateModule).finalizeCandidate(distributionId,version);}
    function submitEmptyCandidate(uint64 windowStart,uint32 version,H.EmptyEvidence calldata evidence) external {if(msg.sender!=finalizer)revert Unauthorized();_check();Candidate(candidateModule).submitEmptyCandidate(windowStart,version,evidence);}
    function finalizeEmptyCandidate(bytes32 windowId) external {_check();Candidate(candidateModule).finalizeEmptyCandidate(windowId);}
    function startTerminalLiability(bytes32 leafId) external {_check();State(state).terminalize(leafId);}
    function paymentData(bytes32 leafId) external view override returns(T.HolderPayment memory,bool){return State(state).paymentData(leafId);}
    function paymentDigest(bytes32 leafId) external view override returns(bytes32){return State(state).paymentDigest(leafId);}
    function paymentWindowStart(bytes32 leafId) external view returns(uint64){return State(state).paymentWindowStart(leafId);}
    function consumePayment(bytes32 leafId,bytes32 digest) external override {if(msg.sender!=kernel)revert Unauthorized();_check();State(state).acknowledgePayment(leafId,digest);}
    function canonicalPayment(bytes32 leafId) external view returns(bytes32,address,address,uint256,uint8,bool){return State(state).canonicalPayment(leafId);}
    function terminalReconciliation() external view returns(bytes32,uint256){return State(state).terminalReconciliation();}
    function _hash(address a) private view returns(bytes32 h){assembly{h:=extcodehash(a)}}
}
