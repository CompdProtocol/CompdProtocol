// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {CompdV2Types, CompdV2Errors, CompdV2KnownRoles} from "./CompdV2Types.sol";
import {ICompdEmergencyVaultV2} from "./ICompdEmergencyVaultV2.sol";
import {ICompdHolderRewardsDistributorV2} from "./ICompdHolderRewardsDistributorV2.sol";

/// @notice Fresh V2 domain/workflow identity scaffold; no proof, materialization or payment is implemented.
contract CompdHolderRewardsDistributorV2 is ICompdHolderRewardsDistributorV2 {
    address public immutable override vault;
    address public immutable distributionFinalizer;
    bytes32 public constant PROTOCOL_ID = keccak256("COMPD_HOLDER_REWARDS_V2");
    uint64 public constant REVIEW_SECONDS = 1_800;
    uint16 public constant MAX_RECIPIENTS = 30;

    constructor(address vault_, address finalizer_) {
        if (vault_.code.length == 0 || finalizer_ == address(0)) revert CompdV2Errors.InvalidImmutableConfiguration();
        ICompdEmergencyVaultV2 vaultInterface = ICompdEmergencyVaultV2(vault_);
        try vaultInterface.lifecycle() returns (CompdV2Types.Lifecycle) { }
        catch { revert CompdV2Errors.InvalidImmutableConfiguration(); }
        if (
            finalizer_ == vaultInterface.emergencyRecoveryAuthority()
                || finalizer_ == vaultInterface.emergencyRecoveryWallet()
                || finalizer_ == CompdV2KnownRoles.GUARDIAN
                || finalizer_ == CompdV2KnownRoles.RECOVERY_TREASURY
                || finalizer_ == CompdV2KnownRoles.AUTOMATION_EXECUTOR
                || finalizer_ == CompdV2KnownRoles.RESERVED_COMPD_IDENTITY
                || finalizer_ == CompdV2KnownRoles.BUYBACK_ADMIN
                || finalizer_ == CompdV2KnownRoles.DEV_CREATOR
        ) revert CompdV2Errors.InvalidImmutableConfiguration();
        vault = vault_;
        distributionFinalizer = finalizer_;
    }

    function domainSeparator() external view override returns (bytes32) {
        return _domainSeparator();
    }
    function windowId(uint64 windowStart, uint64 windowEnd) external view override returns (bytes32) {
        return keccak256(abi.encode(_domainSeparator(), windowStart, windowEnd));
    }
    function distributionId(bytes32 windowId_) external view override returns (bytes32) {
        return keccak256(abi.encode(PROTOCOL_ID, address(this), windowId_));
    }
    function emergencyLifecycle() external view override returns (CompdV2Types.Lifecycle) {
        return ICompdEmergencyVaultV2(vault).lifecycle();
    }
    function _domainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(PROTOCOL_ID, block.chainid, address(this), vault));
    }
    function candidate(bytes32) external pure override returns (CommitmentView memory) { revert CompdV2Errors.ImplementationDeferred(); }
    function emptyCandidate(bytes32) external pure override returns (EmptyCandidateView memory) { revert CompdV2Errors.ImplementationDeferred(); }
    function submitCandidate(NormalCandidate calldata) external pure override { revert CompdV2Errors.ImplementationDeferred(); }
    function correctCandidate(bytes32, NormalReplacement calldata) external pure override { revert CompdV2Errors.ImplementationDeferred(); }
    function materializeLeaf(bytes32, Leaf calldata, bytes32[] calldata) external pure override {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function finalizeCandidate(bytes32) external pure override { revert CompdV2Errors.ImplementationDeferred(); }
    function executeProof(bytes32, Leaf calldata, bytes32[] calldata) external pure override returns (bool) {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function submitEmptyCandidate(EmptyCandidate calldata) external pure override { revert CompdV2Errors.ImplementationDeferred(); }
    function correctEmptyCandidate(bytes32, EmptyReplacement calldata) external pure override {
        revert CompdV2Errors.ImplementationDeferred();
    }
    function finalizeEmptyCandidate(bytes32) external pure override { revert CompdV2Errors.ImplementationDeferred(); }
    function startTerminalLiability(bytes32, uint16) external pure override { revert CompdV2Errors.ImplementationDeferred(); }
    function rootByVersion(bytes32, uint32) external pure override returns (bytes32) { revert CompdV2Errors.ImplementationDeferred(); }
    function datasetHashByVersion(bytes32, uint32) external pure override returns (bytes32) { revert CompdV2Errors.ImplementationDeferred(); }
    function commitmentHashByVersion(bytes32, uint32) external pure override returns (bytes32) { revert CompdV2Errors.ImplementationDeferred(); }
    function correctionReasonHashByVersion(bytes32, uint32) external pure override returns (bytes32) { revert CompdV2Errors.ImplementationDeferred(); }
    function materializedLeafHash(bytes32, uint32, uint16) external pure override returns (bytes32) { revert CompdV2Errors.ImplementationDeferred(); }
    function hashLeaf(Leaf calldata) external pure override returns (bytes32) { revert CompdV2Errors.ImplementationDeferred(); }
    function hashPadding(bytes32, bytes32, uint32, uint16) external pure override returns (bytes32) { revert CompdV2Errors.ImplementationDeferred(); }
    function hashEmptyCommitment(EmptyCandidate calldata) external pure override returns (bytes32) { revert CompdV2Errors.ImplementationDeferred(); }
    function hashNode(bytes32, bytes32) external pure override returns (bytes32) { revert CompdV2Errors.ImplementationDeferred(); }
    function paymentStatus(bytes32, uint32, uint16) external pure override returns (bool, bool, bool) {
        revert CompdV2Errors.ImplementationDeferred();
    }
}
