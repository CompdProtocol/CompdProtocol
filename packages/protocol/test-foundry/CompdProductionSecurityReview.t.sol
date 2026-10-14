// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CompdProductionVault} from "../contracts/production/CompdProductionVault.sol";
import {CompdStrategyExecutor} from "../contracts/production/CompdStrategyExecutor.sol";
import {CompdBuybackExecutor} from "../contracts/production/CompdBuybackExecutor.sol";
import {CompdProductionVaultFactory} from "../contracts/flap/CompdProductionVaultFactory.sol";
import {CompdThinFlapReceiver} from "../contracts/flap/CompdThinFlapReceiver.sol";
import {MockProductionERC20, MockCompdToken, MockEquityOracle, MockStrategyAdapter, MockQuoteGuard, MockBuybackRouter, MockBurnSink, MockFeeOnTransferERC20, MockHolderRewardsDistributor} from "./fixtures/CompdProductionFixtures.sol";

contract CompdProductionSecurityReviewTest is Test {
    address internal constant FLAP_VAULT_PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
    address internal constant FLAP_TAX_PROCESSOR = address(0xF1A9);
    address internal constant GUARDIAN = 0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    address internal constant AUTOMATION = 0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;
    address internal constant BUYBACK_ADMIN = 0x29BB16dB8e9f2371255BA75aF83aECaFB2CC00BA;
    address internal constant RECOVERY = 0xFa8706AA97B07cb29096381f9101784bA0d1332b;
    address internal constant COMPD = 0x7b7Af51136574c91A12988989c0a08E98aE97777;

    MockProductionERC20 internal quote;
    MockProductionERC20 internal marketAsset;
    MockProductionERC20 internal wrappedNative;
    CompdProductionVault internal vault;
    CompdStrategyExecutor internal strategy;
    CompdBuybackExecutor internal buyback;
    CompdProductionVaultFactory internal factory;
    CompdThinFlapReceiver internal receiver;
    MockStrategyAdapter internal adapter;
    MockEquityOracle internal oracle;
    MockQuoteGuard internal quoteA;
    MockQuoteGuard internal quoteB;
    MockBuybackRouter internal router;
    MockBurnSink internal burnSink;
    bytes32 internal constant MARKET = keccak256("SECURITY_REVIEW_SPOT_MARKET");

    function setUp() public {
        vm.chainId(56);
        vm.warp(10 days + 100);
        vm.deal(address(this), 100 ether);
        vm.deal(FLAP_TAX_PROCESSOR, 100 ether);

        quote = new MockProductionERC20("Test Quote", "TQ", 18);
        marketAsset = new MockProductionERC20("Test Asset", "TA", 18);
        wrappedNative = new MockProductionERC20("Wrapped BNB fixture", "WBNB", 18);
        MockCompdToken mockCompd = new MockCompdToken(FLAP_TAX_PROCESSOR);
        vm.etch(COMPD, address(mockCompd).code);

        vault = new CompdProductionVault(address(quote), address(this));
        _configureHolderRewards(vault);
        strategy = new CompdStrategyExecutor(address(vault), address(this));
        buyback = new CompdBuybackExecutor(address(vault));
        factory = new CompdProductionVaultFactory(address(vault));
        vault.bindStrategyExecutor(address(strategy));
        vault.bindBuybackExecutor(address(buyback));
        vault.bindReceiverFactory(address(factory));

        adapter = new MockStrategyAdapter(address(quote));
        oracle = new MockEquityOracle();
        oracle.set(1_000 ether, block.timestamp);
        strategy.configureDependencies(address(adapter), address(oracle), 1 days);
        strategy.setMarketAsset(MARKET, address(marketAsset), true);

        quoteA = new MockQuoteGuard();
        quoteB = new MockQuoteGuard();
        router = new MockBuybackRouter();
        burnSink = new MockBurnSink(COMPD);
        address[] memory buyPath = _path(address(quote), COMPD);
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
        address created = factory.newVault(COMPD, address(quote), address(this), bytes(""));
        receiver = CompdThinFlapReceiver(payable(created));
    }

    function testFuzz_RevenueAccountingNeverExceedsRecognizedAssets(uint96 rawRevenue) public {
        uint256 revenue = uint256(rawRevenue) + 1 ether;
        _sendRevenue(revenue);
        _assertVaultAccounting();
        assertEq(vault.cumulativeRevenue(), revenue);
    }

    function testFuzz_ProfitAndLossSettlementPreserveAssetAndBucketInvariant(
        uint96 rawRevenue,
        uint96 rawPrincipal,
        uint96 rawReturn
    ) public {
        uint256 revenue = uint256(rawRevenue) + 1 ether;
        _sendRevenue(revenue);
        _resume();

        uint256 maxPosition = vault.strategyCapital() / 10;
        uint256 principal = uint256(rawPrincipal) % maxPosition + 1;
        vm.prank(AUTOMATION);
        uint256 runId = strategy.openPosition(MARKET, address(marketAsset), principal, 1);
        uint256 returned = uint256(rawReturn) % (principal * 2 + 1);
        adapter.setReturn(runId, returned);
        vm.prank(AUTOMATION);
        strategy.closePosition(runId);

        _assertVaultAccounting();
        assertEq(vault.activePrincipal(), 0);
        assertEq(strategy.activePositionCount(), 0);
        if (returned > principal) {
            assertEq(vault.cumulativeRealizedProfit(), returned - principal);
            assertEq(vault.cumulativeRealizedLoss(), 0);
        } else if (returned < principal) {
            assertEq(vault.cumulativeRealizedLoss(), principal - returned);
            assertEq(vault.cumulativeRealizedProfit(), 0);
        } else {
            assertEq(vault.cumulativeRealizedLoss(), 0);
            assertEq(vault.cumulativeRealizedProfit(), 0);
        }
    }

    function testFuzz_AccountedQuoteCannotBeQuarantined(uint96 rawAmount) public {
        _sendRevenue(1_000 ether);
        uint256 amount = uint256(rawAmount) % vault.accountedQuote() + 1;
        vm.prank(GUARDIAN);
        vm.expectRevert(CompdProductionVault.NotSurplus.selector);
        vault.quarantineSurplus(address(quote), amount);
        _assertVaultAccounting();
    }

    function testFuzz_AutomationCannotSpendOrRecoverProtocolAssets(uint96 rawAmount) public {
        _sendRevenue(1_000 ether);
        uint256 amount = uint256(rawAmount) % vault.protocolReserve() + 1;
        vm.prank(AUTOMATION);
        vm.expectRevert();
        vault.spendProtocolReserve(address(this), amount, keccak256("AUDIT"));
        vm.prank(AUTOMATION);
        vm.expectRevert(CompdProductionVault.Unauthorized.selector);
        vault.recoverTerminatedAsset(address(quote));
        vm.prank(AUTOMATION);
        vm.expectRevert(CompdProductionVault.Unauthorized.selector);
        vault.releaseBuybackReserve(amount);
        _assertVaultAccounting();
    }

    function testFuzz_BuybackExecutionNeverExceedsFixedHalfBnbCap(uint96 rawRevenue) public {
        uint256 revenue = 20 ether + uint256(rawRevenue) % 1_000 ether;
        _sendRevenue(revenue);
        _resume();
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 1);

        vm.prank(AUTOMATION);
        (uint256 amountIn,) = buyback.executeBuyback();
        assertLe(amountIn, buyback.HARD_CAP_BNB());
        assertLe(buyback.spentThisPeriodBnb(), buyback.periodStartReserveBnb() * 4_000 / 10_000);
        _assertVaultAccounting();
    }

    function testBuybackRejectsDeviationJustAboveThreePercent() public {
        _sendRevenue(20 ether);
        _resume();
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 1);
        address[] memory path = _path(address(quote), COMPD);
        quoteA.setRate(path, 1e18, block.timestamp);
        quoteB.setRate(path, 1.030001e18, block.timestamp); // 300.01 bps above the lower quote.

        vm.prank(AUTOMATION);
        vm.expectRevert(CompdBuybackExecutor.QuoteRejected.selector);
        buyback.executeBuyback();
    }

    function testBuybackAcceptsDeviationAtExactlyThreePercent() public {
        _sendRevenue(20 ether);
        _resume();
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 1);
        address[] memory path = _path(address(quote), COMPD);
        quoteA.setRate(path, 1e18, block.timestamp);
        quoteB.setRate(path, 1.03e18, block.timestamp);

        vm.prank(AUTOMATION);
        (uint256 amountIn,) = buyback.executeBuyback();
        assertLe(amountIn, 0.5 ether);
    }

    function testBuybackSlippageCeilingRejectsOneBaseUnitBeyondThreePercent() public {
        _sendRevenue(2 ether + 34);
        _resume();
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 1);

        uint256 amountIn = vault.buybackReserve() * 2_000 / 10_000;
        uint256 expectedOut = amountIn * 2;
        uint256 exactMinimum = Math.mulDiv(expectedOut, 9_700, 10_000, Math.Rounding.Ceil);
        router.setOutputAdjustment(expectedOut - exactMinimum + 1, true);
        vm.prank(AUTOMATION);
        vm.expectRevert();
        buyback.executeBuyback();

        router.setOutputAdjustment(expectedOut - exactMinimum, true);
        vm.prank(AUTOMATION);
        (, uint256 burned) = buyback.executeBuyback();
        assertGt(burned, 0);
    }

    function testBuybackMinimumTriggerBelowAtAndAboveBoundary() public {
        // Revenue at 1.666...666 yields 0.249999999999999999 Buyback Reserve.
        _sendRevenue(1_666_666_666_666_666_666);
        _resume();
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 1);
        vm.prank(AUTOMATION);
        vm.expectRevert(CompdBuybackExecutor.ReserveBelowTrigger.selector);
        buyback.executeBuyback();
    }

    function testBuybackMinimumTriggerAtAndAboveBoundary() public {
        // At this amount, integer allocation produces exactly 0.25 quote units.
        _sendRevenue(1_666_666_666_666_666_667);
        _resume();
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 1);
        vm.prank(AUTOMATION);
        (uint256 atAmount,) = buyback.executeBuyback();
        assertEq(atAmount, 0.05 ether);

        // The immediately-above case is covered by a separate fresh vault below.
        _assertVaultAccounting();
    }

    function testBuybackMinimumTriggerImmediatelyAboveBoundary() public {
        _sendRevenue(1_666_666_666_666_666_674);
        _resume();
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 1);
        vm.prank(AUTOMATION);
        (uint256 amountIn,) = buyback.executeBuyback();
        assertEq(amountIn, 0.05 ether);
    }

    function testTerminatedReceiverSurplusCanReachOnlyFixedVaultThenRecoveryWallet() public {
        marketAsset.mint(address(receiver), 7 ether);
        vm.deal(address(receiver), 0.4 ether); // Models forced native BNB while quote is ERC20.
        vm.expectRevert(CompdThinFlapReceiver.InvalidLifecycle.selector);
        receiver.sweepOtherAssetAfterTermination(address(marketAsset));

        vm.prank(GUARDIAN);
        vault.initiateShutdown();
        vm.warp(vault.shutdownAt());
        vm.prank(GUARDIAN);
        vault.terminate();

        uint256 tokenSwept = receiver.sweepOtherAssetAfterTermination(address(marketAsset));
        uint256 bnbSwept = receiver.sweepOtherAssetAfterTermination(address(0));
        assertEq(tokenSwept, 7 ether);
        assertEq(bnbSwept, 0.4 ether);
        assertEq(marketAsset.balanceOf(address(vault)), 7 ether);
        assertEq(address(vault).balance, 0.4 ether);

        vm.prank(GUARDIAN);
        vault.quarantineSurplus(address(marketAsset), 7 ether);
        vm.prank(GUARDIAN);
        vault.quarantineSurplus(address(0), 0.4 ether);
        vm.prank(GUARDIAN);
        vault.recoverTerminatedAsset(address(marketAsset));
        vm.prank(GUARDIAN);
        vault.recoverTerminatedAsset(address(0));
        assertEq(marketAsset.balanceOf(RECOVERY) >= 7 ether, true);
        assertEq(RECOVERY.balance >= 0.4 ether, true);
    }

    function testLifecycleRejectsRepeatedTransitionsAndEveryPostTerminationAction() public {
        _sendRevenue(20 ether);
        vm.prank(GUARDIAN);
        vault.resume();
        vm.prank(GUARDIAN);
        vm.expectRevert(CompdProductionVault.InvalidLifecycle.selector);
        vault.resume();
        vm.prank(GUARDIAN);
        vault.pause();
        vm.prank(GUARDIAN);
        vm.expectRevert(CompdProductionVault.InvalidLifecycle.selector);
        vault.pause();

        vm.prank(GUARDIAN);
        vault.initiateShutdown();
        vm.prank(GUARDIAN);
        vm.expectRevert(CompdProductionVault.InvalidLifecycle.selector);
        vault.initiateShutdown();
        vm.prank(GUARDIAN);
        vm.expectRevert(CompdProductionVault.InvalidLifecycle.selector);
        vault.resume();
        vm.prank(GUARDIAN);
        vm.expectRevert(CompdProductionVault.ShutdownNotReady.selector);
        vault.terminate();

        vm.warp(vault.shutdownAt());
        vm.prank(GUARDIAN);
        vault.terminate();
        vm.prank(GUARDIAN);
        vm.expectRevert(CompdProductionVault.InvalidLifecycle.selector);
        vault.terminate();
        vm.prank(AUTOMATION);
        vm.expectRevert(CompdStrategyExecutor.InvalidLifecycle.selector);
        strategy.openPosition(MARKET, address(marketAsset), 1 ether, 1);
        vm.prank(AUTOMATION);
        vm.expectRevert(CompdBuybackExecutor.InvalidLifecycle.selector);
        buyback.executeBuyback();

        vm.prank(GUARDIAN);
        vault.recoverTerminatedAsset(address(quote));
        vm.prank(GUARDIAN);
        vm.expectRevert(CompdProductionVault.InvalidAmount.selector);
        vault.recoverTerminatedAsset(address(quote));
        assertEq(uint256(vault.lifecycle()), uint256(CompdProductionVault.Lifecycle.TERMINATED));
    }

    function testCanonicalV3CannotAttributeUnobservedErc20DonationSeparately() public {
        // ERC20 transfer itself does not wake the receiver. On the next authorized
        // TaxProcessor ping, canonical balance-delta semantics treat both amounts
        // as the new delta. This is the documented attribution limitation.
        quote.mint(address(receiver), 1 ether);
        quote.mint(address(receiver), 2 ether);
        vm.prank(FLAP_TAX_PROCESSOR);
        (bool pinged,) = address(receiver).call("");
        assertTrue(pinged);
        assertEq(vault.cumulativeRevenue(), 3 ether);
        assertEq(vault.accountedQuote(), 3 ether);
        assertEq(receiver.unrecognizedSurplus(), 0);
    }

    function testAccountingInvariantDetectsUnexpectedQuoteBalanceLoss() public {
        _sendRevenue(1_000 ether);
        address recipient = address(0xC0FFEE);
        vault.setProtocolRecipient(recipient, true);
        vault.grantRole(vault.PROTOCOL_RESERVE_SPENDER_ROLE(), address(this));
        _resume();
        quote.burn(address(vault), 1);

        vm.expectRevert(CompdProductionVault.AccountingInvariant.selector);
        vault.spendProtocolReserve(recipient, 1, keccak256("AUDIT"));
        assertEq(vault.protocolReserve(), 500 ether);
        assertEq(vault.accountedQuote(), 1_000 ether);
        assertEq(quote.balanceOf(address(vault)), 1_000 ether - 1);
    }

    function testProtocolReserveRejectsFeeOnTransferQuoteRecipientShortfall() public {
        MockFeeOnTransferERC20 feeQuote = new MockFeeOnTransferERC20();
        CompdProductionVault feeVault = new CompdProductionVault(address(feeQuote), address(this));
        _configureHolderRewards(feeVault);
        CompdStrategyExecutor feeStrategy = new CompdStrategyExecutor(address(feeVault), address(this));
        CompdBuybackExecutor feeBuyback = new CompdBuybackExecutor(address(feeVault));
        CompdProductionVaultFactory feeFactory = new CompdProductionVaultFactory(address(feeVault));
        feeVault.bindStrategyExecutor(address(feeStrategy));
        feeVault.bindBuybackExecutor(address(feeBuyback));
        feeVault.bindReceiverFactory(address(feeFactory));
        vm.prank(FLAP_VAULT_PORTAL);
        CompdThinFlapReceiver feeReceiver = CompdThinFlapReceiver(
            payable(feeFactory.newVault(COMPD, address(feeQuote), address(this), bytes("")))
        );

        feeQuote.mint(address(feeReceiver), 1_000 ether);
        vm.prank(FLAP_TAX_PROCESSOR);
        (bool woke,) = address(feeReceiver).call("");
        assertTrue(woke);
        assertEq(feeVault.accountedQuote(), 1_000 ether);
        address recipient = address(0xC0FFEE);
        feeVault.setProtocolRecipient(recipient, true);
        feeVault.grantRole(feeVault.PROTOCOL_RESERVE_SPENDER_ROLE(), address(this));
        vm.prank(GUARDIAN);
        feeVault.resume();
        feeQuote.setFeeBps(1_000);

        vm.expectRevert(CompdProductionVault.InvalidAmount.selector);
        feeVault.spendProtocolReserve(recipient, 10 ether, keccak256("AUDIT"));
        assertEq(feeVault.protocolReserve(), 500 ether);
        assertEq(feeVault.accountedQuote(), 1_000 ether);
        assertEq(feeQuote.balanceOf(recipient), 0);
        assertEq(feeQuote.balanceOf(address(feeVault)), 1_000 ether);
    }

    function testReceiverDefersTokenThatDebitsMoreThanItsNominalTransfer() public {
        MockFeeOnTransferERC20 feeQuote = new MockFeeOnTransferERC20();
        CompdProductionVault feeVault = new CompdProductionVault(address(feeQuote), address(this));
        _configureHolderRewards(feeVault);
        CompdStrategyExecutor feeStrategy = new CompdStrategyExecutor(address(feeVault), address(this));
        CompdBuybackExecutor feeBuyback = new CompdBuybackExecutor(address(feeVault));
        CompdProductionVaultFactory feeFactory = new CompdProductionVaultFactory(address(feeVault));
        feeVault.bindStrategyExecutor(address(feeStrategy));
        feeVault.bindBuybackExecutor(address(feeBuyback));
        feeVault.bindReceiverFactory(address(feeFactory));
        vm.prank(FLAP_VAULT_PORTAL);
        CompdThinFlapReceiver feeReceiver = CompdThinFlapReceiver(
            payable(feeFactory.newVault(COMPD, address(feeQuote), address(this), bytes("")))
        );

        feeQuote.mint(address(feeReceiver), 100 ether);
        (bool woke,) = address(feeReceiver).call("");
        assertTrue(woke);
        assertEq(feeReceiver.unrecognizedSurplus(), 100 ether);
        feeQuote.mint(address(feeReceiver), 1_000 ether);
        feeQuote.setFeeBps(1_000);
        feeQuote.setSenderPaysExtraFee(true);

        vm.prank(FLAP_TAX_PROCESSOR);
        (woke,) = address(feeReceiver).call("");
        assertTrue(woke);
        assertEq(feeReceiver.accountedQuote(), 1_000 ether);
        assertEq(feeReceiver.unrecognizedSurplus(), 100 ether);
        assertEq(feeQuote.balanceOf(address(feeReceiver)), 1_100 ether);
        assertEq(feeVault.accountedQuote(), 0);

        vm.prank(GUARDIAN);
        feeVault.initiateShutdown();
        vm.warp(feeVault.shutdownAt());
        vm.prank(GUARDIAN);
        vm.expectRevert(CompdProductionVault.OutstandingLiabilities.selector);
        feeVault.terminate();
    }

    function testTerminatedRecoveryRejectsFeeOnTransferAndSenderExtraFeeAssets() public {
        MockFeeOnTransferERC20 accidentalAsset = new MockFeeOnTransferERC20();
        accidentalAsset.mint(address(vault), 100 ether);
        accidentalAsset.setFeeBps(1_000);

        _resume();
        vm.prank(GUARDIAN);
        vault.initiateShutdown();
        vm.warp(vault.shutdownAt());
        vm.prank(GUARDIAN);
        vault.terminate();

        vm.prank(GUARDIAN);
        vm.expectRevert(CompdProductionVault.NotSurplus.selector);
        vault.recoverTerminatedAsset(address(accidentalAsset));
        vm.prank(GUARDIAN);
        vault.quarantineSurplus(address(accidentalAsset), 100 ether);
        vm.prank(GUARDIAN);
        vm.expectRevert(CompdProductionVault.InvalidAmount.selector);
        vault.recoverTerminatedAsset(address(accidentalAsset));
        assertEq(accidentalAsset.balanceOf(address(vault)), 100 ether);
        assertEq(accidentalAsset.balanceOf(RECOVERY), 0);
        assertEq(vault.recoveredOtherAssets(address(accidentalAsset)), 0);

        accidentalAsset.setFeeBps(0);
        accidentalAsset.setSenderPaysExtraFee(true);
        accidentalAsset.setFeeBps(1_000);
        accidentalAsset.mint(address(vault), 10 ether);
        // Keep enough unclassified balance to pay the sender-side fee so the
        // Vault's exact-debit guard, rather than the mock token's balance
        // check, is what rejects this recovery attempt.
        accidentalAsset.mint(address(vault), 11 ether);
        vm.prank(GUARDIAN);
        vault.quarantineSurplus(address(accidentalAsset), 10 ether);
        vm.prank(GUARDIAN);
        vm.expectRevert(CompdProductionVault.InvalidAmount.selector);
        vault.recoverTerminatedAsset(address(accidentalAsset));
        assertEq(accidentalAsset.balanceOf(address(vault)), 121 ether);
        assertEq(accidentalAsset.balanceOf(RECOVERY), 0);
        assertEq(vault.recoveredOtherAssets(address(accidentalAsset)), 0);

        accidentalAsset.setFeeBps(0);
        vm.prank(GUARDIAN);
        vault.recoverTerminatedAsset(address(accidentalAsset));
        assertEq(accidentalAsset.balanceOf(address(vault)), 11 ether);
        assertEq(accidentalAsset.balanceOf(RECOVERY), 110 ether);
        assertEq(vault.recoveredOtherAssets(address(accidentalAsset)), 110 ether);
    }

    function testQuarantinedRecoveryCannotSweepUnclassifiedNonQuoteBalance() public {
        MockProductionERC20 accidental = new MockProductionERC20("Accidental", "ACC", 18);
        accidental.mint(address(vault), 10 ether);
        _resume();
        vm.prank(GUARDIAN);
        vault.initiateShutdown();
        vm.warp(vault.shutdownAt());
        vm.prank(GUARDIAN);
        vault.terminate();

        vm.prank(GUARDIAN);
        vm.expectRevert(CompdProductionVault.NotSurplus.selector);
        vault.recoverTerminatedAsset(address(accidental));

        vm.prank(GUARDIAN);
        vault.quarantineSurplus(address(accidental), 4 ether);
        uint256 beforeRecovery = accidental.balanceOf(RECOVERY);
        vm.prank(GUARDIAN);
        vault.recoverTerminatedAsset(address(accidental));
        assertEq(accidental.balanceOf(RECOVERY) - beforeRecovery, 4 ether);
        assertEq(accidental.balanceOf(address(vault)), 6 ether);
        assertEq(vault.quarantinedSurplus(address(accidental)), 0);

        vm.prank(GUARDIAN);
        vm.expectRevert(CompdProductionVault.NotSurplus.selector);
        vault.recoverTerminatedAsset(address(accidental));
        vm.prank(GUARDIAN);
        vault.quarantineSurplus(address(accidental), 6 ether);
        vm.prank(GUARDIAN);
        vault.recoverTerminatedAsset(address(accidental));
        assertEq(accidental.balanceOf(address(vault)), 0);
        assertEq(accidental.balanceOf(RECOVERY), 10 ether);
    }

    function testQuarantineIsAvailableDuringShutdownAndDoesNotMoveFunds() public {
        MockProductionERC20 accidental = new MockProductionERC20("Accidental", "ACC", 18);
        accidental.mint(address(vault), 9 ether);
        _resume();
        uint256 balanceBefore = accidental.balanceOf(address(vault));
        vm.prank(GUARDIAN);
        vault.quarantineSurplus(address(accidental), 2 ether);
        vm.prank(GUARDIAN);
        vault.initiateShutdown();
        uint256 capitalBefore = vault.strategyCapital();
        vm.prank(GUARDIAN);
        vault.quarantineSurplus(address(accidental), 3 ether);
        vm.prank(GUARDIAN);
        vm.expectRevert(CompdProductionVault.NotSurplus.selector);
        vault.quarantineSurplus(address(accidental), 5 ether);
        assertEq(accidental.balanceOf(address(vault)), balanceBefore);
        assertEq(vault.strategyCapital(), capitalBefore);
        assertEq(vault.quarantinedSurplus(address(accidental)), 5 ether);
    }

    function testQuoteRecoveryDoesNotSweepUnclassifiedSurplus() public {
        _sendRevenue(1_000 ether);
        quote.mint(address(vault), 5 ether);
        _resume();
        vm.prank(GUARDIAN);
        vault.initiateShutdown();
        vm.warp(vault.shutdownAt());
        vm.prank(GUARDIAN);
        vault.terminate();

        uint256 recoveryBefore = quote.balanceOf(RECOVERY);
        vm.prank(GUARDIAN);
        vault.recoverTerminatedAsset(address(quote));
        assertEq(quote.balanceOf(RECOVERY) - recoveryBefore, 1_000 ether);
        assertEq(quote.balanceOf(address(vault)), 5 ether);
        vm.prank(GUARDIAN);
        vm.expectRevert(CompdProductionVault.NotSurplus.selector);
        vault.recoverTerminatedAsset(address(quote));

        vm.prank(GUARDIAN);
        vault.quarantineSurplus(address(quote), 5 ether);
        vm.prank(GUARDIAN);
        vault.recoverTerminatedAsset(address(quote));
        assertEq(quote.balanceOf(address(vault)), 0);
        assertEq(quote.balanceOf(RECOVERY), recoveryBefore + 1_005 ether);
    }

    function testModuleBindingsRejectMismatchedVaultAndFactory() public {
        CompdProductionVault target = new CompdProductionVault(address(quote), address(this));
        CompdProductionVault other = new CompdProductionVault(address(quote), address(this));
        _configureHolderRewards(target);
        _configureHolderRewards(other);
        CompdStrategyExecutor wrongStrategy = new CompdStrategyExecutor(address(other), address(this));
        CompdBuybackExecutor wrongBuyback = new CompdBuybackExecutor(address(other));
        CompdProductionVaultFactory wrongFactory = new CompdProductionVaultFactory(address(other));

        vm.expectRevert(CompdProductionVault.InvalidConfiguration.selector);
        target.bindStrategyExecutor(address(wrongStrategy));
        vm.expectRevert(CompdProductionVault.InvalidConfiguration.selector);
        target.bindBuybackExecutor(address(wrongBuyback));
        vm.expectRevert(CompdProductionVault.InvalidConfiguration.selector);
        target.bindReceiverFactory(address(wrongFactory));
        vm.expectRevert(CompdProductionVault.InvalidConfiguration.selector);
        target.bindStrategyExecutor(address(0x1234));
        _resume();
        vm.expectRevert(CompdProductionVault.InvalidLifecycle.selector);
        vault.bindStrategyExecutor(address(strategy));
    }

    function testModuleBindingsRejectImmutableIdentityMismatches() public {
        CompdProductionVault target = new CompdProductionVault(address(quote), address(this));
        _configureHolderRewards(target);
        MockStrategyBindingIdentity wrongStrategy = new MockStrategyBindingIdentity(address(target), address(0xBAD), GUARDIAN);
        MockBuybackBindingIdentity wrongAutomation = new MockBuybackBindingIdentity(
            address(target), address(0xBAD), COMPD, BUYBACK_ADMIN
        );
        MockBuybackBindingIdentity wrongToken = new MockBuybackBindingIdentity(
            address(target), AUTOMATION, address(0xBAD), BUYBACK_ADMIN
        );
        MockBuybackBindingIdentity wrongAdmin = new MockBuybackBindingIdentity(
            address(target), AUTOMATION, COMPD, address(0xBAD)
        );
        MockFactoryBindingIdentity wrongFactory = new MockFactoryBindingIdentity(address(target), address(0xBAD));

        vm.expectRevert(CompdProductionVault.InvalidConfiguration.selector);
        target.bindStrategyExecutor(address(wrongStrategy));
        vm.expectRevert(CompdProductionVault.InvalidConfiguration.selector);
        target.bindBuybackExecutor(address(wrongAutomation));
        vm.expectRevert(CompdProductionVault.InvalidConfiguration.selector);
        target.bindBuybackExecutor(address(wrongToken));
        vm.expectRevert(CompdProductionVault.InvalidConfiguration.selector);
        target.bindBuybackExecutor(address(wrongAdmin));
        vm.expectRevert(CompdProductionVault.InvalidConfiguration.selector);
        target.bindReceiverFactory(address(wrongFactory));
    }

    function testReceiverRecordsFactoryAndVaultIdentity() public view {
        assertEq(receiver.productionVault(), address(vault));
        assertEq(receiver.factory(), address(factory));
    }

    function testReceiverRegistrationValidatesVaultFactoryTokenQuoteAndLifecycle() public {
        CompdProductionVault target = new CompdProductionVault(address(quote), address(this));
        CompdProductionVault other = new CompdProductionVault(address(quote), address(this));
        _configureHolderRewards(target);
        _configureHolderRewards(other);
        CompdStrategyExecutor targetStrategy = new CompdStrategyExecutor(address(target), address(this));
        CompdBuybackExecutor targetBuyback = new CompdBuybackExecutor(address(target));
        target.bindStrategyExecutor(address(targetStrategy));
        target.bindBuybackExecutor(address(targetBuyback));
        MockReceiverRegistrationFactory registrationFactory = new MockReceiverRegistrationFactory(address(target));
        target.bindReceiverFactory(address(registrationFactory));

        MockReceiverIdentity wrongVault = new MockReceiverIdentity(
            address(other), address(registrationFactory), COMPD, address(quote)
        );
        MockReceiverIdentity wrongFactory = new MockReceiverIdentity(
            address(target), address(0xFACADE), COMPD, address(quote)
        );
        MockReceiverIdentity wrongToken = new MockReceiverIdentity(
            address(target), address(registrationFactory), address(0xBAD), address(quote)
        );
        MockReceiverIdentity wrongQuote = new MockReceiverIdentity(
            address(target), address(registrationFactory), COMPD, address(marketAsset)
        );
        MockReceiverIdentity valid = new MockReceiverIdentity(
            address(target), address(registrationFactory), COMPD, address(quote)
        );

        vm.prank(address(0xBAD));
        vm.expectRevert(CompdProductionVault.Unauthorized.selector);
        target.registerFlapReceiver(address(valid));
        vm.expectRevert(CompdProductionVault.InvalidConfiguration.selector);
        registrationFactory.register(address(wrongVault));
        vm.expectRevert(CompdProductionVault.InvalidConfiguration.selector);
        registrationFactory.register(address(wrongFactory));
        vm.expectRevert(CompdProductionVault.InvalidConfiguration.selector);
        registrationFactory.register(address(wrongToken));
        vm.expectRevert(CompdProductionVault.InvalidConfiguration.selector);
        registrationFactory.register(address(wrongQuote));

        registrationFactory.register(address(valid));
        assertEq(target.flapReceiver(), address(valid));
        vm.expectRevert(CompdProductionVault.InvalidConfiguration.selector);
        registrationFactory.register(address(valid));
        vm.prank(GUARDIAN);
        target.resume();
        MockReceiverIdentity another = new MockReceiverIdentity(
            address(target), address(registrationFactory), COMPD, address(quote)
        );
        vm.expectRevert(CompdProductionVault.InvalidLifecycle.selector);
        registrationFactory.register(address(another));
    }

    function _sendRevenue(uint256 amount) internal {
        quote.mint(address(receiver), amount);
        vm.prank(FLAP_TAX_PROCESSOR);
        (bool pinged,) = address(receiver).call("");
        assertTrue(pinged);
    }

    function _resume() internal {
        if (vault.lifecycle() == CompdProductionVault.Lifecycle.PAUSED) {
            vm.prank(GUARDIAN);
            vault.resume();
        }
    }

    function _configureHolderRewards(CompdProductionVault target) internal {
        uint64 activationTimestamp = uint64(block.timestamp / target.HOLDER_WINDOW_SECONDS() * target.HOLDER_WINDOW_SECONDS());
        target.configureHolderRewardsActivation(1, bytes32(uint256(1)), activationTimestamp);
        target.bindHolderRewardsDistributor(address(new MockHolderRewardsDistributor()));
    }

    function _assertVaultAccounting() internal view {
        assertEq(vault.totalAccountedBuckets(), vault.accountedQuote() + vault.activePrincipal());
        assertGe(quote.balanceOf(address(vault)), vault.accountedQuote());
    }

    function _path(address first, address second) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = first;
        path[1] = second;
    }
}

contract MockReceiverRegistrationFactory {
    address public immutable productionVault;
    address public constant COMPD_TOKEN = 0x7b7Af51136574c91A12988989c0a08E98aE97777;

    constructor(address vault_) { productionVault = vault_; }

    function register(address receiver) external {
        CompdProductionVault(payable(productionVault)).registerFlapReceiver(receiver);
    }
}

contract MockReceiverIdentity {
    address public immutable productionVault;
    address public immutable factory;
    address public immutable taxToken;
    address private immutable _quoteToken;
    uint256 public accountedQuote;

    constructor(address vault_, address factory_, address token_, address quote_) {
        productionVault = vault_;
        factory = factory_;
        taxToken = token_;
        _quoteToken = quote_;
    }

    function vaultQuoteToken() external view returns (address) { return _quoteToken; }
}

contract MockStrategyBindingIdentity {
    address public immutable vault;
    address public immutable AUTOMATION_EXECUTOR;
    address public immutable GUARDIAN;

    constructor(address vault_, address automation_, address guardian_) {
        vault = vault_;
        AUTOMATION_EXECUTOR = automation_;
        GUARDIAN = guardian_;
    }
}

contract MockBuybackBindingIdentity {
    address public immutable vault;
    address public immutable AUTOMATION_EXECUTOR;
    address public immutable COMPD_TOKEN;
    address public immutable PROTOCOL_BUYBACK_ADMIN;

    constructor(address vault_, address automation_, address token_, address admin_) {
        vault = vault_;
        AUTOMATION_EXECUTOR = automation_;
        COMPD_TOKEN = token_;
        PROTOCOL_BUYBACK_ADMIN = admin_;
    }
}

contract MockFactoryBindingIdentity {
    address public immutable productionVault;
    address public immutable COMPD_TOKEN;

    constructor(address vault_, address token_) {
        productionVault = vault_;
        COMPD_TOKEN = token_;
    }
}
