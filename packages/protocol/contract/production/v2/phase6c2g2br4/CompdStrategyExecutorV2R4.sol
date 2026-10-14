// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {C2G2BTypes as T, IC2G2BStrategyAdapterR4} from "./C2G2BTypes.sol";

/// @notice Immutable typed dispatcher for the R4 strategy-executor architecture prototype.
/// @dev This contract is not a production allowlist or a real DeFi integration.
contract CompdStrategyExecutorV2R4 {
    struct Run {
        address adapter;
        bytes32 adapterCodeHash;
        bytes32 allocationId;
        bytes32 positionId;
        bytes32 exitId;
        bytes32 closeId;
        uint256 principal;
        uint256 maxDesignedLoss;
        uint256 physicalRecovered;
        uint32 collectionAttempts;
        T.StrategyRunState state;
    }

    address public immutable kernel;
    address[] private _adapters;
    mapping(address => bytes32) public adapterCodeHash;
    mapping(address => bool) private _approved;
    mapping(uint256 => Run) private _runs;
    mapping(uint256 => mapping(bytes32 => bool)) public attemptUsed;
    mapping(uint256 => mapping(bytes32 => bool)) public recoveryUsed;
    mapping(uint256 => bool) private _runUsed;
    mapping(bytes32 => bool) private _allocationUsed;
    bool private _entered;

    error Unauthorized();
    error InvalidRun();
    error Replay();
    error ChangedCode();
    error InvalidAdapterResponse();
    error TransferFailed();

    event RunOpened(uint256 indexed runId,address indexed adapter,bytes32 indexed allocationId,uint256 principal,uint256 maxDesignedLoss,bytes32 positionId);
    event ExitRequested(uint256 indexed runId,bytes32 indexed exitId,T.StrategyRunState state);
    event CollectionAttempt(uint256 indexed runId,bytes32 indexed attemptId,uint32 attemptNumber,uint256 physicalBNB,T.StrategyRunState state);
    event CollectionMetadataMismatch(uint256 indexed runId,bytes32 indexed attemptId,uint256 reported,uint256 physical);
    event RunBlocked(uint256 indexed runId,bytes32 indexed evidence);
    event RunClosed(uint256 indexed runId,bytes32 indexed closeId,uint256 physicalTerminalBNB);

    modifier onlyKernel() { if (msg.sender != kernel) revert Unauthorized(); _; }
    modifier lock() { if (_entered) revert Unauthorized(); _entered = true; _; _entered = false; }

    receive() external payable {
        if (!_approved[msg.sender] || _codeHash(msg.sender) != adapterCodeHash[msg.sender]) revert Unauthorized();
    }

    constructor(address kernel_,address[] memory adapters_) {
        if (kernel_ == address(0) || adapters_.length == 0 || adapters_.length > 16) revert Unauthorized();
        kernel = kernel_;
        for (uint256 i; i < adapters_.length; ++i) {
            address adapter = adapters_[i];
            if (adapter.code.length == 0 || _approved[adapter]) revert InvalidRun();
            bytes32 h = _codeHash(adapter);
            if (h == bytes32(0)) revert InvalidRun();
            _approved[adapter] = true;
            adapterCodeHash[adapter] = h;
            _adapters.push(adapter);
        }
    }

    function adapterCount() external view returns (uint256) { return _adapters.length; }
    function adapterAt(uint256 index) external view returns (address adapter,bytes32 codeHash) {
        adapter = _adapters[index]; codeHash = adapterCodeHash[adapter];
    }
    function isApprovedStrategy(address adapter) external view returns (bool) {
        return _approved[adapter] && _codeHash(adapter) == adapterCodeHash[adapter];
    }

    function openRun(uint256 runId,address adapter,uint256 amount,uint256 maxDesignedLoss,bytes32 allocationId)
        external payable onlyKernel lock returns (bytes32 positionId)
    {
        if (runId == 0 || amount == 0 || allocationId == bytes32(0) || msg.value != amount || _runUsed[runId] || _allocationUsed[allocationId]) revert InvalidRun();
        _checkAdapter(adapter);
        _runUsed[runId] = true; _allocationUsed[allocationId] = true;
        Run storage r = _runs[runId];
        r.adapter = adapter; r.adapterCodeHash = adapterCodeHash[adapter]; r.allocationId = allocationId;
        r.principal = amount; r.maxDesignedLoss = maxDesignedLoss; r.state = T.StrategyRunState.OPEN;
        uint256 beforeBalance = address(this).balance - msg.value;
        positionId = IC2G2BStrategyAdapterR4(adapter).open{value: amount}(runId,allocationId,amount,maxDesignedLoss);
        if (positionId == bytes32(0) || address(this).balance != beforeBalance) revert InvalidAdapterResponse();
        r.positionId = positionId;
        emit RunOpened(runId,adapter,allocationId,amount,maxDesignedLoss,positionId);
    }

    function requestExit(uint256 runId,bytes32 exitId) external onlyKernel lock returns (T.RunStatus) {
        Run storage r = _runs[runId]; _checkRun(r);
        if (exitId == bytes32(0) || r.state == T.StrategyRunState.CLOSED) revert InvalidRun();
        if (r.exitId != bytes32(0) && r.exitId != exitId) revert Replay();
        r.exitId = exitId;
        try IC2G2BStrategyAdapterR4(r.adapter).requestExit(r.positionId,exitId) returns (T.AdapterPositionStatus status) {
            if (status == T.AdapterPositionStatus.EXIT_REQUESTED) r.state = T.StrategyRunState.EXIT_REQUESTED;
            else if (status == T.AdapterPositionStatus.RETURN_PENDING) r.state = T.StrategyRunState.RETURN_PENDING;
            else if (status == T.AdapterPositionStatus.OPEN) r.state = T.StrategyRunState.BLOCKED;
            else revert InvalidAdapterResponse();
        } catch {
            r.state = T.StrategyRunState.BLOCKED;
            emit RunBlocked(runId,keccak256("EXIT_ATTEMPT_FAILED"));
        }
        emit ExitRequested(runId,exitId,r.state);
        return _asModuleStatus(r.state);
    }

    function collectPartial(uint256 runId,bytes32 attemptId,uint256 maxPrincipal) external onlyKernel lock returns (uint256 physicalForwarded) {
        Run storage r = _runs[runId]; _checkRun(r);
        if (attemptId == bytes32(0) || attemptUsed[runId][attemptId] || maxPrincipal == 0 || maxPrincipal > r.principal - r.physicalRecovered || r.exitId == bytes32(0) || r.state == T.StrategyRunState.CLOSED) revert Replay();
        attemptUsed[runId][attemptId] = true;
        uint32 number = ++r.collectionAttempts;
        uint256 beforeBalance = address(this).balance;
        bytes32 recoveryId;
        uint256 reportedAmount;
        try IC2G2BStrategyAdapterR4(r.adapter).collect(r.positionId,attemptId,maxPrincipal) returns (uint256 reported,bytes32 id) {
            reportedAmount = reported; recoveryId = id;
        } catch {
            r.state = T.StrategyRunState.BLOCKED;
            emit CollectionAttempt(runId,attemptId,number,0,r.state);
            emit RunBlocked(runId,keccak256("COLLECTION_ATTEMPT_FAILED"));
            return 0;
        }
        uint256 physical = address(this).balance - beforeBalance;
        if (physical > maxPrincipal || (physical != 0 && (recoveryId == bytes32(0) || recoveryUsed[runId][recoveryId]))) revert InvalidAdapterResponse();
        if (physical != 0) { recoveryUsed[runId][recoveryId] = true; r.physicalRecovered += physical; }
        if (reportedAmount != physical) emit CollectionMetadataMismatch(runId,attemptId,reportedAmount,physical);
        if (physical != 0) _sendKernel(physical);
        if (physical != 0) r.state = T.StrategyRunState.PARTIALLY_RECOVERED;
        else if (r.state != T.StrategyRunState.BLOCKED) r.state = T.StrategyRunState.RETURN_PENDING;
        emit CollectionAttempt(runId,attemptId,number,physical,r.state);
        return physical;
    }

    function closeToKernel(uint256 runId,bytes32 closeId) external onlyKernel lock returns (uint256 principal,uint256 reportedReturn,bytes32 canonicalCloseId) {
        Run storage r = _runs[runId]; _checkRun(r);
        if (closeId == bytes32(0) || r.closeId != bytes32(0) || r.exitId == bytes32(0) || r.state == T.StrategyRunState.OPEN || r.state == T.StrategyRunState.CLOSED) revert InvalidRun();
        r.closeId = closeId;
        uint256 beforeBalance = address(this).balance;
        bytes32 closedPosition = IC2G2BStrategyAdapterR4(r.adapter).close(r.positionId,closeId);
        if (closedPosition != r.positionId) revert InvalidAdapterResponse();
        uint256 physical = address(this).balance - beforeBalance;
        _sendKernel(physical);
        r.state = T.StrategyRunState.CLOSED;
        principal = r.principal; reportedReturn = physical; canonicalCloseId = closeId;
        emit RunClosed(runId,closeId,physical);
    }

    function observe(uint256 runId) external view returns (T.AdapterPositionStatus status,uint256 reportedRecoverable,bytes32 pendingClaimId) {
        Run storage r = _runs[runId]; _checkRunView(r);
        return IC2G2BStrategyAdapterR4(r.adapter).observe(r.positionId);
    }
    function runState(uint256 runId) external view returns (T.StrategyRunState) { return _runs[runId].state; }
    function positionId(uint256 runId) external view returns (bytes32) { return _runs[runId].positionId; }
    function runInfo(uint256 runId) external view returns(address adapter,bytes32 adapterHash,bytes32 allocationId,bytes32 positionId_,bytes32 exitId,bytes32 closeId,uint256 principal,uint256 maxLoss,uint256 recovered,uint32 attempts,T.StrategyRunState state){Run storage r=_runs[runId];return(r.adapter,r.adapterCodeHash,r.allocationId,r.positionId,r.exitId,r.closeId,r.principal,r.maxDesignedLoss,r.physicalRecovered,r.collectionAttempts,r.state);}

    function _sendKernel(uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = payable(kernel).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
    function _asModuleStatus(T.StrategyRunState state) private pure returns (T.RunStatus) {
        if (state == T.StrategyRunState.OPEN) return T.RunStatus.OPEN;
        if (state == T.StrategyRunState.EXIT_REQUESTED) return T.RunStatus.EXIT_REQUESTED;
        if (state == T.StrategyRunState.RETURN_PENDING) return T.RunStatus.RETURN_PENDING;
        if (state == T.StrategyRunState.PARTIALLY_RECOVERED) return T.RunStatus.PARTIALLY_RECOVERED;
        return T.RunStatus.BLOCKED;
    }
    function _checkRun(Run storage r) private view { _checkAdapter(r.adapter); if (r.principal == 0) revert InvalidRun(); }
    function _checkRunView(Run storage r) private view { _checkAdapter(r.adapter); if (r.principal == 0) revert InvalidRun(); }
    function _checkAdapter(address adapter) private view { if (!_approved[adapter] || adapter.code.length == 0 || _codeHash(adapter) != adapterCodeHash[adapter]) revert ChangedCode(); }
    function _codeHash(address a) private view returns (bytes32 h) { assembly { h := extcodehash(a) } }
}
