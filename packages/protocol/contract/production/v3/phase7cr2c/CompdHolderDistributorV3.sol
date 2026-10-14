// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {C2G2BTypes as T, IC2G2BHolderDistributor} from "../../v2/phase7ar2/C2G2BTypesR2.sol";
import {CompdCanonicalHolderStateV3 as State} from "./CompdCanonicalHolderStateV3.sol";

interface IKernelFinalizerIdentityV3 { function lifecycle() external view returns (T.Lifecycle); }

/// @notice Non-custodial R2-compatible Distributor facade over the shared V3 state.
contract CompdHolderDistributorV3 is IC2G2BHolderDistributor {
    address public immutable kernel;
    address public immutable finalizer;
    address public immutable state;
    bytes32 public immutable stateCodeHash;
    error Unauthorized(); error ChangedCode();

    constructor(address kernel_,address state_,address finalizer_) {
        if(kernel_==address(0)||state_.code.length==0||finalizer_==address(0)) revert Unauthorized();
        kernel=kernel_;state=state_;finalizer=finalizer_;stateCodeHash=_hash(state_);
        if(State(state_).kernel()!=kernel_||State(state_).finalizer()!=finalizer_)revert Unauthorized();
    }
    function canonicalState() external view returns(address){return state;}
    function submitCandidate(State.Candidate calldata c) external {if(msg.sender!=finalizer)revert Unauthorized();_check();State(state).submitCandidate(c);}
    function submitCandidate(State.Candidate calldata c,State.CandidateEvidence calldata e) external {if(msg.sender!=finalizer)revert Unauthorized();_check();State(state).submitCandidate(c,e);}
    function correctCandidate(bytes32 distributionId,uint32 version,bytes32 reasonHash,bytes32 root,bytes32 datasetHash) external {if(msg.sender!=finalizer)revert Unauthorized();_check();State(state).correctCandidate(distributionId,version,reasonHash,root,datasetHash);}
    function correctCandidate(State.Candidate calldata c,State.CandidateEvidence calldata e,bytes32 reasonHash) external {if(msg.sender!=finalizer)revert Unauthorized();_check();State(state).correctCandidate(c,e,reasonHash);}
    function materializeLeaf(bytes32 distributionId,uint32 version,State.Leaf calldata leaf,bytes32[] calldata proof) external returns(bytes32){if(msg.sender!=finalizer)revert Unauthorized();_check();return State(state).materializeLeaf(distributionId,version,leaf,proof);}
    function finalizeCandidate(bytes32 distributionId,uint32 version) external {_check();State(state).finalizeCandidate(distributionId,version);}
    function submitEmptyCandidate(bytes32 windowId,uint32 version,uint256 exactPool,bytes32 evidenceHash) external {if(msg.sender!=finalizer)revert Unauthorized();_check();State(state).submitEmptyCandidate(windowId,version,exactPool,evidenceHash);}
    function finalizeEmptyCandidate(bytes32 windowId) external {_check();State(state).finalizeEmptyCandidate(windowId);}
    function startTerminalLiability(bytes32 leafId) external {_check();State(state).terminalize(leafId);}

    function paymentData(bytes32 leafId) external view override returns(T.HolderPayment memory payment,bool proofValid){return State(state).paymentData(leafId);}
    function paymentDigest(bytes32 leafId) external view override returns(bytes32){return State(state).paymentDigest(leafId);}
    function paymentWindowStart(bytes32 leafId) external view returns(uint64){return State(state).paymentWindowStart(leafId);}
    function consumePayment(bytes32 leafId,bytes32 digest) external override {if(msg.sender!=kernel)revert Unauthorized();_check();State(state).acknowledgePayment(leafId,digest);}
    function canonicalPayment(bytes32 leafId) external view returns(bytes32,address,address,uint256,uint8,bool){return State(state).canonicalPayment(leafId);}
    function terminalReconciliation() external view returns(bytes32,uint256){return State(state).terminalReconciliation();}
    function _check() private view {if(_hash(state)!=stateCodeHash)revert ChangedCode();}
    function _hash(address a) private view returns(bytes32 h){assembly{h:=extcodehash(a)}}
}
