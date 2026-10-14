// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {C2G2BTypes as T,IC2G2BStrategyExecutorR4} from "../../v2/phase7ar2/C2G2BTypesR2.sol";

interface IKernelSettlementR4 {
    function lifecycle() external view returns(T.Lifecycle);
    function strategyExecutor() external view returns(address);
    function strategyExecutorHash() external view returns(bytes32);
    function allocateStrategyPrincipal(uint256,address,uint256,bytes32) external;
    function requestStrategyExit(uint256,bytes32) external returns(T.RunStatus);
    function collectStrategyPrincipal(uint256,bytes32) external returns(uint256);
    function settleStrategyPrincipal(uint256,bytes32) external;
    function runPrincipal(uint256) external view returns(uint256);
    function runMaxDesignedLoss(uint256) external view returns(uint256);
    function runActualLoss(uint256) external view returns(uint256);
    function runLossBoundBreached(uint256) external view returns(bool);
    function principalCredited(uint256) external view returns(uint256);
    function runTotalPhysicalReturn(uint256) external view returns(uint256);
    function strategyAllocationHalted() external view returns(bool);
    function strategyCapital() external view returns(uint256);
    function cumulativeRealizedLoss() external view returns(uint256);
}

/// @notice Isolated R4 typed Executor lifecycle module; finality/write-off is deliberately not implemented.
contract CompdSettlementModuleV3 {
    uint8 public constant MODULE_ID=0;
    uint32 public constant MODULE_VERSION=4;
    address public immutable kernel;
    address public immutable strategyExecutor;
    bytes32 public immutable executorHash;
    struct Run {address adapter;uint256 principal;uint256 principalCredited;uint256 cumulativePhysicalReturn;uint64 openedAt;uint64 lastTransitionAt;bytes32 allocationId;bytes32 exitId;bytes32 closeId;bytes32 blockedEvidence;T.StrategyRunState state;uint256 maxDesignedLoss;uint256 actualLoss;bool lossBoundBreached;uint32 collectionAttempts;}
    /// @notice Append-only future attribution record; it has no accounting or recovery authority.
    struct LateRecoveryRecord {uint256 runId;bytes32 recoveryId;uint256 physicalAmount;bytes32 priorTerminalRef;address destination;bytes32 attribution;}
    mapping(uint256=>Run) private _runs;
    mapping(uint256=>mapping(bytes32=>bool)) public collectionAttemptUsed;
    mapping(bytes32=>LateRecoveryRecord) public lateRecoveryRecord;
    uint256[] private _history;
    bool private _entered;bool public riskLatched;bool private _riskInitialized;uint64 private _riskDay;uint256 private _dayCapital;uint256 private _dayLossStart;uint256 public peakStrategyCapital;
    // Admitted runs remain outstanding until their successful CLOSED transition.
    // Append-only history is evidence, never a lifetime-sized termination scan.
    uint256 private _unclosedRunCount;
    error Unauthorized();error InvalidRun();error ChangedCode();error ExternalFailure();error Replay();
    event RunOpened(uint256 indexed runId,address indexed adapter,uint256 principal,bytes32 allocationId,bytes32 positionId);
    event ExitTransition(uint256 indexed runId,bytes32 indexed exitId,T.StrategyRunState state);
    event CollectionRecorded(uint256 indexed runId,bytes32 indexed attemptId,uint32 attemptNumber,uint256 physicalPrincipal,uint256 remainingAP,T.StrategyRunState state);
    event RunBlocked(uint256 indexed runId,bytes32 indexed evidence);
    event RunClosed(uint256 indexed runId,bytes32 indexed closeId,uint256 totalPhysicalReturn,uint256 actualLoss,T.StrategyRunState state);
    event RiskBreakerLatched(uint256 dailyLoss,uint256 dayCapital,uint256 drawdown,uint256 peakCapital);
    event LossBoundBreachRecorded(uint256 indexed runId,uint256 maxDesignedLoss,uint256 actualLoss);
    event LateRecoveryHistoryRecorded(uint256 indexed runId,bytes32 indexed recoveryId,uint256 physicalAmount,bytes32 priorTerminalRef,address destination,bytes32 attribution);
    modifier lock(){if(_entered)revert Unauthorized();_entered=true;_;_entered=false;}
    /// @dev Forward-reference-safe: Kernel and its internally-created Executor are
    /// deliberately not queried here. Kernel validates both addresses/hashes last.
    constructor(address kernel_,address executor_,bytes32 expectedExecutorHash_){if(kernel_==address(0)||executor_==address(0)||expectedExecutorHash_==bytes32(0))revert Unauthorized();kernel=kernel_;strategyExecutor=executor_;executorHash=expectedExecutorHash_;}
    function moduleId() external pure returns(uint8){return MODULE_ID;}
    function moduleVersion() external pure returns(uint32){return MODULE_VERSION;}

    function startRun(uint256 id,address adapter,uint256 amount,bytes32 allocationId) external lock {
        if(msg.sender!=_automation()||id==0||_runs[id].state!=T.StrategyRunState.NONE||adapter==address(0)||amount==0||allocationId==0)revert Unauthorized();
        _checkExecutor();_syncRisk();if(riskLatched||IKernelSettlementR4(kernel).strategyAllocationHalted())revert InvalidRun();
        if(!IC2G2BStrategyExecutorR4(strategyExecutor).isApprovedStrategy(adapter))revert InvalidRun();
        IKernelSettlementR4(kernel).allocateStrategyPrincipal(id,adapter,amount,allocationId);
        uint256 maxLoss=IKernelSettlementR4(kernel).runMaxDesignedLoss(id);bytes32 positionId_=IC2G2BStrategyExecutorR4(strategyExecutor).positionId(id);
        if(positionId_==bytes32(0)||IC2G2BStrategyExecutorR4(strategyExecutor).runState(id)!=T.StrategyRunState.OPEN)revert ExternalFailure();
        _runs[id]=Run(adapter,amount,0,0,uint64(block.timestamp),uint64(block.timestamp),allocationId,0,0,0,T.StrategyRunState.OPEN,maxLoss,0,false,0);_history.push(id);++_unclosedRunCount;
        emit RunOpened(id,adapter,amount,allocationId,positionId_);
    }

    function requestExit(uint256 id,bytes32 exitId) external lock {
        if(msg.sender!=_automation()&&msg.sender!=_guardian())revert Unauthorized();Run storage r=_runs[id];
        if(r.state==T.StrategyRunState.NONE||r.state==T.StrategyRunState.CLOSED||exitId==bytes32(0))revert InvalidRun();if(r.exitId!=bytes32(0)&&r.exitId!=exitId)revert Replay();r.exitId=exitId;
        _checkExecutor();T.RunStatus s=IKernelSettlementR4(kernel).requestStrategyExit(id,exitId);
        if(s==T.RunStatus.EXIT_REQUESTED)r.state=T.StrategyRunState.EXIT_REQUESTED;else if(s==T.RunStatus.RETURN_PENDING)r.state=T.StrategyRunState.RETURN_PENDING;else if(s==T.RunStatus.PARTIALLY_RECOVERED)r.state=T.StrategyRunState.PARTIALLY_RECOVERED;else if(s==T.RunStatus.BLOCKED)r.state=T.StrategyRunState.BLOCKED;else revert ExternalFailure();
        r.lastTransitionAt=uint64(block.timestamp);emit ExitTransition(id,exitId,r.state);
    }

    /// @notice Permissionless: caller cannot select amount, target, route, recipient or strategy.
    function collectRun(uint256 id,bytes32 attemptId) external lock returns(uint256 credited) {
        Run storage r=_runs[id];if(r.state==T.StrategyRunState.NONE||r.state==T.StrategyRunState.CLOSED||r.exitId==0||attemptId==0||collectionAttemptUsed[id][attemptId])revert Replay();_checkExecutor();
        collectionAttemptUsed[id][attemptId]=true;uint256 oldCredited=IKernelSettlementR4(kernel).principalCredited(id);
        credited=IKernelSettlementR4(kernel).collectStrategyPrincipal(id,attemptId);r.principalCredited=IKernelSettlementR4(kernel).principalCredited(id);r.cumulativePhysicalReturn=IKernelSettlementR4(kernel).runTotalPhysicalReturn(id);
        if(r.principalCredited<oldCredited||r.principalCredited>r.principal)revert ExternalFailure();unchecked{++r.collectionAttempts;}
        T.StrategyRunState es=IC2G2BStrategyExecutorR4(strategyExecutor).runState(id);if(es==T.StrategyRunState.BLOCKED)r.state=T.StrategyRunState.BLOCKED;else if(credited!=0)r.state=T.StrategyRunState.PARTIALLY_RECOVERED;else r.state=T.StrategyRunState.RETURN_PENDING;
        r.lastTransitionAt=uint64(block.timestamp);emit CollectionRecorded(id,attemptId,r.collectionAttempts,credited,r.principal-r.principalCredited,r.state);
    }

    function closeRun(uint256 id,bytes32 closeId) external lock {
        if(msg.sender!=_automation()&&msg.sender!=_guardian())revert Unauthorized();Run storage r=_runs[id];if(r.state==T.StrategyRunState.NONE||r.state==T.StrategyRunState.OPEN||r.state==T.StrategyRunState.CLOSED||r.exitId==0||closeId==0)revert InvalidRun();if(r.closeId!=0)revert Replay();_checkExecutor();
        IKernelSettlementR4(kernel).settleStrategyPrincipal(id,closeId);r.closeId=closeId;r.principalCredited=IKernelSettlementR4(kernel).principalCredited(id);r.cumulativePhysicalReturn=IKernelSettlementR4(kernel).runTotalPhysicalReturn(id);r.actualLoss=IKernelSettlementR4(kernel).runActualLoss(id);r.lossBoundBreached=IKernelSettlementR4(kernel).runLossBoundBreached(id);
        if(r.lossBoundBreached){riskLatched=true;emit LossBoundBreachRecorded(id,r.maxDesignedLoss,r.actualLoss);}_syncRisk();r.state=T.StrategyRunState.CLOSED;--_unclosedRunCount;r.lastTransitionAt=uint64(block.timestamp);emit RunClosed(id,closeId,r.cumulativePhysicalReturn,r.actualLoss,r.state);
    }

    /// @notice Dormant history-only hook for a future measured Executor recovery route.
    /// @dev Current R4 Executor has no caller for this function; it cannot move or account funds.
    function recordLateRecoveryHistory(uint256 id,bytes32 recoveryId,uint256 physicalAmount,bytes32 priorTerminalRef) external {
        if(msg.sender!=strategyExecutor||_hash(strategyExecutor)!=executorHash||recoveryId==0||physicalAmount==0)revert Unauthorized();
        Run storage r=_runs[id];if(r.state!=T.StrategyRunState.CLOSED||priorTerminalRef==0||priorTerminalRef!=r.closeId||lateRecoveryRecord[recoveryId].recoveryId!=0)revert InvalidRun();
        bytes32 attribution=keccak256(abi.encode(id,recoveryId,physicalAmount,priorTerminalRef,kernel));
        lateRecoveryRecord[recoveryId]=LateRecoveryRecord(id,recoveryId,physicalAmount,priorTerminalRef,kernel,attribution);
        emit LateRecoveryHistoryRecorded(id,recoveryId,physicalAmount,priorTerminalRef,kernel,attribution);
    }

    function recordBlocked(uint256 id,bytes32 evidence) external {if(msg.sender!=_guardian()||evidence==0)revert Unauthorized();Run storage r=_runs[id];if(r.state==T.StrategyRunState.NONE||r.state==T.StrategyRunState.CLOSED)revert InvalidRun();r.state=T.StrategyRunState.BLOCKED;r.blockedEvidence=evidence;r.lastTransitionAt=uint64(block.timestamp);emit RunBlocked(id,evidence);}
    function run(uint256 id) external view returns(Run memory){return _runs[id];}
    function historyLength() external view returns(uint256){return _history.length;}
    function historyAt(uint256 i) external view returns(uint256){return _history[i];}
    function riskState() external view returns(bool,uint64,uint256,uint256,uint256){return(riskLatched,_riskDay,_dayCapital,_dayLossStart,peakStrategyCapital);}
    function terminationReady() external view returns(bool){return _unclosedRunCount==0;}
    function _syncRisk() private {uint256 sc=IKernelSettlementR4(kernel).strategyCapital();uint256 losses=IKernelSettlementR4(kernel).cumulativeRealizedLoss();uint64 day=uint64(block.timestamp/1 days);if(!_riskInitialized||day!=_riskDay){_riskInitialized=true;_riskDay=day;_dayCapital=sc;_dayLossStart=losses;}if(sc>peakStrategyCapital)peakStrategyCapital=sc;uint256 dl=losses>=_dayLossStart?losses-_dayLossStart:0;uint256 dd=peakStrategyCapital>sc?peakStrategyCapital-sc:0;if((_dayCapital!=0&&dl*10_000>=_dayCapital*500)||(peakStrategyCapital!=0&&dd*10_000>=peakStrategyCapital*1_000)){riskLatched=true;emit RiskBreakerLatched(dl,_dayCapital,dd,peakStrategyCapital);}}
    function _checkExecutor() private view {if(_hash(strategyExecutor)!=executorHash||IKernelSettlementR4(kernel).strategyExecutor()!=strategyExecutor||IKernelSettlementR4(kernel).strategyExecutorHash()!=executorHash)revert ChangedCode();}
    function _hash(address a) private view returns(bytes32 h){assembly{h:=extcodehash(a)}}
    function _automation() private pure returns(address){return 0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;}
    function _guardian() private pure returns(address){return 0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;}
}
