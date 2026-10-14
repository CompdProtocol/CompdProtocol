// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CompdProductionVault} from "../contracts/production/CompdProductionVault.sol";
import {CompdStrategyExecutor} from "../contracts/production/CompdStrategyExecutor.sol";
import {CompdBuybackExecutor} from "../contracts/production/CompdBuybackExecutor.sol";
import {CompdProductionVaultFactory} from "../contracts/flap/CompdProductionVaultFactory.sol";
import {CompdThinFlapReceiver} from "../contracts/flap/CompdThinFlapReceiver.sol";
import {
    MockProductionERC20,
    MockCompdToken,
    MockEquityOracle,
    MockStrategyAdapter,
    MockHolderRewardsDistributor
} from "./fixtures/CompdProductionFixtures.sol";

contract CompdHolderRewardsAccountingTest is Test {
    address private constant PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
    address private constant TAX_PROCESSOR = address(0xF1A9);
    address private constant GUARDIAN = 0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    address private constant AUTOMATION = 0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;
    address private constant RECOVERY = 0xFa8706AA97B07cb29096381f9101784bA0d1332b;
    address private constant COMPD = 0x7b7Af51136574c91A12988989c0a08E98aE97777;
    uint64 private constant DAY_START = 10 days;

    MockProductionERC20 private quote;
    MockProductionERC20 private market;
    CompdProductionVault private vault;
    CompdStrategyExecutor private strategy;
    CompdProductionVaultFactory private factory;
    CompdThinFlapReceiver private receiver;
    MockStrategyAdapter private adapter;
    MockEquityOracle private oracle;
    MockHolderRewardsDistributor private distributor;

    function setUp() public {
        vm.chainId(56);
        vm.roll(10_000);
        vm.warp(DAY_START + 100);
        vm.deal(address(this), 100 ether);
        vm.deal(TAX_PROCESSOR, 10 ether);

        quote = new MockProductionERC20("Holder Quote", "HQ", 18);
        market = new MockProductionERC20("Holder Market", "HM", 18);
        MockCompdToken compd = new MockCompdToken(TAX_PROCESSOR);
        vm.etch(COMPD, address(compd).code);

        vault = new CompdProductionVault(address(quote), address(this));
        strategy = new CompdStrategyExecutor(address(vault), address(this));
        CompdBuybackExecutor buyback = new CompdBuybackExecutor(address(vault));
        factory = new CompdProductionVaultFactory(address(vault));
        vault.configureHolderRewardsActivation(1, bytes32(uint256(1)), DAY_START);
        distributor = new MockHolderRewardsDistributor();
        vault.bindHolderRewardsDistributor(address(distributor));
        vault.bindStrategyExecutor(address(strategy));
        vault.bindBuybackExecutor(address(buyback));
        vault.bindReceiverFactory(address(factory));

        adapter = new MockStrategyAdapter(address(quote));
        oracle = new MockEquityOracle();
        oracle.set(1_000 ether, block.timestamp);
        strategy.configureDependencies(address(adapter), address(oracle), 1 days);
        strategy.setMarketAsset(keccak256("HOLDER_TEST_MARKET"), address(market), true);

        vm.prank(PORTAL);
        receiver = CompdThinFlapReceiver(
            payable(factory.newVault(COMPD, address(quote), address(this), bytes("")))
        );
        _sendRevenue(100 ether);
        vault.grantRole(vault.HOLDER_REWARD_SETTLER_ROLE(), address(this));
        vm.prank(GUARDIAN);
        vault.resume();
    }

    function testFlapRevenueStaysExactly351550AndNeverFundsHolders() public view {
        assertEq(vault.strategyCapital(), 35 ether);
        assertEq(vault.buybackReserve(), 15 ether);
        assertEq(vault.protocolReserve(), 50 ether);
        assertEq(vault.holderRewardReserve(), 0);
        _assertAccounting();
    }

    function testProfitSplitRoutesHolderOnlyFromPositiveRealizedProfit() public {
        (bytes32 windowId, uint64 start, uint64 end) = _settleProfit(1 ether, 1 ether);
        bytes32 expectedDomain = keccak256(
            abi.encode(
                keccak256(bytes("CompdHolderRewardsDomain(bytes32 protocolId,uint256 chainId,address compdToken,address vault,address distributor,address rewardAsset)")),
                vault.HOLDER_PROTOCOL_ID(),
                uint256(56),
                COMPD,
                address(vault),
                address(distributor),
                address(quote)
            )
        );
        assertEq(vault.holderDomainSeparator(), expectedDomain);
        bytes32 expectedWindowId = keccak256(
            abi.encode(
                vault.HOLDER_WINDOW_TYPEHASH(), expectedDomain, uint256(1), bytes32(uint256(1)), DAY_START, start, end
            )
        );
        assertEq(windowId, expectedWindowId);
        assertEq(vault.cumulativeRealizedProfit(), 1 ether);
        assertEq(vault.strategyCapital(), 35 ether + 0.65 ether);
        assertEq(vault.buybackReserve(), 15 ether + 0.15 ether);
        assertEq(vault.holderRewardReserve(), 0.1 ether);
        assertEq(vault.protocolReserve(), 50 ether + 0.1 ether);
        assertEq(vault.holderRewardPool(windowId), 0.1 ether);
        assertEq(vault.holderUnfinalizedWindowPoolTotal(), 0.1 ether);
        _assertAccounting();
    }

    function testTinyProfitResidualGoesToStrategyAndHolderMayRoundToZero() public {
        uint256 beforeStrategy = vault.strategyCapital();
        uint256 beforeHolder = vault.holderRewardReserve();
        _settleProfit(1 ether, 1);
        assertEq(vault.strategyCapital() - beforeStrategy, 1);
        assertEq(vault.holderRewardReserve(), beforeHolder);
        assertEq(vault.buybackReserve(), 15 ether);
        assertEq(vault.protocolReserve(), 50 ether);
        _assertAccounting();
    }

    function testClosedRunCannotBeSettledTwiceOrDoubleAccrueHolderProfit() public {
        uint256 runId = _open(1 ether);
        adapter.setReturn(runId, 2 ether);
        vm.prank(AUTOMATION);
        strategy.closePosition(runId);
        uint256 holderReserveAfterClose = vault.holderRewardReserve();
        uint256 accountedAfterClose = vault.accountedQuote();

        vm.prank(AUTOMATION);
        vm.expectRevert(CompdStrategyExecutor.InvalidPosition.selector);
        strategy.closePosition(runId);
        vm.prank(address(strategy));
        vm.expectRevert(CompdProductionVault.InvalidRun.selector);
        vault.settleStrategyPrincipal(runId, 2 ether);

        assertEq(vault.holderRewardReserve(), holderReserveAfterClose);
        assertEq(vault.holderRewardReserve(), 0.1 ether);
        assertEq(vault.cumulativeRealizedProfit(), 1 ether);
        assertEq(vault.activePrincipal(), 0);
        assertEq(vault.accountedQuote(), accountedAfterClose);
        _assertAccounting();
    }

    function testFuzz_ProfitSplitConservesEveryBaseUnit(uint96 rawProfit) public {
        uint256 profit = uint256(rawProfit);
        uint256 beforeStrategy = vault.strategyCapital();
        uint256 beforeBuyback = vault.buybackReserve();
        uint256 beforeHolder = vault.holderRewardReserve();
        uint256 beforeProtocol = vault.protocolReserve();
        _settleProfit(1 ether, profit);
        uint256 strategyPart = vault.strategyCapital() - beforeStrategy;
        uint256 buybackPart = vault.buybackReserve() - beforeBuyback;
        uint256 holderPart = vault.holderRewardReserve() - beforeHolder;
        uint256 protocolPart = vault.protocolReserve() - beforeProtocol;
        assertEq(strategyPart + buybackPart + holderPart + protocolPart, profit);
        assertEq(buybackPart, profit * 1_500 / 10_000);
        assertEq(holderPart, profit * 1_000 / 10_000);
        assertEq(protocolPart, profit * 1_000 / 10_000);
        assertEq(strategyPart, profit - buybackPart - holderPart - protocolPart);
        _assertAccounting();
    }

    function testSettlementWindowsAreHalfOpenAtBoundary() public {
        (bytes32 beforeId, uint64 beforeStart, uint64 beforeEnd) = _settleProfitAt(1 ether, 1 ether, DAY_START + 28_799);
        (bytes32 exactId, uint64 exactStart, uint64 exactEnd) = _settleProfitAt(1 ether, 1 ether, DAY_START + 28_800);
        (bytes32 afterId, uint64 afterStart, uint64 afterEnd) = _settleProfitAt(1 ether, 1 ether, DAY_START + 28_801);
        assertEq(beforeStart, DAY_START);
        assertEq(beforeEnd, DAY_START + 28_800);
        assertEq(exactStart, DAY_START + 28_800);
        assertEq(exactEnd, DAY_START + 57_600);
        assertEq(afterStart, exactStart);
        assertEq(afterEnd, exactEnd);
        assertTrue(beforeId != exactId);
        assertEq(exactId, afterId);
        assertEq(vault.holderRewardPool(beforeId), 0.1 ether);
        assertEq(vault.holderRewardPool(exactId), 0.2 ether);
        _assertAccounting();
    }

    function testUnauthorizedCallersCannotUseHolderVaultPrimitives() public {
        address unauthorized = address(0xBAD);
        bytes32 windowId = vault.holderWindowId(DAY_START, DAY_START + vault.HOLDER_WINDOW_SECONDS());
        bytes32 distributionId = _distributionId(windowId);

        vm.prank(unauthorized);
        vm.expectRevert();
        vault.configureHolderRewardsActivation(2, bytes32(uint256(2)), DAY_START);
        vm.prank(unauthorized);
        vm.expectRevert();
        vault.bindHolderRewardsDistributor(address(this));
        vm.prank(unauthorized);
        vm.expectRevert();
        vault.reserveFinalizedHolderDistribution(distributionId, windowId, 1, 1, 1);
        vm.prank(unauthorized);
        vm.expectRevert();
        vault.registerHolderRewardEntry(distributionId, 1, windowId, 0, address(0xCAFE), 1);
        vm.prank(unauthorized);
        vm.expectRevert();
        vault.finalizeHolderDistribution(distributionId, 1);
        vm.prank(unauthorized);
        vm.expectRevert();
        vault.payCommittedHolderEntry(distributionId, 1, windowId, 0, address(0xCAFE), address(quote), 1);
        vm.prank(unauthorized);
        vm.expectRevert();
        vault.markHolderEntryFailed(distributionId, 1, windowId, 0, address(0xCAFE), address(quote), 1);
        vm.prank(unauthorized);
        vm.expectRevert();
        vault.markManualSettlementAvailable(distributionId, 1, windowId, 0);
        vm.prank(unauthorized);
        vm.expectRevert();
        vault.settleFailedHolderEntry(distributionId, 1, windowId, 0, address(0xCAFE), address(quote), 1);
        vm.prank(unauthorized);
        vm.expectRevert();
        vault.startTerminalHolderLiability(distributionId, 1, windowId, 0);
        vm.prank(unauthorized);
        vm.expectRevert();
        vault.classifyEmptyHolderWindow(windowId);
        vm.prank(unauthorized);
        vm.expectRevert();
        vault.recoverEligibleHolderRewards();
    }

    function testExactLiabilityReviewPayoutAndAtMostOnceAccounting() public {
        (bytes32 windowId,, uint64 windowEnd) = _settleProfit(1 ether, 1 ether);
        bytes32 distributionId = _distributionId(windowId);
        vm.warp(windowEnd);
        vm.prank(address(distributor));
        vault.reserveFinalizedHolderDistribution(distributionId, windowId, 1, 0.1 ether, 1);
        vm.prank(address(distributor));
        vault.registerHolderRewardEntry(distributionId, 1, windowId, 0, address(0xCAFE), 0.1 ether);

        vm.warp(block.timestamp + 1_800);
        vm.prank(address(distributor));
        vault.finalizeHolderDistribution(distributionId, 1);
        assertEq(vault.holderCandidateReviewPoolTotal(), 0);
        assertEq(vault.holderFinalizedUnpaidLiabilityTotal(), 0.1 ether);

        uint256 beforeQuote = quote.balanceOf(address(vault));
        vm.prank(address(distributor));
        vm.expectRevert(CompdProductionVault.InvalidHolderContext.selector);
        vault.payCommittedHolderEntry(distributionId, 1, windowId, 0, address(0xBAD), address(quote), 0.1 ether);
        vm.prank(address(distributor));
        vm.expectRevert(CompdProductionVault.InvalidHolderContext.selector);
        vault.payCommittedHolderEntry(distributionId, 1, windowId, 0, address(0xCAFE), address(quote), 0.2 ether);
        vm.prank(AUTOMATION);
        vm.expectRevert(CompdProductionVault.Unauthorized.selector);
        vault.payCommittedHolderEntry(distributionId, 1, windowId, 0, address(0xCAFE), address(quote), 0.1 ether);

        vm.prank(address(distributor));
        vault.payCommittedHolderEntry(distributionId, 1, windowId, 0, address(0xCAFE), address(quote), 0.1 ether);
        assertEq(quote.balanceOf(address(vault)), beforeQuote - 0.1 ether);
        assertEq(quote.balanceOf(address(0xCAFE)), 0.1 ether);
        assertEq(vault.holderRewardReserve(), 0);
        assertEq(vault.holderFinalizedUnpaidLiabilityTotal(), 0);
        assertEq(vault.accountedQuote(), vault.totalAccountedBuckets());

        vm.prank(address(distributor));
        vm.expectRevert(CompdProductionVault.HolderEntryUnavailable.selector);
        vault.payCommittedHolderEntry(distributionId, 1, windowId, 0, address(0xCAFE), address(quote), 0.1 ether);
        vm.prank(address(distributor));
        vm.expectRevert(CompdProductionVault.InvalidHolderContext.selector);
        vault.correctHolderDistribution(distributionId, 2, 1);
    }

    function testVersionedCorrectionReplacesEntriesAndRestartsFullReview() public {
        (bytes32 windowId,, uint64 windowEnd) = _settleProfit(1 ether, 1 ether);
        bytes32 distributionId = _distributionId(windowId);
        vm.warp(windowEnd);
        vm.prank(address(distributor));
        vault.reserveFinalizedHolderDistribution(distributionId, windowId, 1, 0.1 ether, 2);
        vm.prank(address(distributor));
        vault.registerHolderRewardEntry(distributionId, 1, windowId, 0, address(0xCAFE), 0.04 ether);
        vm.prank(address(distributor));
        vault.registerHolderRewardEntry(distributionId, 1, windowId, 1, address(0xBEEF), 0.06 ether);

        uint256 reserveBefore = vault.holderRewardReserve();
        uint256 quoteBefore = quote.balanceOf(address(vault));
        uint256 oldReviewEnd = block.timestamp + 1_800;
        vm.warp(oldReviewEnd); // correction remains valid after the former review interval, before any payout
        vm.prank(address(distributor));
        vault.correctHolderDistribution(distributionId, 2, 1);
        assertEq(vault.holderDistributionVersion(distributionId), 2);
        assertEq(vault.holderRewardReserve(), reserveBefore);
        assertEq(quote.balanceOf(address(vault)), quoteBefore);
        _assertAccounting();

        vm.prank(address(distributor));
        vm.expectRevert(CompdProductionVault.HolderReviewActive.selector);
        vault.finalizeHolderDistribution(distributionId, 1);
        vm.prank(address(distributor));
        vm.expectRevert(CompdProductionVault.InvalidHolderContext.selector);
        vault.payCommittedHolderEntry(distributionId, 1, windowId, 0, address(0xCAFE), address(quote), 0.04 ether);

        vm.prank(address(distributor));
        vault.registerHolderRewardEntry(distributionId, 2, windowId, 0, address(0xD00D), 0.1 ether);
        vm.warp(block.timestamp + 1_799);
        vm.prank(address(distributor));
        vm.expectRevert(CompdProductionVault.HolderReviewActive.selector);
        vault.finalizeHolderDistribution(distributionId, 2);
        vm.warp(block.timestamp + 1);
        vm.prank(address(distributor));
        vault.finalizeHolderDistribution(distributionId, 2);

        assertEq(vault.holderFinalizedUnpaidLiabilityTotal(), 0.1 ether);
        assertEq(vault.holderPendingAutomaticEntryCount(), 1);
        CompdProductionVault.HolderEntry memory staleEntry = vault.holderRewardEntry(distributionId, 1);
        assertEq(staleEntry.version, 1);
        vm.prank(address(distributor));
        vm.expectRevert(CompdProductionVault.InvalidHolderContext.selector);
        vault.payCommittedHolderEntry(distributionId, 1, windowId, 1, address(0xBEEF), address(quote), 0.06 ether);

        vm.prank(address(distributor));
        vault.payCommittedHolderEntry(distributionId, 2, windowId, 0, address(0xD00D), address(quote), 0.1 ether);
        vm.prank(address(distributor));
        vm.expectRevert(CompdProductionVault.InvalidHolderContext.selector);
        vault.correctHolderDistribution(distributionId, 3, 1);
        assertEq(quote.balanceOf(address(0xD00D)), 0.1 ether);
        _assertAccounting();
    }

    function testSequentialVersionsAndIncompleteReplacementCannotFinalize() public {
        (bytes32 windowId,, uint64 windowEnd) = _settleProfit(1 ether, 1 ether);
        bytes32 distributionId = _distributionId(windowId);
        vm.warp(windowEnd);
        vm.prank(address(distributor));
        vault.reserveFinalizedHolderDistribution(distributionId, windowId, 1, 0.1 ether, 2);

        vm.prank(address(distributor));
        vault.correctHolderDistribution(distributionId, 2, 1);
        vm.prank(address(distributor));
        vm.expectRevert(CompdProductionVault.InvalidHolderContext.selector);
        vault.correctHolderDistribution(distributionId, 2, 1); // same version
        vm.prank(address(distributor));
        vm.expectRevert(CompdProductionVault.InvalidHolderContext.selector);
        vault.correctHolderDistribution(distributionId, 4, 1); // skipped version
        vm.prank(address(distributor));
        vm.expectRevert(CompdProductionVault.InvalidHolderContext.selector);
        vault.correctHolderDistribution(distributionId, 1, 1); // stale version

        vm.warp(block.timestamp + 17);
        vm.prank(address(distributor));
        vault.correctHolderDistribution(distributionId, 3, 2);
        assertEq(vault.holderDistributionVersion(distributionId), 3);
        vm.prank(address(distributor));
        vm.expectRevert(CompdProductionVault.InvalidHolderContext.selector);
        vault.registerHolderRewardEntry(distributionId, 2, windowId, 0, address(0xCAFE), 0.1 ether);
        vm.prank(address(distributor));
        vault.registerHolderRewardEntry(distributionId, 3, windowId, 0, address(0xCAFE), 0.1 ether);

        vm.warp(block.timestamp + 1_800);
        vm.prank(address(distributor));
        vm.expectRevert(CompdProductionVault.HolderReviewActive.selector);
        vault.finalizeHolderDistribution(distributionId, 3); // expected two positive entries, only one registered
        assertEq(vault.holderCandidateReviewPoolTotal(), 0.1 ether);
        assertEq(vault.holderFinalizedUnpaidLiabilityTotal(), 0);
        _assertAccounting();
    }

    function testAutomaticFailureLocksCorrectionAndManualSettlementIsExclusive() public {
        (bytes32 windowId,, uint64 windowEnd) = _settleProfit(1 ether, 1 ether);
        bytes32 distributionId = _distributionId(windowId);
        vm.warp(windowEnd);
        vm.prank(address(distributor));
        vault.reserveFinalizedHolderDistribution(distributionId, windowId, 1, 0.1 ether, 1);
        vm.prank(address(distributor));
        vault.registerHolderRewardEntry(distributionId, 1, windowId, 0, address(0xCAFE), 0.1 ether);
        vm.warp(block.timestamp + 1_800);
        vm.prank(address(distributor));
        vault.finalizeHolderDistribution(distributionId, 1);

        // The bound Distributor records a failed exact payout after catching the payout subcall revert.
        vm.prank(address(distributor));
        vault.markHolderEntryFailed(distributionId, 1, windowId, 0, address(0xCAFE), address(quote), 0.1 ether);
        vm.prank(address(distributor));
        vm.expectRevert(CompdProductionVault.HolderEntryUnavailable.selector);
        vault.payCommittedHolderEntry(distributionId, 1, windowId, 0, address(0xCAFE), address(quote), 0.1 ether);
        vm.prank(address(distributor));
        vm.expectRevert(CompdProductionVault.InvalidHolderContext.selector);
        vault.correctHolderDistribution(distributionId, 2, 1);

        vm.prank(address(this));
        vm.expectRevert(CompdProductionVault.HolderEntryUnavailable.selector);
        vault.settleFailedHolderEntry(distributionId, 1, windowId, 0, address(0xCAFE), address(quote), 0.1 ether);
        vault.markManualSettlementAvailable(distributionId, 1, windowId, 0);
        vm.expectRevert(CompdProductionVault.InvalidHolderContext.selector);
        vault.settleFailedHolderEntry(distributionId, 1, windowId, 0, address(0xBEEF), address(quote), 0.1 ether);
        vm.expectRevert(CompdProductionVault.InvalidHolderContext.selector);
        vault.settleFailedHolderEntry(distributionId, 1, windowId, 0, address(0xCAFE), address(quote), 0.2 ether);

        vault.settleFailedHolderEntry(distributionId, 1, windowId, 0, address(0xCAFE), address(quote), 0.1 ether);
        vm.prank(address(distributor));
        vm.expectRevert(CompdProductionVault.HolderEntryUnavailable.selector);
        vault.payCommittedHolderEntry(distributionId, 1, windowId, 0, address(0xCAFE), address(quote), 0.1 ether);
        vm.expectRevert(CompdProductionVault.HolderEntryUnavailable.selector);
        vault.settleFailedHolderEntry(distributionId, 1, windowId, 0, address(0xCAFE), address(quote), 0.1 ether);
        assertEq(quote.balanceOf(address(0xCAFE)), 0.1 ether);
        assertEq(vault.holderRewardReserve(), 0);
        _assertAccounting();
    }

    function testSupersededEntryCannotEnterTerminalHandling() public {
        (bytes32 windowId,, uint64 windowEnd) = _settleProfit(1 ether, 1 ether);
        bytes32 distributionId = _distributionId(windowId);
        vm.warp(windowEnd);
        vm.prank(address(distributor));
        vault.reserveFinalizedHolderDistribution(distributionId, windowId, 1, 0.1 ether, 1);
        vm.prank(address(distributor));
        vault.registerHolderRewardEntry(distributionId, 1, windowId, 0, address(0xCAFE), 0.1 ether);
        vm.prank(address(distributor));
        vault.correctHolderDistribution(distributionId, 2, 1);
        vm.prank(address(distributor));
        vault.registerHolderRewardEntry(distributionId, 2, windowId, 0, address(0xD00D), 0.1 ether);
        vm.warp(block.timestamp + 1_800);
        vm.prank(address(distributor));
        vault.finalizeHolderDistribution(distributionId, 2);
        vm.prank(address(distributor));
        vault.markHolderEntryFailed(distributionId, 2, windowId, 0, address(0xD00D), address(quote), 0.1 ether);
        vault.markManualSettlementAvailable(distributionId, 2, windowId, 0);

        vm.prank(GUARDIAN);
        vault.initiateShutdown();
        vm.warp(vault.shutdownAt());
        vm.prank(GUARDIAN);
        vault.terminate();

        vm.prank(address(distributor));
        vm.expectRevert(CompdProductionVault.HolderEntryUnavailable.selector);
        vault.startTerminalHolderLiability(distributionId, 1, windowId, 0);
        vm.prank(address(distributor));
        vault.startTerminalHolderLiability(distributionId, 2, windowId, 0);
        CompdProductionVault.HolderEntry memory activeEntry = vault.holderRewardEntry(distributionId, 0);
        assertEq(activeEntry.version, 2);
        assertEq(uint8(activeEntry.status), uint8(CompdProductionVault.HolderEntryStatus.TERMINAL_PENDING));
        _assertAccounting();
    }

    function testTerminalRecoveryAfterRejectedPayoutAndManualSettlement() public {
        (bytes32 windowId,, uint64 windowEnd) = _settleProfit(1 ether, 1 ether);
        bytes32 distributionId = _distributionId(windowId);
        vm.warp(windowEnd);
        vm.prank(address(distributor));
        vault.reserveFinalizedHolderDistribution(distributionId, windowId, 1, 0.1 ether, 1);
        vm.prank(address(distributor));
        vault.registerHolderRewardEntry(distributionId, 1, windowId, 0, address(0xCAFE), 0.1 ether);
        vm.warp(block.timestamp + 1_800);
        vm.prank(address(distributor));
        vault.finalizeHolderDistribution(distributionId, 1);
        vm.prank(address(distributor));
        vault.markHolderEntryFailed(distributionId, 1, windowId, 0, address(0xCAFE), address(quote), 0.1 ether);
        assertEq(vault.holderRewardReserve(), 0.1 ether);
        assertEq(vault.holderFinalizedUnpaidLiabilityTotal(), 0.1 ether);
        vm.expectRevert();
        vault.settleFailedHolderEntry(distributionId, 1, windowId, 0, address(0xCAFE), address(quote), 0.1 ether);
        vault.markManualSettlementAvailable(distributionId, 1, windowId, 0);

        vm.prank(GUARDIAN);
        vault.initiateShutdown();
        vm.warp(vault.shutdownAt());
        vm.prank(GUARDIAN);
        vault.terminate();
        vm.prank(address(distributor));
        vault.startTerminalHolderLiability(distributionId, 1, windowId, 0);
        vm.prank(address(distributor));
        vm.expectRevert(CompdProductionVault.InvalidHolderContext.selector);
        vault.correctHolderDistribution(distributionId, 2, 1);
        CompdProductionVault.HolderEntry memory terminalEntry = vault.holderRewardEntry(distributionId, 0);
        uint64 graceStart = terminalEntry.terminalGraceStartAt;
        assertEq(graceStart, block.timestamp);
        vm.prank(address(distributor));
        vm.expectRevert(CompdProductionVault.HolderEntryUnavailable.selector);
        vault.startTerminalHolderLiability(distributionId, 1, windowId, 0);

        uint256 before = quote.balanceOf(address(vault));
        vm.warp(uint256(graceStart) + vault.TERMINAL_GRACE_SECONDS() - 1);
        vm.expectRevert(CompdProductionVault.HolderGraceActive.selector);
        vault.expireTerminalHolderLiability(distributionId, 1, windowId, 0, address(0xCAFE), address(quote), 0.1 ether);
        assertEq(quote.balanceOf(address(vault)), before);

        vm.warp(uint256(graceStart) + vault.TERMINAL_GRACE_SECONDS());
        vault.expireTerminalHolderLiability(distributionId, 1, windowId, 0, address(0xCAFE), address(quote), 0.1 ether);
        assertEq(vault.holderRewardReserve(), 0.1 ether);
        assertEq(vault.holderFinalizedUnpaidLiabilityTotal(), 0);
        assertEq(vault.holderRecoveryEligibleTotal(), 0.1 ether);
        uint256 recipientBefore = quote.balanceOf(address(0xCAFE));
        vm.expectRevert(CompdProductionVault.HolderEntryUnavailable.selector);
        vault.settleFailedHolderEntry(distributionId, 1, windowId, 0, address(0xCAFE), address(quote), 0.1 ether);
        assertEq(quote.balanceOf(address(0xCAFE)), recipientBefore);
        vm.prank(GUARDIAN);
        vault.recoverEligibleHolderRewards();
        assertEq(quote.balanceOf(RECOVERY), 0.1 ether);
        assertEq(vault.holderRewardReserve(), 0);
        assertEq(vault.accountedQuote(), vault.totalAccountedBuckets());
    }

    function testUnfinalizedPoolCannotBeRecoveredAfterTermination() public {
        (bytes32 ignoredWindow,,) = _settleProfit(1 ether, 1 ether);
        ignoredWindow;
        vm.prank(GUARDIAN);
        vault.initiateShutdown();
        vm.warp(vault.shutdownAt());
        vm.prank(GUARDIAN);
        vault.terminate();
        vm.prank(GUARDIAN);
        vm.expectRevert(CompdProductionVault.NotSurplus.selector);
        vault.recoverEligibleHolderRewards();
        assertEq(vault.holderRewardReserve(), 0.1 ether);
    }

    function testEmptyWindowPoolOnlyBecomesRecoverableAfterTerminalReconciliation() public {
        (bytes32 windowId, uint64 start, uint64 end) = _settleProfit(1 ether, 1 ether);
        assertEq(start, DAY_START);
        vm.warp(end);
        vm.prank(address(distributor));
        vault.classifyEmptyHolderWindow(windowId);
        assertEq(vault.holderUnallocatedNoRecipientPoolTotal(), 0.1 ether);
        vm.expectRevert(CompdProductionVault.HolderReconciliationIncomplete.selector);
        vault.classifyUnallocatedHolderPoolsForRecovery();

        vm.prank(GUARDIAN);
        vault.initiateShutdown();
        vm.warp(vault.shutdownAt());
        vm.prank(GUARDIAN);
        vault.terminate();
        vault.classifyUnallocatedHolderPoolsForRecovery();
        assertEq(vault.holderRecoveryEligibleTotal(), 0.1 ether);
        vm.prank(GUARDIAN);
        vault.recoverEligibleHolderRewards();
        assertEq(quote.balanceOf(RECOVERY), 0.1 ether);
        assertEq(vault.holderRewardReserve(), 0);
        _assertAccounting();
    }

    function _settleProfit(uint256 principal, uint256 profit) private returns (bytes32 windowId, uint64 start, uint64 end) {
        return _settleProfitAt(principal, profit, uint64(block.timestamp));
    }

    function _settleProfitAt(uint256 principal, uint256 profit, uint64 timestamp)
        private
        returns (bytes32 windowId, uint64 start, uint64 end)
    {
        uint256 runId = _open(principal);
        adapter.setReturn(runId, principal + profit);
        vm.warp(timestamp);
        oracle.set(1_000 ether, block.timestamp);
        vm.prank(AUTOMATION);
        strategy.closePosition(runId);
        start = uint64(uint256(timestamp) / vault.HOLDER_WINDOW_SECONDS() * vault.HOLDER_WINDOW_SECONDS());
        end = start + vault.HOLDER_WINDOW_SECONDS();
        windowId = vault.holderWindowId(start, end);
    }

    function _open(uint256 amount) private returns (uint256 runId) {
        vm.prank(AUTOMATION);
        runId = strategy.openPosition(keccak256("HOLDER_TEST_MARKET"), address(market), amount, amount);
    }

    function _distributionId(bytes32 windowId) private view returns (bytes32) {
        return keccak256(abi.encode(vault.HOLDER_DISTRIBUTION_TYPEHASH(), vault.holderDomainSeparator(), windowId));
    }

    function _sendRevenue(uint256 amount) private {
        quote.mint(address(receiver), amount);
        vm.prank(TAX_PROCESSOR);
        (bool ok,) = address(receiver).call("");
        assertTrue(ok);
    }

    function _assertAccounting() private view {
        assertEq(
            vault.strategyCapital() + vault.buybackReserve() + vault.protocolReserve() + vault.holderRewardReserve(),
            vault.accountedQuote() + vault.activePrincipal()
        );
        assertGe(quote.balanceOf(address(vault)), vault.accountedQuote());
        assertEq(
            vault.holderUnfinalizedWindowPoolTotal() + vault.holderCandidateReviewPoolTotal()
                + vault.holderFinalizedUnpaidLiabilityTotal() + vault.holderUnallocatedNoRecipientPoolTotal()
                + vault.holderRecoveryEligibleTotal(),
            vault.holderRewardReserve()
        );
    }
}
