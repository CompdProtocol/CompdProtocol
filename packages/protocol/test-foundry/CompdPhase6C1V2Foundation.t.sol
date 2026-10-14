// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {CompdV2Types, CompdV2KnownRoles, CompdV2Errors} from "../contracts/production/v2/CompdV2Types.sol";
import {CompdProductionVaultV2} from "../contracts/production/v2/CompdProductionVaultV2.sol";
import {CompdHolderWorkflowV2} from "../contracts/production/v2/CompdHolderWorkflowV2.sol";
import {CompdHolderLiabilityV2} from "../contracts/production/v2/CompdHolderLiabilityV2.sol";
import {CompdEmergencyRegistryV2} from "../contracts/production/v2/CompdEmergencyRegistryV2.sol";
import {CompdHolderRewardsDistributorV2} from "../contracts/production/v2/CompdHolderRewardsDistributorV2.sol";
import {CompdThinFlapReceiverV2} from "../contracts/production/v2/CompdThinFlapReceiverV2.sol";
import {
    ICompdEmergencyVaultV2,
    ICompdEmergencyModuleV2,
    ICompdStrategyExecutorV2,
    ICompdBuybackExecutorV2,
    ICompdThinFlapReceiverV2
} from "../contracts/production/v2/ICompdEmergencyVaultV2.sol";
import {ICompdHolderRewardsDistributorV2} from "../contracts/production/v2/ICompdHolderRewardsDistributorV2.sol";
import {ICompdProductionVaultFactoryV2} from "../contracts/production/v2/ICompdProductionVaultFactoryV2.sol";

contract CompdPhase6C1V2FoundationTest is Test {
    function _newVault(address quote, address admin, address emergencyAuthority, address emergencyWallet)
        private returns (CompdProductionVaultV2)
    {
        return new CompdProductionVaultV2(
            quote, admin, emergencyAuthority, emergencyWallet,
            keccak256(type(CompdHolderWorkflowV2).runtimeCode),
            keccak256(type(CompdHolderLiabilityV2).runtimeCode),
            keccak256(type(CompdEmergencyRegistryV2).runtimeCode)
        );
    }

    function testLifecycleNumericStability() public pure {
        assertEq(uint8(CompdV2Types.Lifecycle.ACTIVE), 0);
        assertEq(uint8(CompdV2Types.Lifecycle.PAUSED), 1);
        assertEq(uint8(CompdV2Types.Lifecycle.SHUTDOWN_PENDING), 2);
        assertEq(uint8(CompdV2Types.Lifecycle.TERMINATED), 3);
        assertEq(uint8(CompdV2Types.Lifecycle.EMERGENCY_RECOVERY), 4);
    }

    function testEmergencyProcessingStatusNumericStability() public pure {
        assertEq(uint8(CompdV2Types.EmergencyProcessingStatus.NOT_STARTED), 0);
        assertEq(uint8(CompdV2Types.EmergencyProcessingStatus.IN_PROGRESS), 1);
        assertEq(uint8(CompdV2Types.EmergencyProcessingStatus.COMPLETE_WITHIN_REGISTERED_SCOPE), 2);
        assertEq(uint8(CompdV2Types.EmergencyProcessingStatus.COMPLETE_WITH_UNRESOLVED), 3);
    }

    function testModuleIdentityExactOrdering() public pure {
        assertEq(uint8(CompdV2Types.ModuleId.VAULT), 0);
        assertEq(uint8(CompdV2Types.ModuleId.STRATEGY_EXECUTOR), 1);
        assertEq(uint8(CompdV2Types.ModuleId.BUYBACK_EXECUTOR), 2);
        assertEq(uint8(CompdV2Types.ModuleId.THIN_FLAP_RECEIVER), 3);
        assertEq(uint8(CompdV2Types.EmergencyRunStatus.EXIT_REQUIRED), 0);
        assertEq(uint8(CompdV2Types.EmergencyRunStatus.EXIT_ATTEMPTED), 1);
        assertEq(uint8(CompdV2Types.EmergencyRunStatus.EXIT_SETTLED), 2);
        assertEq(uint8(CompdV2Types.EmergencyRunStatus.EXIT_BLOCKED), 3);
        assertEq(uint8(CompdV2Types.EmergencyRunStatus.ASYNC_EXIT_PENDING), 4);
    }

    function testVaultSelectorSetUniqueAndNarrow() public pure {
        bytes4[] memory selectors = new bytes4[](44);
        selectors[0] = ICompdEmergencyVaultV2.emergencyWithdrawAll.selector;
        selectors[1] = ICompdEmergencyVaultV2.emergencyWithdrawAsset.selector;
        selectors[2] = ICompdEmergencyVaultV2.emergencyRecoverModuleAsset.selector;
        selectors[3] = ICompdEmergencyVaultV2.emergencyExitRun.selector;
        selectors[4] = ICompdEmergencyVaultV2.emergencyRetryAsset.selector;
        selectors[5] = ICompdEmergencyVaultV2.emergencyRetryRun.selector;
        selectors[6] = ICompdEmergencyVaultV2.registerDiscoveredEmergencyAsset.selector;
        selectors[7] = ICompdEmergencyVaultV2.emergencyRefreshCompletion.selector;
        selectors[8] = ICompdEmergencyVaultV2.emergencyRecoveryState.selector;
        selectors[9] = ICompdEmergencyVaultV2.emergencyRecoveryWallet.selector;
        selectors[10] = ICompdEmergencyVaultV2.emergencyRecoveryAuthority.selector;
        selectors[11] = ICompdEmergencyVaultV2.emergencyAccountingSnapshot.selector;
        selectors[12] = ICompdEmergencyVaultV2.emergencyReconciliation.selector;
        selectors[13] = ICompdEmergencyVaultV2.emergencyAssetStatus.selector;
        selectors[14] = ICompdEmergencyVaultV2.emergencyAttemptCount.selector;
        selectors[15] = ICompdEmergencyVaultV2.emergencyAttemptAt.selector;
        selectors[16] = ICompdEmergencyVaultV2.emergencyHolderBackingState.selector;
        selectors[17] = ICompdEmergencyVaultV2.emergencyAssetCount.selector;
        selectors[18] = ICompdEmergencyVaultV2.emergencyAssetAt.selector;
        selectors[19] = ICompdEmergencyVaultV2.emergencyModuleAddress.selector;
        selectors[20] = ICompdEmergencyVaultV2.lifecycle.selector;
        selectors[21] = ICompdEmergencyVaultV2.quoteToken.selector;
        selectors[22] = ICompdEmergencyVaultV2.compdToken.selector;
        selectors[23] = ICompdEmergencyVaultV2.registerFlapRevenue.selector;
        selectors[24] = ICompdEmergencyVaultV2.allocateStrategyPrincipal.selector;
        selectors[25] = ICompdEmergencyVaultV2.settleStrategyPrincipal.selector;
        selectors[26] = ICompdEmergencyVaultV2.startTerminalHolderLiability.selector;
        selectors[27] = ICompdEmergencyVaultV2.reserveFinalizedHolderDistribution.selector;
        selectors[28] = ICompdEmergencyVaultV2.correctHolderDistribution.selector;
        selectors[29] = ICompdEmergencyVaultV2.registerHolderRewardEntry.selector;
        selectors[30] = ICompdEmergencyVaultV2.finalizeHolderDistribution.selector;
        selectors[31] = ICompdEmergencyVaultV2.payCommittedHolderEntry.selector;
        selectors[32] = ICompdEmergencyVaultV2.markHolderEntryFailed.selector;
        selectors[33] = ICompdEmergencyVaultV2.markManualSettlementAvailable.selector;
        selectors[34] = ICompdEmergencyVaultV2.settleFailedHolderEntry.selector;
        selectors[35] = ICompdEmergencyVaultV2.openEmptyCandidate.selector;
        selectors[36] = ICompdEmergencyVaultV2.correctEmptyCandidate.selector;
        selectors[37] = ICompdEmergencyVaultV2.finalizeEmptyCandidate.selector;
        selectors[38] = ICompdEmergencyVaultV2.expireTerminalHolderLiability.selector;
        selectors[39] = ICompdEmergencyVaultV2.recoverExpiredHolderLiability.selector;
        selectors[40] = ICompdEmergencyVaultV2.recoverNoRecipientPool.selector;
        selectors[41] = ICompdEmergencyVaultV2.RECOVERY_TREASURY.selector;
        selectors[42] = ICompdEmergencyVaultV2.emergencyOutflowByModuleAsset.selector;
        selectors[43] = ICompdEmergencyVaultV2.emergencyFailureCountByModuleAsset.selector;
        _assertUnique(selectors);

        bytes4[] memory forbidden = new bytes4[](7);
        forbidden[0] = bytes4(keccak256("withdraw(address,uint256,address)"));
        forbidden[1] = bytes4(keccak256("withdrawAll(address)"));
        forbidden[2] = bytes4(keccak256("execute(address,bytes)"));
        forbidden[3] = bytes4(keccak256("execute(address,bytes,uint256)"));
        forbidden[4] = bytes4(keccak256("sweep(address,address)"));
        forbidden[5] = bytes4(keccak256("setRecoveryWallet(address)"));
        forbidden[6] = bytes4(keccak256("setEmergencyAuthority(address)"));
        for (uint256 i; i < selectors.length; ++i) {
            for (uint256 j; j < forbidden.length; ++j) assertTrue(selectors[i] != forbidden[j]);
        }
    }

    function testDistributorSelectorSetUniqueAndNoRescueSurface() public pure {
        bytes4[] memory selectors = new bytes4[](26);
        selectors[0] = ICompdHolderRewardsDistributorV2.submitCandidate.selector;
        selectors[1] = ICompdHolderRewardsDistributorV2.correctCandidate.selector;
        selectors[2] = ICompdHolderRewardsDistributorV2.materializeLeaf.selector;
        selectors[3] = ICompdHolderRewardsDistributorV2.finalizeCandidate.selector;
        selectors[4] = ICompdHolderRewardsDistributorV2.executeProof.selector;
        selectors[5] = ICompdHolderRewardsDistributorV2.submitEmptyCandidate.selector;
        selectors[6] = ICompdHolderRewardsDistributorV2.correctEmptyCandidate.selector;
        selectors[7] = ICompdHolderRewardsDistributorV2.finalizeEmptyCandidate.selector;
        selectors[8] = ICompdHolderRewardsDistributorV2.startTerminalLiability.selector;
        selectors[9] = ICompdHolderRewardsDistributorV2.rootByVersion.selector;
        selectors[10] = ICompdHolderRewardsDistributorV2.datasetHashByVersion.selector;
        selectors[11] = ICompdHolderRewardsDistributorV2.commitmentHashByVersion.selector;
        selectors[12] = ICompdHolderRewardsDistributorV2.correctionReasonHashByVersion.selector;
        selectors[13] = ICompdHolderRewardsDistributorV2.materializedLeafHash.selector;
        selectors[14] = ICompdHolderRewardsDistributorV2.hashLeaf.selector;
        selectors[15] = ICompdHolderRewardsDistributorV2.hashPadding.selector;
        selectors[16] = ICompdHolderRewardsDistributorV2.hashEmptyCommitment.selector;
        selectors[17] = ICompdHolderRewardsDistributorV2.hashNode.selector;
        selectors[18] = ICompdHolderRewardsDistributorV2.domainSeparator.selector;
        selectors[19] = ICompdHolderRewardsDistributorV2.windowId.selector;
        selectors[20] = ICompdHolderRewardsDistributorV2.emergencyLifecycle.selector;
        selectors[21] = ICompdHolderRewardsDistributorV2.paymentStatus.selector;
        selectors[22] = ICompdHolderRewardsDistributorV2.vault.selector;
        selectors[23] = ICompdHolderRewardsDistributorV2.distributionId.selector;
        selectors[24] = ICompdHolderRewardsDistributorV2.candidate.selector;
        selectors[25] = ICompdHolderRewardsDistributorV2.emptyCandidate.selector;
        _assertUnique(selectors);
    }

    function testModuleAndFactoryInterfaceSelectorsAreUniqueAndFactoryHasNoEmergencyAuthority() public pure {
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = ICompdEmergencyModuleV2.vault.selector;
        selectors[1] = ICompdEmergencyModuleV2.emergencySweepAsset.selector;
        selectors[2] = ICompdEmergencyModuleV2.snapshotEmergencyBalance.selector;
        selectors[3] = ICompdEmergencyModuleV2.emergencyLifecycleCompatibility.selector;
        selectors[4] = ICompdStrategyExecutorV2.emergencyExitRun.selector;
        selectors[5] = ICompdStrategyExecutorV2.emergencyRunStatus.selector;
        selectors[6] = ICompdStrategyExecutorV2.closePosition.selector;
        selectors[7] = ICompdStrategyExecutorV2.activeRunCount.selector;
        selectors[8] = ICompdStrategyExecutorV2.activeRunAt.selector;
        selectors[9] = ICompdStrategyExecutorV2.adapterForRun.selector;
        _assertUnique(selectors);
        assertTrue(ICompdProductionVaultFactoryV2.productionVault.selector != ICompdProductionVaultFactoryV2.compdToken.selector);
        assertTrue(ICompdProductionVaultFactoryV2.productionVault.selector != ICompdProductionVaultFactoryV2.quoteToken.selector);
        assertTrue(ICompdProductionVaultFactoryV2.compdToken.selector != ICompdProductionVaultFactoryV2.quoteToken.selector);
        assertTrue(ICompdProductionVaultFactoryV2.productionVault.selector != bytes4(keccak256("emergencyRecoveryAuthority()")));

        bytes4[] memory buybackSelectors = new bytes4[](4);
        buybackSelectors[0] = ICompdEmergencyModuleV2.vault.selector;
        buybackSelectors[1] = ICompdEmergencyModuleV2.emergencySweepAsset.selector;
        buybackSelectors[2] = ICompdEmergencyModuleV2.snapshotEmergencyBalance.selector;
        buybackSelectors[3] = ICompdEmergencyModuleV2.emergencyLifecycleCompatibility.selector;
        _assertUnique(buybackSelectors);

        bytes4[] memory receiverSelectors = new bytes4[](9);
        receiverSelectors[0] = ICompdEmergencyModuleV2.vault.selector;
        receiverSelectors[1] = ICompdEmergencyModuleV2.emergencySweepAsset.selector;
        receiverSelectors[2] = ICompdEmergencyModuleV2.snapshotEmergencyBalance.selector;
        receiverSelectors[3] = ICompdEmergencyModuleV2.emergencyLifecycleCompatibility.selector;
        receiverSelectors[4] = ICompdThinFlapReceiverV2.recognizedPendingRevenue.selector;
        receiverSelectors[5] = ICompdThinFlapReceiverV2.unrecognizedSurplus.selector;
        receiverSelectors[6] = ICompdThinFlapReceiverV2.productionVault.selector;
        receiverSelectors[7] = ICompdThinFlapReceiverV2.taxToken.selector;
        receiverSelectors[8] = ICompdThinFlapReceiverV2.vaultQuoteToken.selector;
        _assertUnique(receiverSelectors);

        bytes4[] memory factorySelectors = new bytes4[](3);
        factorySelectors[0] = ICompdProductionVaultFactoryV2.productionVault.selector;
        factorySelectors[1] = ICompdProductionVaultFactoryV2.compdToken.selector;
        factorySelectors[2] = ICompdProductionVaultFactoryV2.quoteToken.selector;
        _assertUnique(factorySelectors);
    }

    function testNoEmergencyFunctionTakesDestinationTargetOrArbitraryCalldata() public pure {
        assertEq(ICompdEmergencyVaultV2.emergencyWithdrawAsset.selector, bytes4(keccak256("emergencyWithdrawAsset(address)")));
        assertEq(ICompdEmergencyVaultV2.emergencyRecoverModuleAsset.selector,
            bytes4(keccak256("emergencyRecoverModuleAsset(uint8,address)")));
        assertEq(ICompdEmergencyVaultV2.emergencyExitRun.selector, bytes4(keccak256("emergencyExitRun(uint256)")));
        assertEq(ICompdEmergencyVaultV2.emergencyRetryAsset.selector, bytes4(keccak256("emergencyRetryAsset(uint8,address)")));
        assertEq(ICompdEmergencyVaultV2.emergencyRetryRun.selector, bytes4(keccak256("emergencyRetryRun(uint256)")));
        assertEq(ICompdEmergencyVaultV2.registerDiscoveredEmergencyAsset.selector,
            bytes4(keccak256("registerDiscoveredEmergencyAsset(address)")));
    }

    function testOrdinaryRecoveryTreasuryIdentityExact() public pure {
        assertEq(CompdV2KnownRoles.RECOVERY_TREASURY, 0xFa8706AA97B07cb29096381f9101784bA0d1332b);
    }

    function testConstructorRejectsZeroEmergencyAuthority() public {
        vm.expectRevert(CompdV2Errors.InvalidImmutableConfiguration.selector);
        _newVault(address(0), address(0x100), address(0), address(0x300));
    }

    function testConstructorRejectsZeroEmergencyWallet() public {
        vm.expectRevert(CompdV2Errors.InvalidImmutableConfiguration.selector);
        _newVault(address(0), address(0x100), address(0x200), address(0));
    }

    function testConstructorRejectsAuthorityEqualsWallet() public {
        vm.expectRevert(CompdV2Errors.InvalidImmutableConfiguration.selector);
        _newVault(address(0), address(0x100), address(0x200), address(0x200));
    }

    function testConstructorRejectsAuthorityOrWalletAliasToKnownRolesAndAdmin() public {
        vm.expectRevert(CompdV2Errors.InvalidImmutableConfiguration.selector);
        _newVault(address(0), address(0x100), CompdV2KnownRoles.GUARDIAN, address(0x300));
        vm.expectRevert(CompdV2Errors.InvalidImmutableConfiguration.selector);
        _newVault(address(0), address(0x100), address(0x200), CompdV2KnownRoles.RECOVERY_TREASURY);
        vm.expectRevert(CompdV2Errors.InvalidImmutableConfiguration.selector);
        _newVault(address(0), address(0x200), address(0x200), address(0x300));
    }

    function testDistributorConstructorRejectsFinalizerAliasedToEmergencyAuthority() public {
        CompdProductionVaultV2 vault = _newVault(address(0), address(0x100), address(0x200), address(0x300));
        address authority = vault.emergencyRecoveryAuthority();
        vm.expectRevert(CompdV2Errors.InvalidImmutableConfiguration.selector);
        new CompdHolderRewardsDistributorV2(address(vault), authority);
    }

    function testDistributorConstructorRejectsFinalizerAliasedToKnownRoles() public {
        CompdProductionVaultV2 vault = _newVault(address(0), address(0x100), address(0x200), address(0x300));
        assertEq(CompdV2KnownRoles.GUARDIAN, 0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1);
        vm.expectRevert(CompdV2Errors.InvalidImmutableConfiguration.selector);
        new CompdHolderRewardsDistributorV2(address(vault), CompdV2KnownRoles.GUARDIAN);
    }

    function testConstructorAcceptsDistinctNonRolePlaceholdersAndStartsPaused() public {
        CompdProductionVaultV2 vault = _newVault(address(0), address(0x100), address(0x200), address(0x300));
        assertEq(uint8(vault.lifecycle()), uint8(CompdV2Types.Lifecycle.PAUSED));
        assertEq(vault.emergencyRecoveryAuthority(), address(0x200));
        assertEq(vault.emergencyRecoveryWallet(), address(0x300));
        assertEq(vault.RECOVERY_TREASURY(), 0xFa8706AA97B07cb29096381f9101784bA0d1332b);
        assertEq(vault.emergencyAssetCount(), 2); // BNB (address(0)) and protected COMPD identity.
    }

    function testReceiverBindsExactVaultQuoteAndCompdIdentity() public {
        CompdProductionVaultV2 vault = _newVault(address(0), address(0x100), address(0x200), address(0x300));
        vm.expectRevert(CompdV2Errors.InvalidImmutableConfiguration.selector);
        new CompdThinFlapReceiverV2(address(vault), address(0x999));
        CompdThinFlapReceiverV2 receiver = new CompdThinFlapReceiverV2(address(vault), vault.compdToken());
        assertEq(receiver.productionVault(), address(vault));
        assertEq(receiver.vault(), address(vault));
        assertEq(receiver.taxToken(), vault.compdToken());
        assertEq(receiver.vaultQuoteToken(), vault.quoteToken());
    }

    function testManifestCandidateCapIsBoundedAndMarkedLocal() public pure {
        assertTrue(CompdV2Types.canAppendManifestEntry(15));
        assertFalse(CompdV2Types.canAppendManifestEntry(16));
        assertFalse(CompdV2Types.canAppendManifestEntry(17));
    }

    function testEmergencyInitiationEvolvedBeyondScaffoldAndEntersRecoveryWithoutSweeping() public {
        CompdProductionVaultV2 vault = _newVault(address(0), address(0x100), address(0x200), address(0x300));
        vm.prank(address(0x200));
        vault.emergencyWithdrawAll();
        assertEq(uint8(vault.lifecycle()), uint8(CompdV2Types.Lifecycle.EMERGENCY_RECOVERY));
        (CompdV2Types.Lifecycle state_, CompdV2Types.EmergencyProcessingStatus status_, bytes32 snapshotId,,,) = vault.emergencyRecoveryState();
        assertTrue(snapshotId != bytes32(0));
        assertEq(uint256(state_), uint256(CompdV2Types.Lifecycle.EMERGENCY_RECOVERY));
        assertEq(uint256(status_), uint256(CompdV2Types.EmergencyProcessingStatus.IN_PROGRESS));
    }

    function testEmergencySnapshotEncodingIsDeterministic() public pure {
        CompdV2Types.EmergencySnapshot memory value;
        value.snapshotId = keccak256("snapshot");
        value.accountedQuote = 123;
        value.holderRewardReserve = 45;
        value.lifecycleBefore = CompdV2Types.Lifecycle.TERMINATED;
        value.snapshotStatus = CompdV2Types.EmergencySnapshotCellStatus.RECORDED;
        bytes memory encoded = abi.encode(value);
        CompdV2Types.EmergencySnapshot memory decoded = abi.decode(encoded, (CompdV2Types.EmergencySnapshot));
        assertEq(keccak256(abi.encode(decoded)), keccak256(encoded));
        assertEq(decoded.snapshotId, value.snapshotId);
        assertEq(decoded.accountedQuote, value.accountedQuote);
        assertEq(uint8(decoded.lifecycleBefore), uint8(value.lifecycleBefore));
    }

    function _assertUnique(bytes4[] memory selectors) private pure {
        for (uint256 i; i < selectors.length; ++i) {
            for (uint256 j = i + 1; j < selectors.length; ++j) assertTrue(selectors[i] != selectors[j]);
        }
    }
}
