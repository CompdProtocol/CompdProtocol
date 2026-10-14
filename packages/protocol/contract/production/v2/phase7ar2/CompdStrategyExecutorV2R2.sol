// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {C2G2BTypes as T, IC2G2BStrategyAdapterR4} from "./C2G2BTypesR2.sol";
import {CompdTerminatedCustodyV3 as Recovery} from "../../v3/phase7cr2ch/CompdTerminatedCustodyV3.sol";

/// @dev Strategy-specific adapters expose commitments reviewed during admission.
interface IStrategyAdmissionMetadataR1 {
    function strategyIdentity() external view returns (bytes32);
    function riskConfigCommitment() external view returns (bytes32);
    function venueDependencyCommitment() external view returns (bytes32);
}

interface IStrategyAdmissionKernelR1 {
    function lifecycle() external view returns (T.Lifecycle);
    function hasActivated() external view returns (bool);
}

/// @notice R1 typed dispatcher and timelocked adapter admission gate.
/// @dev Constructor starts with zero adapters. Existing positions remain closable after disable.
contract CompdStrategyExecutorV2R2 {
    struct Run {
        address adapter; bytes32 adapterCodeHash; bytes32 allocationId; bytes32 positionId;
        bytes32 exitId; bytes32 closeId; uint256 principal; uint256 maxDesignedLoss;
        uint256 physicalRecovered; uint32 collectionAttempts; T.StrategyRunState state;
    }
    struct Proposal { bytes32 codeHash; bytes32 identity; bytes32 riskCommitment; bytes32 venueCommitment; uint64 executableAt; bool pending; }
    struct AdmissionCommitment { bytes32 identity; bytes32 risk; bytes32 venue; }

    uint256 public constant MAX_ADAPTERS = 16;
    uint64 public constant STRATEGY_ADMISSION_TIMELOCK = 24 hours;
    address public immutable kernel;
    address public immutable configurationAdmin;
    address public immutable guardian;
    uint64 public constant admissionDelay = STRATEGY_ADMISSION_TIMELOCK;
    address[] private _adapters;
    mapping(address => bytes32) public adapterCodeHash;
    mapping(address => bool) private _enabled;
    mapping(address => Proposal) public proposals;
    mapping(address => AdmissionCommitment) private _commitments;
    mapping(uint256 => Run) private _runs;
    mapping(uint256 => mapping(bytes32 => bool)) public attemptUsed;
    mapping(uint256 => mapping(bytes32 => bool)) public recoveryUsed;
    mapping(uint256 => bool) private _runUsed;
    mapping(bytes32 => bool) private _allocationUsed;
    bool private _entered;

    error Unauthorized(); error InvalidRun(); error Replay(); error ChangedCode();
    error InvalidAdapterResponse(); error TransferFailed(); error AdmissionUnavailable();
    event AdapterProposed(address indexed adapter,bytes32 indexed codeHash,bytes32 identity,bytes32 riskCommitment,bytes32 venueCommitment,uint64 executableAt);
    event AdapterProposalCancelled(address indexed adapter);
    event AdapterAdmitted(address indexed adapter,bytes32 indexed codeHash,bytes32 identity,bytes32 riskCommitment,bytes32 venueCommitment);
    event AdapterDisabled(address indexed adapter);
    event RunOpened(uint256 indexed runId,address indexed adapter,bytes32 indexed allocationId,uint256 principal,uint256 maxDesignedLoss,bytes32 positionId);
    event ExitRequested(uint256 indexed runId,bytes32 indexed exitId,T.StrategyRunState state);
    event CollectionAttempt(uint256 indexed runId,bytes32 indexed attemptId,uint32 attemptNumber,uint256 physicalBNB,T.StrategyRunState state);
    event CollectionMetadataMismatch(uint256 indexed runId,bytes32 indexed attemptId,uint256 reported,uint256 physical);
    event RunBlocked(uint256 indexed runId,bytes32 indexed evidence);
    event RunClosed(uint256 indexed runId,bytes32 indexed closeId,uint256 physicalTerminalBNB);

    modifier onlyKernel(){if(msg.sender!=kernel)revert Unauthorized();_;}
    modifier lock(){if(_entered)revert Unauthorized();_entered=true;_;_entered=false;}

    receive() external payable {bytes32 h=adapterCodeHash[msg.sender];if(h==0||_codeHash(msg.sender)!=h)revert Unauthorized();}
    /// @notice Only objectively unencumbered balances after Kernel termination.
    function recoverTerminatedFunds() external lock returns(uint256){if(msg.sender!=guardian)revert Unauthorized();return Recovery.native(kernel);}
    function rescueAccidentalERC20(address token,uint256 amount) external lock {if(msg.sender!=guardian)revert Unauthorized();Recovery.token(kernel,token,amount);}

    constructor(address kernel_,address admin_,address guardian_){
        if(kernel_==address(0)||admin_==address(0)||guardian_==address(0))revert Unauthorized();
        kernel=kernel_;configurationAdmin=admin_;guardian=guardian_;
    }

    function adapterCount() external view returns(uint256){return _adapters.length;}
    function adapterAt(uint256 index) external view returns(address adapter,bytes32 codeHash){adapter=_adapters[index];codeHash=adapterCodeHash[adapter];}
    function isApprovedStrategy(address adapter) external view returns(bool){return _enabled[adapter]&&_codeHash(adapter)==adapterCodeHash[adapter];}

    /// @notice Proposal is not executable until the immutable deployment delay has elapsed.
    function proposeStrategy(address adapter,bytes32 identity,bytes32 riskCommitment,bytes32 venueCommitment) external {
        if(msg.sender!=configurationAdmin)revert Unauthorized();
        if(!_admissionState()||adapter.code.length==0||adapterCodeHash[adapter]!=0||proposals[adapter].pending||_adapters.length>=MAX_ADAPTERS||identity==0||riskCommitment==0||venueCommitment==0)revert AdmissionUnavailable();
        bytes32 h=_codeHash(adapter);if(h==0||!_metadataMatches(adapter,identity,riskCommitment,venueCommitment))revert AdmissionUnavailable();
        uint64 ready=uint64(block.timestamp)+admissionDelay;if(ready<block.timestamp)revert AdmissionUnavailable();
        proposals[adapter]=Proposal(h,identity,riskCommitment,venueCommitment,ready,true);
        emit AdapterProposed(adapter,h,identity,riskCommitment,venueCommitment,ready);
    }

    function cancelStrategyProposal(address adapter) external {
        if(msg.sender!=configurationAdmin&&msg.sender!=guardian)revert Unauthorized();
        if(!proposals[adapter].pending)revert AdmissionUnavailable();delete proposals[adapter];emit AdapterProposalCancelled(adapter);
    }

    function activateStrategy(address adapter) external {
        if(msg.sender!=configurationAdmin)revert Unauthorized();
        Proposal memory p=proposals[adapter];
        if(!_admissionState()||!p.pending||block.timestamp<p.executableAt||adapter.code.length==0||_codeHash(adapter)!=p.codeHash||!_metadataMatches(adapter,p.identity,p.riskCommitment,p.venueCommitment))revert AdmissionUnavailable();
        delete proposals[adapter];_enabled[adapter]=true;adapterCodeHash[adapter]=p.codeHash;_commitments[adapter]=AdmissionCommitment(p.identity,p.riskCommitment,p.venueCommitment);_adapters.push(adapter);
        emit AdapterAdmitted(adapter,p.codeHash,p.identity,p.riskCommitment,p.venueCommitment);
    }

    /// @notice Guardian can only remove execution availability; it cannot admit/re-enable an adapter.
    function disableStrategy(address adapter) external {
        if(msg.sender!=guardian)revert Unauthorized();if(!_enabled[adapter])revert AdmissionUnavailable();
        _enabled[adapter]=false;emit AdapterDisabled(adapter);
    }

    function openRun(uint256 runId,address adapter,uint256 amount,uint256 maxDesignedLoss,bytes32 allocationId)
        external payable onlyKernel lock returns(bytes32 positionId_)
    {
        if(runId==0||amount==0||allocationId==0||msg.value!=amount||_runUsed[runId]||_allocationUsed[allocationId])revert InvalidRun();
        _checkExecutableAdapter(adapter);_runUsed[runId]=true;_allocationUsed[allocationId]=true;
        Run storage r=_runs[runId];r.adapter=adapter;r.adapterCodeHash=adapterCodeHash[adapter];r.allocationId=allocationId;r.principal=amount;r.maxDesignedLoss=maxDesignedLoss;r.state=T.StrategyRunState.OPEN;
        uint256 beforeBalance=address(this).balance-msg.value;
        positionId_=IC2G2BStrategyAdapterR4(adapter).open{value:amount}(runId,allocationId,amount,maxDesignedLoss);
        if(positionId_==0||address(this).balance!=beforeBalance)revert InvalidAdapterResponse();r.positionId=positionId_;
        emit RunOpened(runId,adapter,allocationId,amount,maxDesignedLoss,positionId_);
    }

    function requestExit(uint256 runId,bytes32 exitId) external onlyKernel lock returns(T.RunStatus){Run storage r=_runs[runId];_checkRun(r);if(exitId==0||r.state==T.StrategyRunState.CLOSED)revert InvalidRun();if(r.exitId!=0&&r.exitId!=exitId)revert Replay();r.exitId=exitId;try IC2G2BStrategyAdapterR4(r.adapter).requestExit(r.positionId,exitId) returns(T.AdapterPositionStatus s){if(s==T.AdapterPositionStatus.EXIT_REQUESTED)r.state=T.StrategyRunState.EXIT_REQUESTED;else if(s==T.AdapterPositionStatus.RETURN_PENDING)r.state=T.StrategyRunState.RETURN_PENDING;else if(s==T.AdapterPositionStatus.OPEN)r.state=T.StrategyRunState.BLOCKED;else revert InvalidAdapterResponse();}catch{r.state=T.StrategyRunState.BLOCKED;emit RunBlocked(runId,keccak256("EXIT_ATTEMPT_FAILED"));}emit ExitRequested(runId,exitId,r.state);return _asModuleStatus(r.state);}

    function collectPartial(uint256 runId,bytes32 attemptId,uint256 maxPrincipal) external onlyKernel lock returns(uint256 forwarded){Run storage r=_runs[runId];_checkRun(r);if(attemptId==0||attemptUsed[runId][attemptId]||maxPrincipal==0||maxPrincipal>r.principal-r.physicalRecovered||r.exitId==0||r.state==T.StrategyRunState.CLOSED)revert Replay();attemptUsed[runId][attemptId]=true;uint32 n=++r.collectionAttempts;uint256 beforeBalance=address(this).balance;bytes32 recoveryId;uint256 reported;try IC2G2BStrategyAdapterR4(r.adapter).collect(r.positionId,attemptId,maxPrincipal) returns(uint256 amount,bytes32 id){reported=amount;recoveryId=id;}catch{r.state=T.StrategyRunState.BLOCKED;emit CollectionAttempt(runId,attemptId,n,0,r.state);emit RunBlocked(runId,keccak256("COLLECTION_ATTEMPT_FAILED"));return 0;}uint256 physical=address(this).balance-beforeBalance;if(physical>maxPrincipal||(physical!=0&&(recoveryId==0||recoveryUsed[runId][recoveryId])))revert InvalidAdapterResponse();if(physical!=0){recoveryUsed[runId][recoveryId]=true;r.physicalRecovered+=physical;}_checkAdapterCode(r.adapter,r.adapterCodeHash);if(reported!=physical)emit CollectionMetadataMismatch(runId,attemptId,reported,physical);if(physical!=0)_sendKernel(physical);forwarded=physical;if(physical!=0)r.state=T.StrategyRunState.PARTIALLY_RECOVERED;else if(r.state!=T.StrategyRunState.BLOCKED)r.state=T.StrategyRunState.RETURN_PENDING;emit CollectionAttempt(runId,attemptId,n,physical,r.state);}

    function closeToKernel(uint256 runId,bytes32 closeId) external onlyKernel lock returns(uint256 principal,uint256 reportedReturn,bytes32 canonicalCloseId){Run storage r=_runs[runId];_checkRun(r);if(closeId==0||r.closeId!=0||r.exitId==0||r.state==T.StrategyRunState.OPEN||r.state==T.StrategyRunState.CLOSED)revert InvalidRun();r.closeId=closeId;uint256 beforeBalance=address(this).balance;bytes32 closed=IC2G2BStrategyAdapterR4(r.adapter).close(r.positionId,closeId);if(closed!=r.positionId)revert InvalidAdapterResponse();uint256 physical=address(this).balance-beforeBalance;_sendKernel(physical);r.state=T.StrategyRunState.CLOSED;principal=r.principal;reportedReturn=physical;canonicalCloseId=closeId;emit RunClosed(runId,closeId,physical);}

    function observe(uint256 runId) external view returns(T.AdapterPositionStatus status,uint256 reportedRecoverable,bytes32 pendingClaimId){Run storage r=_runs[runId];_checkRunView(r);return IC2G2BStrategyAdapterR4(r.adapter).observe(r.positionId);}
    function runState(uint256 runId) external view returns(T.StrategyRunState){return _runs[runId].state;}
    function positionId(uint256 runId) external view returns(bytes32){return _runs[runId].positionId;}
    function runInfo(uint256 runId) external view returns(address adapter,bytes32 adapterHash,bytes32 allocationId,bytes32 positionId_,bytes32 exitId,bytes32 closeId,uint256 principal,uint256 maxLoss,uint256 recovered,uint32 attempts,T.StrategyRunState state){Run storage r=_runs[runId];return(r.adapter,r.adapterCodeHash,r.allocationId,r.positionId,r.exitId,r.closeId,r.principal,r.maxDesignedLoss,r.physicalRecovered,r.collectionAttempts,r.state);}

    function _admissionState() private view returns(bool){return IStrategyAdmissionKernelR1(kernel).lifecycle()==T.Lifecycle.PAUSED&&IStrategyAdmissionKernelR1(kernel).hasActivated();}
    function _metadataMatches(address a,bytes32 identity,bytes32 risk,bytes32 venue) private view returns(bool){try IStrategyAdmissionMetadataR1(a).strategyIdentity() returns(bytes32 i){if(i!=identity)return false;}catch{return false;}try IStrategyAdmissionMetadataR1(a).riskConfigCommitment() returns(bytes32 r){if(r!=risk)return false;}catch{return false;}try IStrategyAdmissionMetadataR1(a).venueDependencyCommitment() returns(bytes32 v){return v==venue;}catch{return false;}}
    function _checkExecutableAdapter(address a) private view{if(!_enabled[a])revert ChangedCode();_checkAdapterCode(a,adapterCodeHash[a]);AdmissionCommitment storage c=_commitments[a];if(!_metadataMatches(a,c.identity,c.risk,c.venue))revert AdmissionUnavailable();}
    function _checkAdapterCode(address a,bytes32 h) private view{if(a.code.length==0||_codeHash(a)!=h)revert ChangedCode();}
    function _checkRun(Run storage r) private view{_checkAdapterCode(r.adapter,r.adapterCodeHash);if(r.principal==0)revert InvalidRun();}
    function _checkRunView(Run storage r) private view{_checkRun(r);}
    function _sendKernel(uint256 amount) private{if(amount==0)return;(bool ok,)=payable(kernel).call{value:amount}("");if(!ok)revert TransferFailed();}
    function _asModuleStatus(T.StrategyRunState s) private pure returns(T.RunStatus){if(s==T.StrategyRunState.OPEN)return T.RunStatus.OPEN;if(s==T.StrategyRunState.EXIT_REQUESTED)return T.RunStatus.EXIT_REQUESTED;if(s==T.StrategyRunState.RETURN_PENDING)return T.RunStatus.RETURN_PENDING;if(s==T.StrategyRunState.PARTIALLY_RECOVERED)return T.RunStatus.PARTIALLY_RECOVERED;return T.RunStatus.BLOCKED;}
    function _codeHash(address a) private view returns(bytes32 h){assembly{h:=extcodehash(a)}}
}

