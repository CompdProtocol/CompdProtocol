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

contract CompdProductionInvariantHandler is Test {
    address private constant TAX_PROCESSOR = address(0xF1A9);
    address private constant AUTOMATION = 0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;
    address private constant GUARDIAN = 0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    bytes32 private constant MARKET = keccak256("INVARIANT_SPOT_MARKET");

    CompdProductionVault public immutable vault;
    CompdThinFlapReceiver public immutable receiver;
    CompdStrategyExecutor public immutable strategy;
    MockStrategyAdapter public immutable adapter;
    MockProductionERC20 public immutable quote;
    MockProductionERC20 public immutable marketAsset;

    constructor(
        CompdProductionVault vault_,
        CompdThinFlapReceiver receiver_,
        CompdStrategyExecutor strategy_,
        MockStrategyAdapter adapter_,
        MockProductionERC20 quote_,
        MockProductionERC20 marketAsset_
    ) {
        vault = vault_;
        receiver = receiver_;
        strategy = strategy_;
        adapter = adapter_;
        quote = quote_;
        marketAsset = marketAsset_;
    }

    function reportRevenue(uint96 rawAmount) external {
        uint256 amount = bound(uint256(rawAmount), 1, 1e24);
        uint256 holderBefore = vault.holderRewardReserve();
        quote.mint(address(receiver), amount);
        vm.prank(TAX_PROCESSOR);
        (bool ok,) = address(receiver).call("");
        require(ok, "receiver wake failed");
        require(vault.holderRewardReserve() == holderBefore, "Flap revenue entered holder reserve");
    }

    function completeStrategyRun(uint96 rawAmount, uint16 rawReturnBps) external {
        uint256 capital = vault.strategyCapital();
        uint256 freeCapital = vault.freeStrategyCapital();
        uint256 cap = capital / 100; // Stay below the locked 3% designed-loss bound.
        if (freeCapital < cap) cap = freeCapital;
        if (cap == 0) return;

        uint256 amount = bound(uint256(rawAmount), 1, cap);
        uint256 returnBps = uint256(rawReturnBps) % 201;
        uint256 runId = strategy.nextRunId();
        adapter.setReturn(runId, amount * returnBps / 100);

        vm.prank(AUTOMATION);
        (bool openOk, bytes memory result) = address(strategy).call(
            abi.encodeCall(CompdStrategyExecutor.openPosition, (MARKET, address(marketAsset), amount, amount))
        );
        // Repeated fuzzed losses can intentionally latch the daily loss breaker. Treat that
        // expected risk-control rejection as a no-op action instead of failing the invariant.
        if (!openOk) return;
        uint256 openedRun = abi.decode(result, (uint256));
        if (openedRun == 0) return;
        require(openedRun == runId, "unexpected run id");
        vm.prank(AUTOMATION);
        (bool closeOk,) = address(strategy).call(
            abi.encodeCall(CompdStrategyExecutor.closePosition, (openedRun))
        );
        require(closeOk, "position close failed");
    }

    function makeDirectDonation(uint96 rawAmount) external {
        quote.mint(address(vault), bound(uint256(rawAmount), 1, 1e24));
    }

    function quarantineQuoteSurplus(uint96 rawAmount) external {
        uint256 balance = quote.balanceOf(address(vault));
        uint256 accounted = vault.accountedQuote();
        uint256 quarantined = vault.quarantinedSurplus(address(quote));
        if (balance < accounted || balance - accounted <= quarantined) return;
        uint256 available = balance - accounted - quarantined;
        uint256 amount = bound(uint256(rawAmount), 1, available);
        vm.prank(GUARDIAN);
        vault.quarantineSurplus(address(quote), amount);
    }
}

contract CompdProductionInvariantTest is Test {
    address private constant PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
    address private constant TAX_PROCESSOR = address(0xF1A9);
    address private constant GUARDIAN = 0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    address private constant COMPD = 0x7b7Af51136574c91A12988989c0a08E98aE97777;

    CompdProductionVault private vault;
    CompdProductionInvariantHandler private handler;
    MockProductionERC20 private quote;

    function setUp() public {
        vm.chainId(56);
        vm.warp(10 days + 100);
        vm.deal(TAX_PROCESSOR, 1 ether);

        quote = new MockProductionERC20("Invariant Quote", "IQ", 18);
        MockProductionERC20 marketAsset = new MockProductionERC20("Invariant Asset", "IA", 18);
        MockCompdToken mockCompd = new MockCompdToken(TAX_PROCESSOR);
        vm.etch(COMPD, address(mockCompd).code);

        vault = new CompdProductionVault(address(quote), address(this));
        uint64 activationTimestamp = uint64(block.timestamp / vault.HOLDER_WINDOW_SECONDS() * vault.HOLDER_WINDOW_SECONDS());
        vault.configureHolderRewardsActivation(1, bytes32(uint256(1)), activationTimestamp);
        vault.bindHolderRewardsDistributor(address(new MockHolderRewardsDistributor()));
        CompdStrategyExecutor strategy = new CompdStrategyExecutor(address(vault), address(this));
        CompdBuybackExecutor buyback = new CompdBuybackExecutor(address(vault));
        CompdProductionVaultFactory factory = new CompdProductionVaultFactory(address(vault));
        vault.bindStrategyExecutor(address(strategy));
        vault.bindBuybackExecutor(address(buyback));
        vault.bindReceiverFactory(address(factory));

        MockStrategyAdapter adapter = new MockStrategyAdapter(address(quote));
        MockEquityOracle oracle = new MockEquityOracle();
        oracle.set(1_000 ether, block.timestamp);
        strategy.configureDependencies(address(adapter), address(oracle), 1 days);
        strategy.setMarketAsset(keccak256("INVARIANT_SPOT_MARKET"), address(marketAsset), true);

        vm.prank(PORTAL);
        CompdThinFlapReceiver receiver = CompdThinFlapReceiver(
            payable(factory.newVault(COMPD, address(quote), address(this), bytes("")))
        );
        quote.mint(address(receiver), 1_000 ether);
        vm.prank(TAX_PROCESSOR);
        (bool ok,) = address(receiver).call("");
        require(ok, "seed revenue failed");
        vm.prank(GUARDIAN);
        vault.resume();

        handler = new CompdProductionInvariantHandler(vault, receiver, strategy, adapter, quote, marketAsset);
        // Foundry also discovers deployed fixture/production contracts by default. Keep fuzzed
        // actions on the handler so the token cannot be impersonated as its Vault holder.
        excludeContract(address(vault));
        excludeContract(address(receiver));
        excludeContract(address(strategy));
        excludeContract(address(adapter));
        excludeContract(address(quote));
        excludeContract(address(marketAsset));
        excludeContract(address(oracle));
        excludeContract(address(buyback));
        excludeContract(address(factory));
        excludeContract(COMPD);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.reportRevenue.selector;
        selectors[1] = handler.completeStrategyRun.selector;
        selectors[2] = handler.makeDirectDonation.selector;
        selectors[3] = handler.quarantineQuoteSurplus.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_bucketConservationAndPhysicalSolvency() public view {
        assertEq(
            vault.strategyCapital() + vault.buybackReserve() + vault.protocolReserve() + vault.holderRewardReserve(),
            vault.accountedQuote() + vault.activePrincipal()
        );
        assertGe(quote.balanceOf(address(vault)), vault.accountedQuote());
    }

    function invariant_QuarantineNeverConsumesAccountedQuote() public view {
        assertLe(vault.quarantinedSurplus(address(quote)), quote.balanceOf(address(vault)) - vault.accountedQuote());
    }

    function invariant_holderReservePartitionAndLiabilityBacking() public view {
        assertEq(
            vault.holderUnfinalizedWindowPoolTotal() + vault.holderCandidateReviewPoolTotal()
                + vault.holderFinalizedUnpaidLiabilityTotal() + vault.holderUnallocatedNoRecipientPoolTotal()
                + vault.holderRecoveryEligibleTotal(),
            vault.holderRewardReserve()
        );
        assertLe(vault.holderFinalizedUnpaidLiabilityTotal(), vault.holderRewardReserve());
        assertLe(vault.holderRecoveryEligibleTotal(), vault.holderRewardReserve());
    }
}
