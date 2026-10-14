// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {C2G2BTypes as T, IC2G2BStrategyAdapterR4} from "../../contracts/production/v2/phase6c2g2br4/C2G2BTypes.sol";

/// @notice Deterministic test-only adapter. Never a production strategy or allowlist candidate.
contract ReferenceStrategyAdapterR4 is IC2G2BStrategyAdapterR4 {
    struct Position {
        address executor;
        uint256 runId;
        uint256 principal;
        uint256 cash;
        uint256 maxDesignedLoss;
        bytes32 allocationId;
        bytes32 exitId;
        T.AdapterPositionStatus status;
        bool terminalReady;
        bool closed;
        bool failExit;
        bool failCollect;
        bool failClose;
        bool mismatchPosition;
        bool overrideReport;
        bool collectionConfigured;
        uint256 reportedAmount;
        uint256 nextCollection;
        bytes32 forcedRecoveryId;
        bool overrideRecoveryId;
        uint256 openRequestCount;
        uint256 exitRequestCount;
        uint256 closeCount;
        mapping(bytes32 => bool) attempts;
    }

    mapping(bytes32 => Position) private _positions;
    mapping(address => mapping(uint256 => bytes32)) private _positionOf;
    mapping(bytes32 => bool) private _usedAllocation;
    mapping(bytes32 => bool) private _usedRecoveryId;
    address private _reentryTarget; bytes private _reentryData; bool public reentryAttempted; bool public reentrySucceeded;

    error Unauthorized(); error InvalidPosition(); error Replay(); error SimulatedFailure(); error TransferFailed();
    event Opened(address indexed executor,uint256 indexed runId,bytes32 indexed positionId,uint256 principal);
    event ExitObserved(bytes32 indexed positionId,bytes32 indexed exitId,T.AdapterPositionStatus status);
    event Collected(bytes32 indexed positionId,bytes32 indexed attemptId,uint256 physicalAmount);
    event Closed(bytes32 indexed positionId,bytes32 indexed closeId,uint256 physicalAmount);

    function open(uint256 runId,bytes32 allocationId,uint256 principal,uint256 maxDesignedLoss) external payable returns (bytes32 positionId) {
        if (runId == 0 || allocationId == bytes32(0) || principal == 0 || msg.value != principal || _positionOf[msg.sender][runId] != bytes32(0) || _usedAllocation[allocationId]) revert InvalidPosition();
        positionId = keccak256(abi.encode(address(this),msg.sender,runId,allocationId));
        Position storage p = _positions[positionId];
        p.executor = msg.sender; p.runId = runId; p.principal = principal; p.cash=principal; p.maxDesignedLoss = maxDesignedLoss;
        p.allocationId = allocationId; p.status = T.AdapterPositionStatus.OPEN; p.openRequestCount = 1;
        _positionOf[msg.sender][runId] = positionId; _usedAllocation[allocationId] = true;
        emit Opened(msg.sender,runId,positionId,principal);
    }

    function requestExit(bytes32 positionId,bytes32 exitId) external returns (T.AdapterPositionStatus) {
        Position storage p = _get(positionId);
        if (p.executor != msg.sender || exitId == bytes32(0) || p.closed) revert Unauthorized();
        if (p.exitId != bytes32(0) && p.exitId != exitId) revert Replay();
        if (p.failExit) revert SimulatedFailure();
        if (p.exitId == bytes32(0)) { p.exitId = exitId; p.exitRequestCount++; p.status = T.AdapterPositionStatus.RETURN_PENDING; }
        emit ExitObserved(positionId,exitId,p.status);
        return p.status;
    }

    function observe(bytes32 positionId) external view returns (T.AdapterPositionStatus status,uint256 reportedRecoverable,bytes32 pendingClaimId) {
        Position storage p = _getView(positionId);
        return (p.status,address(this).balance, p.exitId);
    }

    function collect(bytes32 positionId,bytes32 attemptId,uint256 maxPrincipal) external returns (uint256 reportedAmount,bytes32 recoveryId) {
        Position storage p = _get(positionId);
        if (p.executor != msg.sender || p.exitId == bytes32(0) || p.closed || attemptId == bytes32(0) || maxPrincipal == 0 || p.attempts[attemptId]) revert Unauthorized();
        p.attempts[attemptId] = true;
        if (p.failCollect) revert SimulatedFailure();
        if (_reentryTarget != address(0)) { reentryAttempted=true;(reentrySucceeded,)=_reentryTarget.call(_reentryData); }
        uint256 requested = p.collectionConfigured ? p.nextCollection : maxPrincipal;
        uint256 physical = requested;
        if (physical > maxPrincipal) physical = maxPrincipal;
        if (physical > p.cash) physical = p.cash;
        if (physical > address(this).balance) physical = address(this).balance;
        if (physical != 0) {
            (bool ok,) = payable(msg.sender).call{value: physical}("");
            if (!ok) revert TransferFailed();
            p.cash-=physical;
        }
        recoveryId = p.overrideRecoveryId ? p.forcedRecoveryId : keccak256(abi.encode(positionId,attemptId));
        if (_usedRecoveryId[recoveryId]) revert Replay();
        _usedRecoveryId[recoveryId] = true;
        reportedAmount = p.overrideReport ? p.reportedAmount : physical;
        emit Collected(positionId,attemptId,physical);
    }

    function close(bytes32 positionId,bytes32 closeId) external returns (bytes32 closedPositionId) {
        Position storage p = _get(positionId);
        if (p.executor != msg.sender || p.closed || closeId == bytes32(0)) revert Unauthorized();
        if (p.failClose || !p.terminalReady) revert SimulatedFailure();
        p.closed = true; p.status = T.AdapterPositionStatus.CLOSED; p.closeCount++;
        uint256 amount = p.cash;
        if (amount > address(this).balance) revert TransferFailed();
        if (amount != 0) {
            (bool ok,) = payable(msg.sender).call{value: amount}("");
            if (!ok) revert TransferFailed();
            p.cash=0;
        }
        closedPositionId = p.mismatchPosition ? keccak256(abi.encode(positionId,"wrong")) : positionId;
        emit Closed(positionId,closeId,amount);
    }

    // Test controls. This contract is deliberately not suitable for production.
    function configureFor(bytes32 positionId,bool failExit,bool failCollect,bool failClose,bool terminalReady,uint256 nextCollection,bool overrideReport,uint256 reportedAmount,bool mismatchPosition) external {
        Position storage p = _get(positionId); p.failExit=failExit; p.failCollect=failCollect; p.failClose=failClose;
        p.terminalReady=terminalReady; p.nextCollection=nextCollection; p.overrideReport=overrideReport;
        p.reportedAmount=reportedAmount; p.mismatchPosition=mismatchPosition;
    }
    function setTerminal(bytes32 positionId,bool ready) external { _get(positionId).terminalReady = ready; }
    function setCash(bytes32 positionId,uint256 amount) external { _get(positionId).cash = amount; }
    function setExitFailure(bytes32 positionId,bool fail) external { _get(positionId).failExit = fail; }
    function setCollectFailure(bytes32 positionId,bool fail) external { _get(positionId).failCollect = fail; }
    function setCloseFailure(bytes32 positionId,bool fail) external { _get(positionId).failClose = fail; }
    function setNextCollection(bytes32 positionId,uint256 amount) external { Position storage p=_get(positionId);p.nextCollection=amount;p.collectionConfigured=true; }
    function setRecoveryId(bytes32 positionId,bytes32 recoveryId,bool enabled) external { Position storage p=_get(positionId);p.forcedRecoveryId=recoveryId;p.overrideRecoveryId=enabled; }
    function configureReentry(address target,bytes calldata data) external { _reentryTarget=target;_reentryData=data;reentryAttempted=false;reentrySucceeded=false; }
    function setReport(bytes32 positionId,uint256 amount,bool enabled) external { Position storage p=_get(positionId); p.reportedAmount=amount; p.overrideReport=enabled; }
    function forcePositionMismatch(bytes32 positionId,bool enabled) external { _get(positionId).mismatchPosition=enabled; }
    function setObservedStatus(bytes32 positionId,T.AdapterPositionStatus status) external { _get(positionId).status=status; }
    function position(bytes32 id) external view returns (address executor,uint256 runId,uint256 principal,uint256 maxDesignedLoss,bytes32 allocationId,bytes32 exitId,T.AdapterPositionStatus status,bool terminalReady,bool closed,uint256 openRequests,uint256 exitRequests,uint256 closes) {
        Position storage p=_positions[id]; return(p.executor,p.runId,p.principal,p.maxDesignedLoss,p.allocationId,p.exitId,p.status,p.terminalReady,p.closed,p.openRequestCount,p.exitRequestCount,p.closeCount);
    }
    function positionId(address executor,uint256 runId) external view returns(bytes32) { return _positionOf[executor][runId]; }
    function _get(bytes32 id) private view returns(Position storage p) { p=_positions[id]; if(p.executor==address(0)) revert InvalidPosition(); }
    function _getView(bytes32 id) private view returns(Position storage p) { p=_positions[id]; if(p.executor==address(0)) revert InvalidPosition(); }
    receive() external payable {}
}
