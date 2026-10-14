// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {Phase6C2G2BR6R2BTest} from "./Phase6C2G2BR6R2B.t.sol";
import {CompdVaultKernelV2R6R2B} from "../../contracts/production/v2/phase6c2g2br6r2b/CompdVaultKernelV2R6R2B.sol";
import {CompdBuybackPolicyModuleR6R2B} from "../../contracts/production/v2/phase6c2g2br6r2b/CompdBuybackPolicyModuleR6R2B.sol";
import {R6R2BExecutorMock} from "./Phase6C2G2BR6R2B.t.sol";

contract R6R2BInvariantHandler is Test {
    address private constant ADMIN = 0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;
    address private constant AUTOMATION = 0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;
    CompdVaultKernelV2R6R2B private immutable kernel;
    CompdBuybackPolicyModuleR6R2B private immutable buyback;
    R6R2BExecutorMock private immutable executor;
    uint256 public cumulativeSuccessfulSpend;
    uint256 public successfulAttempts;
    uint256 private nonce;

    constructor(CompdVaultKernelV2R6R2B k, CompdBuybackPolicyModuleR6R2B b, R6R2BExecutorMock e) {
        kernel = k; buyback = b; executor = e;
    }

    function act(uint96 rawSeconds, uint96 rawDonation, uint8 rawMode) external {
        uint256 advance = bound(uint256(rawSeconds), 0, 30 hours);
        if (advance != 0) vm.warp(block.timestamp + advance);
        uint256 donation = bound(uint256(rawDonation), 0, 2 ether);
        if (donation != 0) vm.deal(address(kernel), address(kernel).balance + donation);

        uint8 mode = rawMode % 3 == 0 ? 4 : (rawMode % 3 == 1 ? 2 : 0);
        vm.prank(ADMIN);
        executor.configure(mode, address(0));

        uint256 beforeReserve = kernel.buybackReserve();
        uint8 beforeRingCount = buyback.ringCount();
        uint64 beforeLastSuccess = buyback.lastSuccessfulBuybackAt();
        bytes32 operationId = keccak256(abi.encode("invariant-op", ++nonce));
        vm.prank(AUTOMATION);
        (bool ok,) = address(buyback).call(
            abi.encodeCall(buyback.attempt, (operationId, keccak256("invariant-quote")))
        );
        if (ok) {
            uint256 x = beforeReserve - kernel.buybackReserve();
            cumulativeSuccessfulSpend += x;
            successfulAttempts++;
            (uint64 at, uint256 recorded) = buyback.spendAt(buyback.ringCount() - 1);
            assertEq(at, block.timestamp);
            assertEq(recorded, x);
        } else {
            assertEq(beforeReserve, kernel.buybackReserve());
            assertEq(buyback.ringCount(), beforeRingCount);
            assertEq(buyback.lastSuccessfulBuybackAt(), beforeLastSuccess);
            assertFalse(buyback.operationUsed(operationId));
        }
    }
}

contract Phase6C2G2BR6R2BInvariantTest is Phase6C2G2BR6R2BTest {
    R6R2BInvariantHandler private handler;
    uint256 private initialReserve;

    function setUp() public override {
        super.setUp();
        initialReserve = kernel.buybackReserve();
        handler = new R6R2BInvariantHandler(kernel, buyback, buyExecutor);
        targetContract(address(handler));
    }

    function invariant_BuybackSpendEqualsCommittedReserveDelta() public view {
        assertEq(initialReserve - kernel.buybackReserve(), handler.cumulativeSuccessfulSpend());
        assertEq(kernel.strategyCapital() + kernel.buybackReserve() + kernel.protocolReserve() + kernel.holderRewardReserve(), kernel.accountedQuote() + kernel.activePrincipal());
        assertGe(address(kernel).balance, kernel.accountedQuote());
        assertEq(address(buyExecutor).balance, 0);
    }

    function invariant_RollingSpendIsBoundedByFrozenCohort() public view {
        uint8 count = buyback.ringCount();
        assertLe(count, 4);
        uint256 total;
        for (uint8 i; i < count; ++i) {
            (, uint256 amount) = buyback.spendAt(i);
            assertGt(amount, 0);
            total += amount;
        }
        if (count != 0) assertLe(total, buyback.cohortReserveSnapshot() * 4_000 / 10_000);
    }
}
