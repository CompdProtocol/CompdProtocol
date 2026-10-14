// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CompdProductionVault} from "../contracts/production/CompdProductionVault.sol";
import {CompdStrategyExecutor} from "../contracts/production/CompdStrategyExecutor.sol";
import {CompdBuybackExecutor} from "../contracts/production/CompdBuybackExecutor.sol";
import {CompdProductionVaultFactory} from "../contracts/flap/CompdProductionVaultFactory.sol";
import {CompdThinFlapReceiver} from "../contracts/flap/CompdThinFlapReceiver.sol";
import {IVaultFactoryValidationV2} from "../src/flap/IVaultFactory.sol";
import {IPortalTypes} from "../src/flap/IPortal.sol";
import {
    MockProductionERC20,
    MockCompdToken,
    MockEquityOracle,
    MockStrategyAdapter,
    MockQuoteGuard,
    MockBuybackRouter,
    MockBurnSink,
    MockHolderRewardsDistributor
} from "./fixtures/CompdProductionFixtures.sol";

contract CompdProductionV1Test is Test {
    address internal constant FLAP_VAULT_PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
    address internal constant FLAP_TAX_PROCESSOR = address(0xF1A9);
    address internal constant COMPD_GUARDIAN = 0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    address internal constant AUTOMATION_EXECUTOR = 0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;
    address internal constant BUYBACK_ADMIN = 0x29BB16dB8e9f2371255BA75aF83aECaFB2CC00BA;
    address internal constant RECOVERY_WALLET = 0xFa8706AA97B07cb29096381f9101784bA0d1332b;
    address internal constant COMPD_TOKEN = 0x7b7Af51136574c91A12988989c0a08E98aE97777;
    address internal constant FLAP_GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;

    MockProductionERC20 internal quote;
    MockProductionERC20 internal marketAsset;
    MockProductionERC20 internal wrappedNative;
    CompdProductionVault internal vault;
    CompdStrategyExecutor internal strategy;
    CompdBuybackExecutor internal buyback;
    CompdProductionVaultFactory internal factory;
    CompdThinFlapReceiver internal receiver;
    MockStrategyAdapter internal adapter;
    MockEquityOracle internal equityOracle;
    MockQuoteGuard internal quoteA;
    MockQuoteGuard internal quoteB;
    MockBuybackRouter internal router;
    MockBurnSink internal burnSink;
    bytes32 internal constant MARKET = keccak256("TEST_SPOT_MARKET");

    function setUp() public {
        vm.chainId(56);
        vm.warp(10 days + 100);
        vm.deal(address(this), 100 ether);
        vm.deal(FLAP_TAX_PROCESSOR, 100 ether);

        quote = new MockProductionERC20("Test Quote", "TQ", 18);
        marketAsset = new MockProductionERC20("Test Spot Asset", "TSA", 18);
        wrappedNative = new MockProductionERC20("Wrapped BNB fixture", "WBNB", 18);

        // Local-only COMPD runtime at the owner-approved canonical address; no launch or deployment occurs.
        MockCompdToken mockCompdRuntime = new MockCompdToken(FLAP_TAX_PROCESSOR);
        vm.etch(COMPD_TOKEN, address(mockCompdRuntime).code);

        vault = new CompdProductionVault(address(quote), address(this));
        _configureHolderRewards(vault);
        strategy = new CompdStrategyExecutor(address(vault), address(this));
        buyback = new CompdBuybackExecutor(address(vault));
        factory = new CompdProductionVaultFactory(address(vault));
        vm.prank(address(this));
        vault.bindStrategyExecutor(address(strategy));
        vault.bindBuybackExecutor(address(buyback));
        vault.bindReceiverFactory(address(factory));

        adapter = new MockStrategyAdapter(address(quote));
        equityOracle = new MockEquityOracle();
        equityOracle.set(1_000 ether, block.timestamp);
        strategy.configureDependencies(address(adapter), address(equityOracle), 1 days);
        strategy.setMarketAsset(MARKET, address(marketAsset), true);

        quoteA = new MockQuoteGuard();
        quoteB = new MockQuoteGuard();
        router = new MockBuybackRouter();
        burnSink = new MockBurnSink(COMPD_TOKEN);
        address[] memory buyPath = _path(address(quote), COMPD_TOKEN);
        address[] memory bnbPath = _path(address(quote), address(wrappedNative));
        quoteA.setRate(buyPath, 2e18, block.timestamp);
        quoteB.setRate(buyPath, 2e18, block.timestamp);
        quoteA.setRate(bnbPath, 1e18, block.timestamp);
        quoteB.setRate(bnbPath, 1e18, block.timestamp);
        vm.prank(BUYBACK_ADMIN);
        buyback.configureRoute(
            address(router), address(wrappedNative), address(quoteA), address(quoteB), address(burnSink),
            7 days, 300, buyPath, bnbPath
        );

        vm.prank(FLAP_VAULT_PORTAL);
        address created = factory.newVault(COMPD_TOKEN, address(quote), address(this), bytes(""));
        receiver = CompdThinFlapReceiver(payable(created));
    }

    function testFlapFactoryV23AndNormalizedLaunchChecks() public view {
        assertEq(factory.factorySpecVersion(), "v2.3");
        assertTrue(factory.isQuoteTokenSupported(address(quote)));
        assertFalse(factory.isQuoteTokenSupported(address(marketAsset)));
        assertEq(receiver.vaultQuoteToken(), address(quote));
        assertEq(receiver.taxToken(), COMPD_TOKEN);
        assertEq(vault.flapReceiver(), address(receiver));

        IVaultFactoryValidationV2.LaunchValidationDataV1 memory valid =
            IVaultFactoryValidationV2.LaunchValidationDataV1({
                tokenVersion: IPortalTypes.TokenVersion.TOKEN_TAXED_V3,
                quoteToken: address(quote),
                buyTaxRate: 200,
                sellTaxRate: 200,
                vaultBps: 10_000,
                deflationBps: 0,
                dividendBps: 0,
                lpBps: 0,
                dividendToken: address(0),
                minimumShareBalance: 0
            });
        (bool ok,) = factory.onBeforeLaunch(abi.encode(valid));
        assertTrue(ok);

        valid.sellTaxRate = 199;
        (ok,) = factory.onBeforeLaunch(abi.encode(valid));
        assertFalse(ok);
        valid.sellTaxRate = 200;
        valid.vaultBps = 9_999;
        (ok,) = factory.onBeforeLaunch(abi.encode(valid));
        assertFalse(ok);
        valid.vaultBps = 10_000;
        valid.tokenVersion = IPortalTypes.TokenVersion.TOKEN_V2_PERMIT;
        (ok,) = factory.onBeforeLaunch(abi.encode(valid));
        assertFalse(ok);
    }

    function testRevenueSplitAndDustRemainFullyAccounted() public {
        _sendRevenue(101);
        assertEq(vault.strategyCapital(), 35);
        assertEq(vault.buybackReserve(), 15);
        assertEq(vault.protocolReserve(), 51); // Deterministic remainder goes to Protocol Reserve.
        assertEq(vault.holderRewardReserve(), 0); // Flap revenue never funds Holder Rewards.
        assertEq(vault.accountedQuote(), 101);
        assertEq(vault.totalAccountedBuckets(), 101);

        _sendRevenue(9_999);
        assertEq(vault.cumulativeRevenue(), 10_100);
        assertEq(vault.totalAccountedBuckets(), 10_100);
        assertEq(vault.accountedQuote() + vault.activePrincipal(), 10_100);
    }

    function testRealizedProfitAloneUsesApproved65_15_10_10Split() public {
        _sendRevenue(1_000 ether);
        assertEq(vault.strategyCapital(), 350 ether);
        assertEq(vault.buybackReserve(), 150 ether);
        assertEq(vault.protocolReserve(), 500 ether);
        assertEq(vault.holderRewardReserve(), 0);
        _resumeVault();

        uint256 runId = _openPosition(35 ether, 10 ether);
        adapter.setReturn(runId, 50 ether);
        vm.prank(AUTOMATION_EXECUTOR);
        strategy.closePosition(runId);

        assertEq(vault.cumulativeRealizedProfit(), 15 ether);
        assertEq(vault.cumulativeRealizedLoss(), 0);
        assertEq(vault.strategyCapital(), 359.75 ether);
        assertEq(vault.buybackReserve(), 152.25 ether);
        assertEq(vault.holderRewardReserve(), 1.5 ether);
        assertEq(vault.protocolReserve(), 501.5 ether);
        assertEq(vault.accountedQuote(), vault.totalAccountedBuckets());
        assertEq(vault.activePrincipal(), 0);
    }

    function testReturnedPrincipalIsNotProfit() public {
        _sendRevenue(1_000 ether);
        _resumeVault();
        uint256 runId = _openPosition(35 ether, 10 ether);
        adapter.setReturn(runId, 35 ether);
        vm.prank(AUTOMATION_EXECUTOR);
        strategy.closePosition(runId);

        assertEq(vault.cumulativeRealizedProfit(), 0);
        assertEq(vault.strategyCapital(), 350 ether);
        assertEq(vault.buybackReserve(), 150 ether);
        assertEq(vault.protocolReserve(), 500 ether);
        assertEq(vault.holderRewardReserve(), 0);
        assertEq(vault.accountedQuote(), 1_000 ether);
    }

    function testNegativePnLReducesCapitalWithoutCreatingProfitAllocations() public {
        _sendRevenue(1_000 ether);
        _resumeVault();
        uint256 runId = _openPosition(35 ether, 10 ether);
        adapter.setReturn(runId, 17 ether);
        vm.prank(AUTOMATION_EXECUTOR);
        strategy.closePosition(runId);

        assertEq(vault.cumulativeRealizedLoss(), 18 ether);
        assertEq(vault.cumulativeRealizedProfit(), 0);
        assertEq(vault.strategyCapital(), 332 ether);
        assertEq(vault.buybackReserve(), 150 ether);
        assertEq(vault.protocolReserve(), 500 ether);
        assertTrue(strategy.designedLossBreachTripped());
        assertEq(vault.accountedQuote(), vault.totalAccountedBuckets());
    }

    function testStrategyPositionExposureAllowlistAndConcurrencyCaps() public {
        _sendRevenue(1_000 ether);
        vm.prank(AUTOMATION_EXECUTOR);
        vm.expectRevert(CompdStrategyExecutor.InvalidLifecycle.selector);
        strategy.openPosition(MARKET, address(marketAsset), 1 ether, 1 ether);
        _resumeVault();

        vm.prank(AUTOMATION_EXECUTOR);
        vm.expectRevert(CompdStrategyExecutor.RiskLimitExceeded.selector);
        strategy.openPosition(MARKET, address(marketAsset), 35 ether + 1, 1 ether);

        vm.prank(AUTOMATION_EXECUTOR);
        vm.expectRevert(CompdStrategyExecutor.RiskLimitExceeded.selector);
        strategy.openPosition(MARKET, address(marketAsset), 1 ether, 10.5 ether + 1);

        vm.prank(AUTOMATION_EXECUTOR);
        vm.expectRevert(CompdStrategyExecutor.DependencyUnavailable.selector);
        strategy.openPosition(keccak256("NOT_ALLOWED"), address(marketAsset), 1 ether, 1 ether);

        uint256 first = _openPosition(35 ether, 10 ether);
        uint256 second = _openPosition(35 ether, 10 ether);
        uint256 third = _openPosition(35 ether, 10 ether);
        assertEq(strategy.activePositionCount(), 3);
        assertEq(strategy.activeExposure(), 105 ether);
        vm.prank(AUTOMATION_EXECUTOR);
        vm.expectRevert(CompdStrategyExecutor.InvalidPosition.selector);
        strategy.openPosition(MARKET, address(marketAsset), 1 ether, 1 ether);

        adapter.setReturn(first, 35 ether);
        vm.prank(AUTOMATION_EXECUTOR);
        strategy.closePosition(first);
        adapter.setReturn(second, 35 ether);
        vm.prank(AUTOMATION_EXECUTOR);
        strategy.closePosition(second);
        adapter.setReturn(third, 35 ether);
        vm.prank(AUTOMATION_EXECUTOR);
        strategy.closePosition(third);
        assertTrue(strategy.canFinalizeShutdown());
    }

    function testDailyRealizedLossBreakerStopsFurtherEntries() public {
        _sendRevenue(1_000 ether);
        _resumeVault();
        uint256 one = _openPosition(35 ether, 10 ether);
        uint256 two = _openPosition(35 ether, 10 ether);
        uint256 three = _openPosition(35 ether, 10 ether);
        adapter.setReturn(one, 29 ether);
        vm.prank(AUTOMATION_EXECUTOR);
        strategy.closePosition(one);
        adapter.setReturn(two, 29 ether);
        vm.prank(AUTOMATION_EXECUTOR);
        strategy.closePosition(two);
        adapter.setReturn(three, 29 ether);
        vm.prank(AUTOMATION_EXECUTOR);
        strategy.closePosition(three);

        assertEq(strategy.dailyStartStrategyCapital(), 350 ether);
        assertEq(strategy.dailyRealizedLoss(), 18 ether);
        vm.prank(AUTOMATION_EXECUTOR);
        vm.expectRevert(CompdStrategyExecutor.RiskLimitExceeded.selector);
        strategy.openPosition(MARKET, address(marketAsset), 1 ether, 1 ether);
    }

    function testDrawdownFeedLatchesUntilGuardianReviewAndResume() public {
        _sendRevenue(1_000 ether);
        _resumeVault();
        strategy.refreshRiskStatus();
        equityOracle.set(890 ether, block.timestamp);
        strategy.refreshRiskStatus();
        assertTrue(strategy.drawdownTripped());

        vm.prank(AUTOMATION_EXECUTOR);
        vm.expectRevert(CompdStrategyExecutor.DrawdownLatched.selector);
        strategy.openPosition(MARKET, address(marketAsset), 1 ether, 1 ether);

        _pauseVault();
        equityOracle.set(950 ether, block.timestamp);
        vm.prank(COMPD_GUARDIAN);
        strategy.resumeAfterDrawdown();
        _resumeVault();
        assertFalse(strategy.drawdownTripped());
        assertGt(_openPosition(1 ether, 1 ether), 0);
    }

    function testOnlyAutomationCanOpenAndOnlyGuardianCanManageLifecycle() public {
        _sendRevenue(1_000 ether);
        vm.expectRevert(CompdProductionVault.Unauthorized.selector);
        vault.resume();
        _resumeVault();

        vm.prank(address(0xA11CE));
        vm.expectRevert(CompdStrategyExecutor.Unauthorized.selector);
        strategy.openPosition(MARKET, address(marketAsset), 1 ether, 1 ether);

        vm.prank(AUTOMATION_EXECUTOR);
        vm.expectRevert();
        strategy.configureDependencies(address(adapter), address(equityOracle), 1 days);

        _pauseVault();
        _resumeVault();
        assertEq(uint256(vault.lifecycle()), uint256(CompdProductionVault.Lifecycle.ACTIVE));
    }

    function testBuybackSizingHardCapCooldownAndUtcReserveCap() public {
        _sendRevenue(20 ether); // Buyback Reserve: 3 quote units, 3 BNB-equivalent in this fixture.
        _resumeVault();
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 1);

        vm.prank(AUTOMATION_EXECUTOR);
        (uint256 firstIn, uint256 firstBurn) = buyback.executeBuyback();
        assertEq(firstIn, 0.5 ether); // 20% is 0.6; immutable per-execution cap binds at 0.5.
        assertEq(firstBurn, 1 ether);
        assertEq(buyback.periodStartReserveBnb(), 3 ether);
        assertEq(buyback.spentThisPeriodBnb(), 0.5 ether);
        assertEq(buyback.cumulativeCompdBurned(), 1 ether);

        vm.prank(AUTOMATION_EXECUTOR);
        vm.expectRevert(CompdBuybackExecutor.CooldownActive.selector);
        buyback.executeBuyback();

        vm.warp(buyback.lastExecutionAt() + 6 hours);
        vm.prank(AUTOMATION_EXECUTOR);
        (uint256 secondIn,) = buyback.executeBuyback();
        assertEq(secondIn, 0.5 ether);

        vm.warp(buyback.lastExecutionAt() + 6 hours);
        vm.prank(AUTOMATION_EXECUTOR);
        (uint256 thirdIn,) = buyback.executeBuyback();
        assertEq(thirdIn, 0.2 ether); // Remaining 40% period-start cap.
        assertEq(buyback.spentThisPeriodBnb(), 1.2 ether);

        vm.warp(buyback.lastExecutionAt() + 6 hours);
        vm.prank(AUTOMATION_EXECUTOR);
        vm.expectRevert(CompdBuybackExecutor.DailyCapExceeded.selector);
        buyback.executeBuyback();
    }

    function testBuybackTriggerSignerDeviationAndPausedGuards() public {
        _sendRevenue(1.3 ether); // 0.195 Buyback Reserve, below the 0.25 BNB-equivalent trigger.
        _resumeVault();
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 1);
        vm.prank(AUTOMATION_EXECUTOR);
        vm.expectRevert(CompdBuybackExecutor.ReserveBelowTrigger.selector);
        buyback.executeBuyback();

        _sendRevenue(2 ether);
        vm.prank(address(0xA11CE));
        vm.expectRevert(CompdBuybackExecutor.Unauthorized.selector);
        buyback.executeBuyback();

        _pauseVault();
        vm.prank(AUTOMATION_EXECUTOR);
        vm.expectRevert(CompdBuybackExecutor.InvalidLifecycle.selector);
        buyback.executeBuyback();
    }

    function testBuybackRejectsIndependentQuoteDeviation() public {
        _sendRevenue(2 ether);
        address[] memory buyPath = _path(address(quote), COMPD_TOKEN);
        quoteB.setRate(buyPath, 2.1e18, block.timestamp);
        _resumeVault();
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 1);
        vm.prank(AUTOMATION_EXECUTOR);
        vm.expectRevert(CompdBuybackExecutor.QuoteRejected.selector);
        buyback.executeBuyback();
    }

    function testAutomationCannotConfigureRouteOrReleaseReserveDirectly() public {
        address[] memory buyPath = _path(address(quote), COMPD_TOKEN);
        address[] memory bnbPath = _path(address(quote), address(wrappedNative));
        vm.prank(AUTOMATION_EXECUTOR);
        vm.expectRevert(CompdBuybackExecutor.Unauthorized.selector);
        buyback.configureRoute(address(router), address(wrappedNative), address(quoteA), address(quoteB), address(burnSink), 1 days, 300, buyPath, bnbPath);
        vm.prank(AUTOMATION_EXECUTOR);
        vm.expectRevert(CompdProductionVault.Unauthorized.selector);
        vault.releaseBuybackReserve(1);
    }

    function testLifecycleDelayExtensionAndFixedDestinationRecovery() public {
        _sendRevenue(1_000 ether);
        uint256 expected = quote.balanceOf(address(vault));
        _resumeVault();
        _pauseVault();
        vm.prank(COMPD_GUARDIAN);
        vault.initiateShutdown();
        uint64 deadline = vault.shutdownAt();
        vm.prank(COMPD_GUARDIAN);
        vm.expectRevert(CompdProductionVault.InvalidConfiguration.selector);
        vault.extendShutdown(deadline - uint64(1));
        vm.prank(COMPD_GUARDIAN);
        vault.extendShutdown(deadline + uint64(1 days));
        vm.prank(COMPD_GUARDIAN);
        vm.expectRevert(CompdProductionVault.ShutdownNotReady.selector);
        vault.terminate();

        vm.warp(deadline + 1 days);
        vm.prank(COMPD_GUARDIAN);
        vault.terminate();
        assertEq(uint256(vault.lifecycle()), uint256(CompdProductionVault.Lifecycle.TERMINATED));
        vm.prank(COMPD_GUARDIAN);
        vm.expectRevert(CompdProductionVault.InvalidLifecycle.selector);
        vault.resume();

        uint256 beforeRecovery = quote.balanceOf(RECOVERY_WALLET);
        vm.prank(COMPD_GUARDIAN);
        vault.recoverTerminatedAsset(address(quote));
        assertEq(quote.balanceOf(RECOVERY_WALLET) - beforeRecovery, expected);
        assertEq(vault.recoveredStrategyCapital(), 350 ether);
        assertEq(vault.recoveredBuybackReserve(), 150 ether);
        assertEq(vault.recoveredProtocolReserve(), 500 ether);
        assertEq(vault.strategyCapital() + vault.buybackReserve() + vault.protocolReserve(), 0);
    }

    function testActiveShutdownWaitsForOpenStrategyPositionSettlement() public {
        _sendRevenue(1_000 ether);
        _resumeVault();
        uint256 runId = _openPosition(35 ether, 10 ether);

        vm.prank(COMPD_GUARDIAN);
        vault.initiateShutdown();
        assertEq(uint256(vault.lifecycle()), uint256(CompdProductionVault.Lifecycle.SHUTDOWN_PENDING));
        vm.warp(vault.shutdownAt());
        vm.prank(COMPD_GUARDIAN);
        vm.expectRevert(CompdProductionVault.OutstandingLiabilities.selector);
        vault.terminate();

        adapter.setReturn(runId, 35 ether);
        vm.prank(AUTOMATION_EXECUTOR);
        strategy.closePosition(runId);
        assertEq(vault.activePrincipal(), 0);
        assertTrue(strategy.canFinalizeShutdown());

        vm.prank(COMPD_GUARDIAN);
        vault.terminate();
        assertEq(uint256(vault.lifecycle()), uint256(CompdProductionVault.Lifecycle.TERMINATED));
    }

    function testNoNewStrategyOrBuybackDuringShutdownPending() public {
        _sendRevenue(20 ether);
        _resumeVault();
        vm.prank(COMPD_GUARDIAN);
        vault.initiateShutdown();

        vm.prank(AUTOMATION_EXECUTOR);
        vm.expectRevert(CompdStrategyExecutor.InvalidLifecycle.selector);
        strategy.openPosition(MARKET, address(marketAsset), 1 ether, 1 ether);
        vm.prank(AUTOMATION_EXECUTOR);
        vm.expectRevert(CompdBuybackExecutor.InvalidLifecycle.selector);
        buyback.executeBuyback();
    }

    function testUnaccountedSurplusIsQuarantinedWithoutTouchingProtectedBuckets() public {
        _sendRevenue(1_000 ether);
        uint256 quoteBalanceBefore = quote.balanceOf(address(vault));
        uint256 recoveryBalanceBefore = quote.balanceOf(RECOVERY_WALLET);
        quote.mint(address(vault), 5 ether);

        vm.prank(COMPD_GUARDIAN);
        vault.quarantineSurplus(address(quote), 5 ether);
        assertEq(vault.quarantinedSurplus(address(quote)), 5 ether);
        assertEq(quote.balanceOf(address(vault)), quoteBalanceBefore + 5 ether);
        assertEq(quote.balanceOf(RECOVERY_WALLET), recoveryBalanceBefore);
        assertEq(vault.strategyCapital(), 350 ether);
        assertEq(vault.buybackReserve(), 150 ether);
        assertEq(vault.protocolReserve(), 500 ether);

        vm.prank(COMPD_GUARDIAN);
        vm.expectRevert(CompdProductionVault.NotSurplus.selector);
        vault.quarantineSurplus(address(quote), 1);
        vm.prank(AUTOMATION_EXECUTOR);
        vm.expectRevert(CompdProductionVault.Unauthorized.selector);
        vault.quarantineSurplus(address(quote), 1);
    }

    function testProtectedAndActivePrincipalBalancesCannotBeQuarantined() public {
        _sendRevenue(1_000 ether);
        vm.prank(COMPD_GUARDIAN);
        vm.expectRevert(CompdProductionVault.NotSurplus.selector);
        vault.quarantineSurplus(address(quote), 1);

        _resumeVault();
        _openPosition(35 ether, 10 ether);
        assertEq(vault.activePrincipal(), 35 ether);
        assertEq(quote.balanceOf(address(vault)), vault.accountedQuote());
        vm.prank(COMPD_GUARDIAN);
        vm.expectRevert(CompdProductionVault.NotSurplus.selector);
        vault.quarantineSurplus(address(quote), 1);
        assertEq(vault.strategyCapital(), 350 ether);
        assertEq(vault.buybackReserve(), 150 ether);
        assertEq(vault.protocolReserve(), 500 ether);
    }

    function testReceiverCannotBeDrainedThroughExternalSelfForward() public {
        vm.expectRevert(CompdThinFlapReceiver.InvalidLifecycle.selector);
        receiver.sweepQuarantinedSurplusAfterTermination();

        vm.prank(address(0xBAD));
        vm.expectRevert(CompdThinFlapReceiver.UnauthorizedSelfCall.selector);
        receiver.forwardPending(1);

        quote.mint(address(receiver), 1 ether);
        vm.prank(address(0xBAD));
        assertFalse(receiver.forward());
        assertEq(vault.accountedQuote(), 0);
        vm.prank(address(0xBAD));
        (bool pinged,) = address(receiver).call("");
        assertTrue(pinged);
        assertEq(receiver.unrecognizedSurplus(), 1 ether);
        assertFalse(receiver.forward());

        quote.mint(address(receiver), 2 ether);
        vm.prank(FLAP_TAX_PROCESSOR);
        (pinged,) = address(receiver).call("");
        assertTrue(pinged);
        assertEq(vault.cumulativeRevenue(), 2 ether);
        assertEq(receiver.unrecognizedSurplus(), 1 ether);
        assertEq(quote.balanceOf(address(receiver)), 1 ether);

        vm.prank(address(0xBAD));
        vm.expectRevert();
        factory.newVault(COMPD_TOKEN, address(quote), address(0xBAD), bytes(""));
    }

    function testNativeQuoteBuybackUsesSameLimitsAndVerifiesBurn() public {
        CompdProductionVault nativeVault = new CompdProductionVault(address(0), address(this));
        _configureHolderRewards(nativeVault);
        CompdStrategyExecutor nativeStrategy = new CompdStrategyExecutor(address(nativeVault), address(this));
        CompdBuybackExecutor nativeBuyback = new CompdBuybackExecutor(address(nativeVault));
        CompdProductionVaultFactory nativeFactory = new CompdProductionVaultFactory(address(nativeVault));
        nativeVault.bindStrategyExecutor(address(nativeStrategy));
        nativeVault.bindBuybackExecutor(address(nativeBuyback));
        nativeVault.bindReceiverFactory(address(nativeFactory));

        vm.prank(FLAP_VAULT_PORTAL);
        address nativeReceiver = nativeFactory.newVault(COMPD_TOKEN, address(0), address(this), bytes(""));
        vm.prank(FLAP_TAX_PROCESSOR);
        (bool sent,) = payable(nativeReceiver).call{value: 20 ether}("");
        assertTrue(sent);
        assertEq(nativeVault.buybackReserve(), 3 ether);

        address[] memory nativePath = _path(address(wrappedNative), COMPD_TOKEN);
        MockQuoteGuard nativeQuoteA = new MockQuoteGuard();
        MockQuoteGuard nativeQuoteB = new MockQuoteGuard();
        nativeQuoteA.setRate(nativePath, 2e18, block.timestamp);
        nativeQuoteB.setRate(nativePath, 2e18, block.timestamp);
        MockBuybackRouter nativeRouter = new MockBuybackRouter();
        MockBurnSink nativeBurnSink = new MockBurnSink(COMPD_TOKEN);
        vm.prank(BUYBACK_ADMIN);
        nativeBuyback.configureRoute(
            address(nativeRouter), address(wrappedNative), address(nativeQuoteA), address(nativeQuoteB),
            address(nativeBurnSink), 7 days, 300, nativePath, new address[](0)
        );

        vm.prank(COMPD_GUARDIAN);
        nativeVault.resume();
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 1);
        vm.prank(AUTOMATION_EXECUTOR);
        (uint256 amountIn, uint256 burned) = nativeBuyback.executeBuyback();
        assertEq(amountIn, 0.5 ether);
        assertEq(burned, 1 ether);
        assertEq(nativeBuyback.spentThisPeriodBnb(), 0.5 ether);
        assertEq(nativeVault.buybackReserve(), 2.5 ether);
    }

    function testNativeSurplusCanBeQuarantinedAndNativeFlapRevenueForwards() public {
        CompdProductionVault nativeVault = new CompdProductionVault(address(0), address(this));
        _configureHolderRewards(nativeVault);
        CompdStrategyExecutor nativeStrategy = new CompdStrategyExecutor(address(nativeVault), address(this));
        CompdBuybackExecutor nativeBuyback = new CompdBuybackExecutor(address(nativeVault));
        CompdProductionVaultFactory nativeFactory = new CompdProductionVaultFactory(address(nativeVault));
        nativeVault.bindStrategyExecutor(address(nativeStrategy));
        nativeVault.bindBuybackExecutor(address(nativeBuyback));
        nativeVault.bindReceiverFactory(address(nativeFactory));
        vm.prank(FLAP_VAULT_PORTAL);
        CompdThinFlapReceiver nativeReceiver = CompdThinFlapReceiver(
            payable(nativeFactory.newVault(COMPD_TOKEN, address(0), address(this), bytes("")))
        );

        // An unsolicited payment is quarantined at the Receiver, not credited as Flap revenue.
        (bool sent,) = address(nativeReceiver).call{value: 1 ether}("");
        assertTrue(sent);
        assertEq(nativeReceiver.unrecognizedSurplus(), 1 ether);
        assertEq(nativeVault.accountedQuote(), 0);

        vm.prank(FLAP_TAX_PROCESSOR);
        (sent,) = payable(nativeReceiver).call{value: 1 ether}("");
        assertTrue(sent);
        assertEq(nativeVault.strategyCapital(), 0.35 ether);
        assertEq(nativeVault.buybackReserve(), 0.15 ether);
        assertEq(nativeVault.protocolReserve(), 0.5 ether);
        assertEq(nativeVault.holderRewardReserve(), 0);
        assertEq(address(nativeVault).balance, 1 ether);
        assertEq(address(nativeReceiver).balance, 1 ether);

        vm.deal(address(nativeVault), address(nativeVault).balance + 2 ether);
        vm.prank(COMPD_GUARDIAN);
        nativeVault.quarantineSurplus(address(0), 2 ether);
        assertEq(nativeVault.quarantinedSurplus(address(0)), 2 ether);
        assertEq(address(nativeVault).balance, 3 ether);

        vm.prank(COMPD_GUARDIAN);
        nativeVault.initiateShutdown();
        vm.warp(nativeVault.shutdownAt());
        vm.prank(COMPD_GUARDIAN);
        nativeVault.terminate();
        nativeReceiver.sweepQuarantinedSurplusAfterTermination();
        assertEq(address(nativeReceiver).balance, 0);
        assertEq(address(nativeVault).balance, 4 ether);
        vm.prank(COMPD_GUARDIAN);
        nativeVault.quarantineSurplus(address(0), 1 ether);
        uint256 recoveryBefore = RECOVERY_WALLET.balance;
        vm.prank(COMPD_GUARDIAN);
        nativeVault.recoverTerminatedAsset(address(0));
        assertEq(RECOVERY_WALLET.balance - recoveryBefore, 4 ether);
        assertEq(nativeVault.recoveredSurplus(address(0)), 3 ether);
    }

    function testDirectRevenueCreditAndRecoveryAreRoleAndStateBound() public {
        vm.expectRevert(CompdProductionVault.Unauthorized.selector);
        vault.registerFlapRevenue(1 ether);
        vm.prank(COMPD_GUARDIAN);
        vm.expectRevert(CompdProductionVault.InvalidLifecycle.selector);
        vault.recoverTerminatedAsset(address(quote));
        vm.prank(FLAP_GUARDIAN);
        vm.expectRevert(CompdProductionVault.Unauthorized.selector);
        vault.pause();
    }

    function testProtocolReserveSpendRequiresExplicitRoleAndAllowlistedRecipient() public {
        _sendRevenue(1_000 ether);
        address recipient = address(0xC0FFEE);
        vault.setProtocolRecipient(recipient, true);
        vault.grantRole(vault.PROTOCOL_RESERVE_SPENDER_ROLE(), address(this));
        _resumeVault();
        vault.spendProtocolReserve(recipient, 100 ether, keccak256("AUDIT"));
        assertEq(vault.protocolReserve(), 400 ether);
        assertEq(vault.strategyCapital(), 350 ether);
        assertEq(vault.buybackReserve(), 150 ether);
        vm.expectRevert(CompdProductionVault.InvalidRecipient.selector);
        vault.spendProtocolReserve(address(0xBAD), 1 ether, keccak256("AUDIT"));
    }

    function _sendRevenue(uint256 amount) internal {
        quote.mint(address(receiver), amount);
        vm.prank(FLAP_TAX_PROCESSOR);
        (bool pinged,) = address(receiver).call(""); // Flap V3 zero-value wake after the quote-token transfer.
        assertTrue(pinged);
    }

    function _resumeVault() internal {
        if (vault.lifecycle() == CompdProductionVault.Lifecycle.PAUSED) {
            vm.prank(COMPD_GUARDIAN);
            vault.resume();
        }
    }

    function _configureHolderRewards(CompdProductionVault target) internal {
        uint64 activationTimestamp = uint64(block.timestamp / target.HOLDER_WINDOW_SECONDS() * target.HOLDER_WINDOW_SECONDS());
        target.configureHolderRewardsActivation(1, bytes32(uint256(1)), activationTimestamp);
        target.bindHolderRewardsDistributor(address(new MockHolderRewardsDistributor()));
    }

    function _pauseVault() internal {
        if (vault.lifecycle() == CompdProductionVault.Lifecycle.ACTIVE) {
            vm.prank(COMPD_GUARDIAN);
            vault.pause();
        }
    }

    function _openPosition(uint256 amount, uint256 declaredLoss) internal returns (uint256 runId) {
        vm.prank(AUTOMATION_EXECUTOR);
        runId = strategy.openPosition(MARKET, address(marketAsset), amount, declaredLoss);
        assertGt(runId, 0);
    }

    function _path(address first, address second) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = first;
        path[1] = second;
    }
}
