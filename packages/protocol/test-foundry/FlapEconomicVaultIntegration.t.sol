// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CompdEconomicVault} from "../contracts/CompdEconomicVault.sol";
import {CompdEconomicVaultFactory} from "../contracts/flap/CompdEconomicVaultFactory.sol";
import {MockToken} from "../contracts/mocks/MockTokensAndMarket.sol";
import {VaultUISchema, VaultDataSchema} from "../src/flap/IVaultSchemasV1.sol";

contract FlapEconomicVaultIntegrationTest is Test {
    address internal constant FLAP_VAULT_PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
    address internal constant FLAP_GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    address internal constant TAX_TOKEN = address(0x7777);
    bytes32 internal constant STRATEGY_ROLE = keccak256("STRATEGY_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant BUYBACK_EXECUTOR_ROLE = keccak256("BUYBACK_EXECUTOR_ROLE");

    MockToken internal quote;
    CompdEconomicVault internal vault;

    function setUp() public {
        vm.chainId(56);
        vm.deal(address(this), 100 ether);
        quote = new MockToken("Quote", "Q");
        vault = new CompdEconomicVault(TAX_TOKEN, address(quote), address(this));
    }

    function testReceiveGasUnder1M() public {
        uint256 gasBefore = gasleft();
        (bool success,) = address(vault).call{value: 1 ether}("");
        uint256 gasUsed = gasBefore - gasleft();
        assertTrue(success, "receive should accept native transfer");
        assertLe(gasUsed, 1_000_000, "receive exceeds Flap limit");
    }

    function testERC20PingStrategySettlementAndApprovedProfitSplit() public {
        quote.mint(address(vault), 5 ether);
        assertEq(vault.pendingRevenue(), 0, "bare ERC20 transfer must not be recognized");
        (bool woke,) = address(vault).call{value: 0}("");
        assertTrue(woke, "zero-value wake must succeed");
        assertEq(vault.pendingRevenue(), 5 ether);

        vault.configureRevenueSplit(10_000, 0, 0);
        vault.routeRevenue();
        vault.grantRole(STRATEGY_ROLE, address(this));
        vault.openStrategy(1, 2 ether);
        assertEq(vault.accountedQuote(), 3 ether, "strategy outflow must decrement baseline");

        quote.mint(address(this), 3 ether);
        quote.approve(address(vault), 3 ether);
        vault.settleStrategy(1, 3 ether);
        assertEq(vault.pendingRealizedProfit(), 1 ether);
        vault.routeProfit();
        assertEq(vault.strategyCapital(), 5.7 ether);
        assertEq(vault.profitBuybackReserve(), 0.2 ether);
        assertEq(vault.profitProtocolReserve(), 0.1 ether);
    }

    function testNegativePnLDoesNotCreateProfitAllocations() public {
        quote.mint(address(vault), 10 ether);
        (bool woke,) = address(vault).call{value: 0}("");
        assertTrue(woke);
        vault.configureRevenueSplit(10_000, 0, 0);
        vault.routeRevenue();
        vault.grantRole(STRATEGY_ROLE, address(this));
        vault.openStrategy(2, 10 ether);
        quote.mint(address(this), 8 ether);
        quote.approve(address(vault), 8 ether);
        vault.settleStrategy(2, 8 ether);
        vault.routeProfit();
        assertEq(vault.cumulativeRealizedLoss(), 2 ether);
        assertEq(vault.pendingRealizedProfit(), 0);
        assertEq(vault.profitBuybackReserve(), 0);
        assertEq(vault.profitProtocolReserve(), 0);
    }

    function testSchemaDescriptionAndGuardianRoles() public {
        assertGt(bytes(vault.description()).length, 0);
        VaultUISchema memory ui = vault.vaultUISchema();
        assertGt(bytes(ui.vaultType).length, 0);
        assertGt(bytes(ui.description).length, 0);
        assertEq(ui.methods.length, 18);
        for (uint256 i; i < ui.methods.length; ++i) {
            assertGt(bytes(ui.methods[i].name).length, 0);
            assertGt(bytes(ui.methods[i].description).length, 0);
            assertTrue(ui.methods[i].approvals.length == 0);
        }
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), FLAP_GUARDIAN));
        assertTrue(vault.hasRole(STRATEGY_ROLE, FLAP_GUARDIAN));
        assertTrue(vault.hasRole(PAUSER_ROLE, FLAP_GUARDIAN));
        assertTrue(vault.hasRole(BUYBACK_EXECUTOR_ROLE, FLAP_GUARDIAN));

        vm.expectRevert(abi.encodeWithSignature("Error(string)", "Cannot revoke Guardian"));
        vault.revokeRole(STRATEGY_ROLE, FLAP_GUARDIAN);
        vm.prank(FLAP_GUARDIAN);
        vault.pause();
        assertTrue(vault.paused());
    }

    function testShutdownSyncsUnpingedRevenueAndGuardianRecoversOnlyAfterTermination() public {
        vault.configureRevenueSplit(10_000, 0, 0);
        vault.initiateShutdown(100);
        quote.mint(address(vault), 1 ether);
        vm.warp(vault.shutdownAt());
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "Shutdown conditions not met"));
        vault.terminate();
        assertEq(vault.accountedQuote(), 0, "reverted sync must roll back atomically");

        vault.routeRevenue();
        assertEq(vault.accountedQuote(), 1 ether);
        vault.terminate();
        assertEq(uint256(vault.lifecycle()), 2);

        // A second fresh vault is used below to cover the pre-termination rejection.
        CompdEconomicVault fresh = new CompdEconomicVault(TAX_TOKEN, address(quote), address(this));
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "Recovery before termination"));
        vm.prank(FLAP_GUARDIAN);
        fresh.emergencyWithdrawToken(address(quote), address(this));

        uint256 beforeBalance = quote.balanceOf(address(this));
        vm.prank(FLAP_GUARDIAN);
        vault.emergencyWithdrawToken(address(quote), address(this));
        assertEq(quote.balanceOf(address(this)) - beforeBalance, 1 ether);
        assertEq(vault.accountedQuote(), 0);
    }

    function testFactoryUsesCanonicalPortalGuardAndDataSchema() public {
        CompdEconomicVaultFactory factory = new CompdEconomicVaultFactory(address(this));
        VaultDataSchema memory schema = factory.vaultDataSchema();
        assertGt(bytes(schema.description).length, 0);
        assertEq(schema.fields.length, 0);
        assertFalse(schema.isArray);
        assertTrue(factory.isQuoteTokenSupported(address(0)));
        assertTrue(factory.isQuoteTokenSupported(address(quote)));
        assertFalse(factory.isQuoteTokenSupported(address(0x1234)));

        vm.expectRevert(abi.encodeWithSignature("Error(string)", "Only Vault Portal"));
        factory.newVault(TAX_TOKEN, address(quote), address(this), "");

        vm.prank(FLAP_VAULT_PORTAL);
        address created = factory.newVault(TAX_TOKEN, address(quote), address(this), "");
        CompdEconomicVault createdVault = CompdEconomicVault(payable(created));
        assertEq(createdVault.taxToken(), TAX_TOKEN);
        assertEq(createdVault.vaultQuoteToken(), address(quote));
        assertEq(keccak256(bytes(createdVault.vaultSpecVersion())), keccak256(bytes("v3")));
    }
}
