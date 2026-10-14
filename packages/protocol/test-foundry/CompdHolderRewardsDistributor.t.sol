// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CompdProductionVault} from "../contracts/production/CompdProductionVault.sol";
import {CompdStrategyExecutor} from "../contracts/production/CompdStrategyExecutor.sol";
import {CompdBuybackExecutor} from "../contracts/production/CompdBuybackExecutor.sol";
import {CompdProductionVaultFactory} from "../contracts/flap/CompdProductionVaultFactory.sol";
import {CompdThinFlapReceiver} from "../contracts/flap/CompdThinFlapReceiver.sol";
import {CompdHolderRewardsDistributor} from "../contracts/production/CompdHolderRewardsDistributor.sol";
import {ICompdHolderRewardsDistributor as ID} from "../contracts/production/ICompdHolderRewardsDistributor.sol";
import {ICompdHolderRewardsVault as IVaultHolder} from "../contracts/production/ICompdProductionInterfaces.sol";
import {
    MockCompdToken,
    MockProductionERC20,
    MockEquityOracle,
    MockStrategyAdapter
} from "./fixtures/CompdProductionFixtures.sol";

/// @dev Test quote supports deterministic payout failures and swallowed callback attempts.
contract ControlledQuote is ERC20 {
    address public blockedRecipient;
    address public callbackRecipient;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    uint256 public callbackCount;

    constructor() ERC20("Holder Quote", "HQ") {}

    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function setBlockedRecipient(address recipient) external { blockedRecipient = recipient; }
    function setCallback(address recipient, address target, bytes calldata data) external {
        callbackRecipient = recipient;
        callbackTarget = target;
        callbackData = data;
        callbackSucceeded = false;
        callbackCount = 0;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0) && to == blockedRecipient) revert("payout blocked");
        super._update(from, to, value);
        if (from != address(0) && to == callbackRecipient && callbackTarget != address(0)) {
            ++callbackCount;
            (callbackSucceeded,) = callbackTarget.call(callbackData);
        }
    }
}

/// @dev Storage-free forwarding runtime is etched at the canonical Automation/Finalizer test identities.
contract Phase3Relay {
    function relay(address target, bytes calldata data) external returns (bool success, bytes memory result) {
        return target.call(data);
    }

    function relayBatch(address[] calldata targets, bytes[] calldata calls, bool[] calldata forwarded) external {
        require(targets.length == calls.length && targets.length == forwarded.length);
        for (uint256 i; i < targets.length; ++i) {
            (bool success, bytes memory result) = targets[i].call(calls[i]);
            if (forwarded[i]) {
                require(success, "forwarder failed");
                (bool nestedSuccess,) = abi.decode(result, (bool, bytes));
                require(!nestedSuccess, "unexpected forwarded nested success");
            } else {
                require(!success, "unexpected nested success");
            }
        }
    }
}

contract Phase3MerkleTreeBuilder {
    function build(ID.Leaf[] calldata leaves, address distributor) external view returns (bytes32 root, bytes32[][] memory proofs) {
        uint256 width = 1;
        while (width < leaves.length) width <<= 1;
        uint256 depth;
        for (uint256 n = width; n > 1; n >>= 1) ++depth;
        bytes32[][] memory levels = new bytes32[][](depth + 1);
        levels[0] = new bytes32[](width);
        for (uint16 i; i < width; ++i) {
            if (i < leaves.length) levels[0][i] = ID(distributor).hashLeaf(leaves[i]);
            else levels[0][i] = ID(distributor).hashPadding(leaves[0].domainSeparator, leaves[0].distributionId, leaves[0].commitmentVersion, i);
        }
        for (uint256 l; l < depth; ++l) {
            bytes32[] memory lower = levels[l];
            bytes32[] memory upper = new bytes32[](lower.length / 2);
            for (uint256 j; j < upper.length; ++j) upper[j] = ID(distributor).hashNode(lower[2 * j], lower[2 * j + 1]);
            levels[l + 1] = upper;
        }
        root = levels[depth][0];
        proofs = new bytes32[][](leaves.length);
        for (uint256 i; i < leaves.length; ++i) {
            bytes32[] memory proof = new bytes32[](depth);
            for (uint256 l; l < depth; ++l) proof[l] = levels[l][(i >> l) ^ 1];
            proofs[i] = proof;
        }
    }
}

contract Phase3LeafBuilder {
    struct Params {
        bytes32 domain;
        bytes32 distributionId;
        uint32 version;
        bytes32 windowId;
        uint64 windowStart;
        uint64 windowEnd;
        address rewardAsset;
        uint256 pool;
        bytes32 datasetHash;
    }

    function build(Params calldata p, uint256[] calldata amounts, address[] calldata recipients)
        external pure returns (ID.Leaf[] memory leaves)
    {
        leaves = new ID.Leaf[](amounts.length);
        for (uint16 i; i < amounts.length; ++i) {
            ID.Leaf memory leaf;
            leaf.domainSeparator = p.domain;
            leaf.distributionId = p.distributionId;
            leaf.commitmentVersion = p.version;
            leaf.windowId = p.windowId;
            leaf.windowStart = p.windowStart;
            leaf.windowEnd = p.windowEnd;
            leaf.rewardAsset = p.rewardAsset;
            leaf.windowPool = p.pool;
            leaf.finalizedTotalPayable = p.pool;
            leaf.recipientIndex = i;
            leaf.recipient = recipients[i];
            leaf.amount = amounts[i];
            leaf.datasetHash = p.datasetHash;
            leaf.algorithmVersion = 1;
            leaves[i] = leaf;
        }
    }
}

contract CompdHolderRewardsDistributorTest is Test {
    address private constant PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
    address private constant TAX_PROCESSOR = address(0xF1A9);
    address private constant GUARDIAN = 0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    address private constant AUTOMATION = 0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;
    address private constant FINALIZER = address(0xFA11);
    address private constant RECOVERY = 0xFa8706AA97B07cb29096381f9101784bA0d1332b;
    address private constant COMPD = 0x7b7Af51136574c91A12988989c0a08E98aE97777;
    uint64 private constant DAY_START = 10 days;
    uint256 private constant POOL = 0.1 ether;

    ControlledQuote private quote;
    MockProductionERC20 private market;
    CompdProductionVault private vault;
    CompdStrategyExecutor private strategy;
    CompdHolderRewardsDistributor private distributor;
    CompdProductionVaultFactory private factory;
    CompdThinFlapReceiver private receiver;
    MockStrategyAdapter private adapter;
    MockEquityOracle private oracle;
    Phase3MerkleTreeBuilder private treeBuilder;
    Phase3LeafBuilder private leafBuilder;
    bytes32 private windowId;
    uint64 private windowStart;
    uint64 private windowEnd;

    struct Tree { bytes32 root; bytes32[][] proofs; }

    function setUp() public {
        vm.chainId(56);
        vm.roll(10_000);
        vm.warp(DAY_START + 100);
        vm.deal(address(this), 100 ether);
        vm.deal(TAX_PROCESSOR, 10 ether);
        quote = new ControlledQuote();
        market = new MockProductionERC20("Holder Market", "HM", 18);
        MockCompdToken compd = new MockCompdToken(TAX_PROCESSOR);
        vm.etch(COMPD, address(compd).code);

        vault = new CompdProductionVault(address(quote), address(this));
        strategy = new CompdStrategyExecutor(address(vault), address(this));
        CompdBuybackExecutor buyback = new CompdBuybackExecutor(address(vault));
        factory = new CompdProductionVaultFactory(address(vault));
        vault.configureHolderRewardsActivation(1, bytes32(uint256(1)), DAY_START);
        distributor = new CompdHolderRewardsDistributor(address(vault), FINALIZER);
        treeBuilder = new Phase3MerkleTreeBuilder();
        leafBuilder = new Phase3LeafBuilder();
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
        receiver = CompdThinFlapReceiver(payable(factory.newVault(COMPD, address(quote), address(this), bytes(""))));
        _sendRevenue(100 ether);
        vault.grantRole(vault.HOLDER_REWARD_SETTLER_ROLE(), address(this));
        vm.prank(GUARDIAN);
        vault.resume();
        (windowId, windowStart, windowEnd) = _settleProfit(1 ether, 1 ether);
        vm.warp(windowEnd);
        excludeContract(address(compd)); excludeContract(COMPD); excludeContract(address(quote)); excludeContract(address(market));
        excludeContract(address(vault)); excludeContract(address(strategy)); excludeContract(address(buyback));
        excludeContract(address(distributor)); excludeContract(address(factory)); excludeContract(address(receiver));
        excludeContract(address(adapter)); excludeContract(address(oracle));
        excludeContract(address(treeBuilder)); excludeContract(address(leafBuilder));
    }

    function testCanonicalDomainAndLeftRightPositionalProofsExecuteExactly() public {
        ID.Leaf[] memory leaves = _leaves(1, 2, _amounts(0.04 ether, 0.06 ether), _recipients());
        Tree memory tree = _tree(leaves);
        bytes32 expectedLeafHash = keccak256(abi.encode(
            keccak256(bytes("CompdHolderRewardLeaf(bytes32 domainSeparator,bytes32 distributionId,uint32 commitmentVersion,bytes32 windowId,uint64 windowStart,uint64 windowEnd,address rewardAsset,uint256 windowPool,uint256 finalizedTotalPayable,uint16 recipientIndex,address recipient,uint256 amount,bytes32 datasetHash,uint32 algorithmVersion)")),
            leaves[0].domainSeparator, leaves[0].distributionId, leaves[0].commitmentVersion, leaves[0].windowId,
            leaves[0].windowStart, leaves[0].windowEnd, leaves[0].rewardAsset, leaves[0].windowPool,
            leaves[0].finalizedTotalPayable, leaves[0].recipientIndex, leaves[0].recipient, leaves[0].amount,
            leaves[0].datasetHash, leaves[0].algorithmVersion
        ));
        assertEq(distributor.hashLeaf(leaves[0]), expectedLeafHash);
        assertTrue(tree.proofs[0][0] == distributor.hashLeaf(leaves[1]));
        assertTrue(tree.proofs[1][0] == distributor.hashLeaf(leaves[0]));
        _submitAndMaterialize(leaves, tree, 2);
        ID.CommitmentView memory c = distributor.candidate(leaves[0].distributionId);
        assertEq(c.domainSeparator, vault.holderDomainSeparator());
        assertEq(c.root, tree.root);
        assertEq(uint8(c.status), uint8(ID.CandidateStatus.REVIEW));
        _finalize(leaves[0].distributionId, c.executableAfter);
        vm.prank(AUTOMATION);
        assertTrue(distributor.executeProof(leaves[0].distributionId, leaves[0], tree.proofs[0]));
        vm.prank(AUTOMATION);
        assertTrue(distributor.executeProof(leaves[0].distributionId, leaves[1], tree.proofs[1]));
        assertEq(quote.balanceOf(leaves[0].recipient), 0.04 ether);
        assertEq(quote.balanceOf(leaves[1].recipient), 0.06 ether);
        vm.prank(AUTOMATION);
        vm.expectRevert();
        distributor.executeProof(leaves[0].distributionId, leaves[0], tree.proofs[0]);
        vm.prank(FINALIZER); vm.expectRevert(); distributor.correctCandidate(leaves[0].distributionId, _replacement(tree.root, 2));
        vm.expectRevert(); vault.markManualSettlementAvailable(leaves[0].distributionId, 1, leaves[0].windowId, 0);
        _assertBuckets();
    }

    function testOnlyFinalizerCanSubmitMaterializeFinalizeAndCorrect() public {
        assertTrue(distributor.hasRole(distributor.DISTRIBUTION_FINALIZER_ROLE(), FINALIZER));
        assertFalse(distributor.hasRole(distributor.DISTRIBUTION_FINALIZER_ROLE(), AUTOMATION));
        assertFalse(distributor.hasRole(distributor.DEFAULT_ADMIN_ROLE(), address(this)));
        bytes32 finalizerRole = distributor.DISTRIBUTION_FINALIZER_ROLE();
        vm.prank(FINALIZER); vm.expectRevert();
        distributor.grantRole(finalizerRole, address(0xBAD));
        ID.Leaf[] memory leaves = _leaves(1, 1, _amounts(POOL), _recipients());
        Tree memory tree = _tree(leaves);
        ID.CandidateInput memory input = _candidate(leaves, tree.root, 1);
        vm.prank(address(0xBAD)); vm.expectRevert(); distributor.submitCandidate(input);
        vm.prank(AUTOMATION); vm.expectRevert(); distributor.submitCandidate(input);
        vm.prank(FINALIZER); distributor.submitCandidate(input);
        vm.prank(address(0xBAD)); vm.expectRevert(); distributor.materializeLeaf(input.distributionId, leaves[0], tree.proofs[0]);
        vm.prank(AUTOMATION); vm.expectRevert(); distributor.materializeLeaf(input.distributionId, leaves[0], tree.proofs[0]);
        vm.prank(FINALIZER); distributor.materializeLeaf(input.distributionId, leaves[0], tree.proofs[0]);
        ID.ReplacementInput memory replacement = ID.ReplacementInput(2, 1, 1, bytes32(uint256(9)), bytes32(uint256(8)), 1, bytes32(uint256(7)));
        vm.prank(AUTOMATION); vm.expectRevert(); distributor.correctCandidate(input.distributionId, replacement);
        vm.prank(address(0xBAD)); vm.expectRevert(); distributor.finalizeCandidate(input.distributionId);
    }

    function testWrongContextAndCandidateFieldsFailClosed() public {
        ID.Leaf[] memory leaves = _leaves(1, 1, _amounts(POOL), _recipients());
        Tree memory tree = _tree(leaves);
        ID.CandidateInput memory good = _candidate(leaves, tree.root, 1);
        ID.CandidateInput memory bad = good; bad.domainSeparator = bytes32(uint256(1)); _expectBadCandidate(bad);
        bad = good; bad.distributionId = bytes32(uint256(2)); _expectBadCandidate(bad);
        bad = good; bad.commitmentVersion = 2; _expectBadCandidate(bad);
        bad = good; bad.windowId = bytes32(uint256(3)); _expectBadCandidate(bad);
        bad = good; bad.windowStart += 1; _expectBadCandidate(bad);
        bad = good; bad.rewardAsset = address(0xA55); _expectBadCandidate(bad);
        bad = good; bad.windowPool += 1; _expectBadCandidate(bad);
        bad = good; bad.finalizedTotalPayable -= 1; _expectBadCandidate(bad);
        bad = good; bad.recipientCount = 31; _expectBadCandidate(bad);
        bad = good; bad.positiveEntryCount = 2; _expectBadCandidate(bad);
        bad = good; bad.root = bytes32(0); _expectBadCandidate(bad);
        bad = good; bad.datasetHash = bytes32(0); _expectBadCandidate(bad);
        bad = good; bad.algorithmVersion = 2; _expectBadCandidate(bad);
        bytes32 otherCompd = keccak256(abi.encode(distributor.DOMAIN_TYPEHASH(), distributor.PROTOCOL_ID(), uint256(56), address(0xC0), address(vault), address(distributor), address(quote)));
        bad = good; bad.domainSeparator = otherCompd; _expectBadCandidate(bad);
        bytes32 otherVault = keccak256(abi.encode(distributor.DOMAIN_TYPEHASH(), distributor.PROTOCOL_ID(), uint256(56), COMPD, address(0xA0), address(distributor), address(quote)));
        bad = good; bad.domainSeparator = otherVault; _expectBadCandidate(bad);
        bytes32 otherDistributor = keccak256(abi.encode(distributor.DOMAIN_TYPEHASH(), distributor.PROTOCOL_ID(), uint256(56), COMPD, address(vault), address(0xD1), address(quote)));
        bad = good; bad.domainSeparator = otherDistributor; _expectBadCandidate(bad);
        bytes32 otherAsset = keccak256(abi.encode(distributor.DOMAIN_TYPEHASH(), distributor.PROTOCOL_ID(), uint256(56), COMPD, address(vault), address(distributor), address(0xA55)));
        bad = good; bad.domainSeparator = otherAsset; _expectBadCandidate(bad);
        uint256 oldChain = block.chainid;
        vm.chainId(97);
        _expectBadCandidate(good);
        vm.chainId(oldChain);
        _assertBuckets();
    }

    function testInvalidProofAndMutatedLeafNeverCreateLiability() public {
        ID.Leaf[] memory leaves = _leaves(1, 2, _amounts(0.04 ether, 0.06 ether), _recipients());
        Tree memory tree = _tree(leaves);
        _submit(leaves, tree.root, 2);
        uint256 beforeLiability = vault.holderCandidateReviewPoolTotal();
        ID.Leaf memory changed = _copyLeaf(leaves[0]); changed.amount += 1;
        vm.prank(FINALIZER); vm.expectRevert(); distributor.materializeLeaf(leaves[0].distributionId, changed, tree.proofs[0]);
        changed = _copyLeaf(leaves[0]); changed.recipientIndex = 1;
        vm.prank(FINALIZER); vm.expectRevert(); distributor.materializeLeaf(leaves[0].distributionId, changed, tree.proofs[0]);
        changed = _copyLeaf(leaves[0]); changed.recipient = address(0xBAD);
        vm.prank(FINALIZER); vm.expectRevert(); distributor.materializeLeaf(leaves[0].distributionId, changed, tree.proofs[0]);
        changed = _copyLeaf(leaves[0]); changed.commitmentVersion = 2;
        vm.prank(FINALIZER); vm.expectRevert(); distributor.materializeLeaf(leaves[0].distributionId, changed, tree.proofs[0]);
        changed = _copyLeaf(leaves[0]); changed.distributionId = bytes32(uint256(999));
        vm.prank(FINALIZER); vm.expectRevert(); distributor.materializeLeaf(leaves[0].distributionId, changed, tree.proofs[0]);
        changed = _copyLeaf(leaves[0]); changed.windowId = bytes32(uint256(998));
        vm.prank(FINALIZER); vm.expectRevert(); distributor.materializeLeaf(leaves[0].distributionId, changed, tree.proofs[0]);
        changed = _copyLeaf(leaves[0]); changed.datasetHash = bytes32(uint256(997));
        vm.prank(FINALIZER); vm.expectRevert(); distributor.materializeLeaf(leaves[0].distributionId, changed, tree.proofs[0]);
        vm.prank(FINALIZER); vm.expectRevert(); distributor.materializeLeaf(leaves[0].distributionId, leaves[0], tree.proofs[1]);
        bytes32[] memory malformed = new bytes32[](2); malformed[0] = tree.proofs[0][0];
        vm.prank(FINALIZER); vm.expectRevert(); distributor.materializeLeaf(leaves[0].distributionId, leaves[0], malformed);
        vm.prank(FINALIZER); distributor.materializeLeaf(leaves[0].distributionId, leaves[0], tree.proofs[0]);
        vm.prank(FINALIZER); vm.expectRevert(); distributor.materializeLeaf(leaves[0].distributionId, leaves[0], tree.proofs[0]);
        assertEq(vault.holderCandidateReviewPoolTotal(), beforeLiability);
        assertEq(uint8(vault.holderRewardEntry(leaves[0].distributionId, 1).status), uint8(IVaultHolder.HolderEntryStatus.NONE));
        _assertBuckets();
    }

    function testArbitraryWrongRootCannotMaterialize() public {
        ID.Leaf[] memory leaves = _leaves(1, 1, _amounts(POOL), _oneRecipient(address(0xCAFE)));
        Tree memory tree = _tree(leaves);
        _submit(leaves, bytes32(uint256(123)), 1);
        vm.prank(FINALIZER); vm.expectRevert(); distributor.materializeLeaf(leaves[0].distributionId, leaves[0], tree.proofs[0]);
        assertEq(vault.holderRewardEntry(leaves[0].distributionId, 0).amount, 0);
        _assertBuckets();
    }

    function testZeroAmountLeafNeedsProofButDoesNotCreateVaultEntry() public {
        address[] memory recipients = _recipients();
        uint256[] memory amounts = _amounts(POOL, 0);
        ID.Leaf[] memory leaves = _leaves(1, 2, amounts, recipients);
        Tree memory tree = _tree(leaves);
        _submit(leaves, tree.root, 1);
        vm.prank(FINALIZER); distributor.materializeLeaf(leaves[0].distributionId, leaves[0], tree.proofs[0]);
        vm.warp(distributor.candidate(leaves[0].distributionId).executableAfter);
        vm.prank(FINALIZER); vm.expectRevert(); distributor.finalizeCandidate(leaves[0].distributionId);
        vm.prank(FINALIZER); distributor.materializeLeaf(leaves[0].distributionId, leaves[1], tree.proofs[1]);
        assertEq(uint8(vault.holderRewardEntry(leaves[0].distributionId, 1).status), uint8(IVaultHolder.HolderEntryStatus.NONE));
        uint64 deadline = distributor.candidate(leaves[0].distributionId).executableAfter;
        _finalize(leaves[0].distributionId, deadline);
        vm.prank(AUTOMATION); vm.expectRevert(); distributor.executeProof(leaves[0].distributionId, leaves[1], tree.proofs[1]);
        _assertBuckets();
    }

    function testZeroRecipientCannotBeProvenIntoVault() public {
        ID.Leaf[] memory leaves = _leaves(1, 1, _amounts(POOL), _oneRecipient(address(0)));
        Tree memory tree = _tree(leaves);
        _submit(leaves, tree.root, 1);
        vm.prank(FINALIZER); vm.expectRevert(CompdHolderRewardsDistributor.InvalidCandidate.selector);
        distributor.materializeLeaf(leaves[0].distributionId, leaves[0], tree.proofs[0]);
        assertEq(vault.holderRewardEntry(leaves[0].distributionId, 0).amount, 0);
        _assertBuckets();
    }

    function testDuplicateRecipientAndOverThirtyRecipientsRejected() public {
        address[] memory recipients = _recipients();
        recipients[1] = recipients[0];
        ID.Leaf[] memory leaves = _leaves(1, 2, _amounts(0.04 ether, 0.06 ether), recipients);
        Tree memory tree = _tree(leaves);
        _submit(leaves, tree.root, 2);
        vm.prank(FINALIZER); distributor.materializeLeaf(leaves[0].distributionId, leaves[0], tree.proofs[0]);
        vm.prank(FINALIZER); vm.expectRevert(CompdHolderRewardsDistributor.DuplicateRecipient.selector);
        distributor.materializeLeaf(leaves[0].distributionId, leaves[1], tree.proofs[1]);
        leaves = _leaves(1, 31, new uint256[](31), new address[](31));
        ID.CandidateInput memory tooMany = _candidate(leaves, bytes32(uint256(3)), 1);
        vm.prank(FINALIZER); vm.expectRevert(); distributor.submitCandidate(tooMany);
    }

    function testAggregateExcessCannotCompleteOrCreateExcessLiability() public {
        ID.Leaf[] memory leaves = _leaves(1, 2, _amounts(0.06 ether, 0.06 ether), _recipients());
        Tree memory tree = _tree(leaves);
        _submit(leaves, tree.root, 2);
        vm.prank(FINALIZER); distributor.materializeLeaf(leaves[0].distributionId, leaves[0], tree.proofs[0]);
        vm.prank(FINALIZER); vm.expectRevert(); distributor.materializeLeaf(leaves[0].distributionId, leaves[1], tree.proofs[1]);
        ID.CommitmentView memory c = distributor.candidate(leaves[0].distributionId);
        assertEq(uint8(c.status), uint8(ID.CandidateStatus.MATERIALIZING));
        assertEq(c.materializedAmount, 0.06 ether);
        assertEq(vault.holderRewardEntry(leaves[0].distributionId, 1).amount, 0);
        vm.warp(c.executableAfter);
        vm.prank(FINALIZER); vm.expectRevert(); distributor.finalizeCandidate(leaves[0].distributionId);
        _assertBuckets();
    }

    function testThirtyRecipientsAndPaddingPathsMaterializeExactly() public {
        uint256[] memory amounts = new uint256[](30);
        address[] memory recipients = new address[](30);
        for (uint16 i; i < 30; ++i) { recipients[i] = address(uint160(0x1000 + i)); amounts[i] = i == 29 ? POOL - 29 : 1; }
        ID.Leaf[] memory leaves = _leaves(1, 30, amounts, recipients);
        Tree memory tree = _tree(leaves);
        _submitAndMaterialize(leaves, tree, 30);
        ID.CommitmentView memory c = distributor.candidate(leaves[0].distributionId);
        assertEq(c.verifiedLeafCount, 30);
        assertEq(c.materializedEntryCount, 30);
        assertEq(c.materializedAmount, POOL);
        _assertBuckets();
    }

    function testCorrectionV2IsAtomicSupersedesProofAndRestartsFullReview() public {
        ID.Leaf[] memory v1 = _leaves(1, 2, _amounts(0.04 ether, 0.06 ether), _recipients());
        Tree memory t1 = _tree(v1);
        _submitAndMaterialize(v1, t1, 2);
        ID.Leaf[] memory v2 = _leaves(2, 1, _amounts(POOL), _oneRecipient(address(0xCAFE)));
        Tree memory t2 = _tree(v2);
        ID.ReplacementInput memory replacement = ID.ReplacementInput(2, 1, 1, t2.root, v2[0].datasetHash, 1, keccak256("correction-1"));
        uint64 firstDeadline = distributor.candidate(v1[0].distributionId).executableAfter;
        uint256 vaultQuoteBefore = quote.balanceOf(address(vault));
        uint256 accountedBefore = vault.accountedQuote();
        uint256 holderReserveBefore = vault.holderRewardReserve();
        uint256 strategyBefore = vault.strategyCapital();
        uint256 buybackBefore = vault.buybackReserve();
        uint256 protocolBefore = vault.protocolReserve();
        vm.warp(block.timestamp + 100);
        vm.prank(FINALIZER); distributor.correctCandidate(v1[0].distributionId, replacement);
        ID.CommitmentView memory c2 = distributor.candidate(v1[0].distributionId);
        assertEq(c2.commitmentVersion, 2);
        assertEq(vault.holderDistributionVersion(v1[0].distributionId), 2);
        assertEq(c2.root, t2.root);
        assertEq(distributor.rootByVersion(v1[0].distributionId, 1), t1.root);
        assertEq(distributor.rootByVersion(v1[0].distributionId, 2), t2.root);
        assertEq(c2.acceptedAt, block.timestamp);
        assertEq(c2.executableAfter, block.timestamp + 1_800);
        assertTrue(c2.executableAfter > firstDeadline);
        assertEq(quote.balanceOf(address(vault)), vaultQuoteBefore);
        assertEq(vault.accountedQuote(), accountedBefore);
        assertEq(vault.holderRewardReserve(), holderReserveBefore);
        assertEq(vault.strategyCapital(), strategyBefore);
        assertEq(vault.buybackReserve(), buybackBefore);
        assertEq(vault.protocolReserve(), protocolBefore);
        vm.prank(AUTOMATION); vm.expectRevert(); distributor.executeProof(v1[0].distributionId, v1[0], t1.proofs[0]);
        vm.prank(FINALIZER); vm.expectRevert(); distributor.materializeLeaf(v1[0].distributionId, v1[0], t1.proofs[0]);
        vm.prank(address(distributor)); vm.expectRevert();
        vault.payCommittedHolderEntry(v1[0].distributionId, 1, v1[0].windowId, 0, v1[0].recipient, address(quote), v1[0].amount);
        vm.prank(FINALIZER); distributor.materializeLeaf(v2[0].distributionId, v2[0], t2.proofs[0]);
        vm.warp(c2.executableAfter - 1);
        vm.prank(FINALIZER); vm.expectRevert(); distributor.finalizeCandidate(v1[0].distributionId);
        vm.warp(c2.executableAfter);
        vm.prank(FINALIZER); distributor.finalizeCandidate(v1[0].distributionId);
        vm.prank(AUTOMATION); assertTrue(distributor.executeProof(v2[0].distributionId, v2[0], t2.proofs[0]));

        replacement.commitmentVersion = 4;
        vm.prank(FINALIZER); vm.expectRevert(); distributor.correctCandidate(v1[0].distributionId, replacement);
        assertEq(distributor.candidate(v1[0].distributionId).commitmentVersion, 2);
        assertEq(vault.holderDistributionVersion(v1[0].distributionId), 2);
        _assertBuckets();
    }

    function testCorrectionAfterSuccessOrAutomaticFailureIsLockedAndNoRetry() public {
        ID.Leaf[] memory leaves = _leaves(1, 2, _amounts(0.04 ether, 0.06 ether), _recipients());
        Tree memory tree = _tree(leaves);
        _submitAndMaterialize(leaves, tree, 2);
        uint64 deadline = distributor.candidate(leaves[0].distributionId).executableAfter;
        _finalize(leaves[0].distributionId, deadline);
        address failedRecipient = leaves[1].recipient;
        quote.setBlockedRecipient(failedRecipient);
        vm.prank(AUTOMATION); assertFalse(distributor.executeProof(leaves[0].distributionId, leaves[1], tree.proofs[1]));
        assertEq(uint8(vault.holderRewardEntry(leaves[0].distributionId, 1).status), uint8(IVaultHolder.HolderEntryStatus.FAILED_PENDING_MANUAL));
        vm.prank(AUTOMATION); assertTrue(distributor.executeProof(leaves[0].distributionId, leaves[0], tree.proofs[0]));
        assertEq(quote.balanceOf(leaves[0].recipient), 0.04 ether);
        vm.expectRevert();
        vault.markManualSettlementAvailable(leaves[0].distributionId, 1, leaves[0].windowId, 0);
        uint256 vaultBalance = quote.balanceOf(address(vault));
        assertEq(vaultBalance, vault.accountedQuote());
        vm.prank(AUTOMATION); vm.expectRevert(); distributor.executeProof(leaves[0].distributionId, leaves[1], tree.proofs[1]);
        ID.ReplacementInput memory replacement = ID.ReplacementInput(2, 1, 1, bytes32(uint256(2)), bytes32(uint256(3)), 1, bytes32(uint256(4)));
        vm.prank(FINALIZER); vm.expectRevert(); distributor.correctCandidate(leaves[0].distributionId, replacement);
        quote.setBlockedRecipient(address(0));
        vault.markManualSettlementAvailable(leaves[0].distributionId, 1, leaves[0].windowId, 1);
        vault.settleFailedHolderEntry(leaves[0].distributionId, 1, leaves[0].windowId, 1,
            leaves[1].recipient, address(quote), leaves[1].amount);
        vm.prank(AUTOMATION); vm.expectRevert(); distributor.executeProof(leaves[0].distributionId, leaves[1], tree.proofs[1]);
        assertEq(quote.balanceOf(failedRecipient), 0.06 ether);
        _assertBuckets();
    }

    function testCorrectionAfterTerminalStartIsLocked() public {
        ID.Leaf[] memory leaves = _leaves(1, 1, _amounts(POOL), _oneRecipient(address(0xCAFE)));
        Tree memory tree = _tree(leaves);
        _submitAndMaterialize(leaves, tree, 1);
        uint64 deadline = distributor.candidate(leaves[0].distributionId).executableAfter;
        _finalize(leaves[0].distributionId, deadline);
        quote.setBlockedRecipient(leaves[0].recipient);
        vm.prank(AUTOMATION); assertFalse(distributor.executeProof(leaves[0].distributionId, leaves[0], tree.proofs[0]));
        vault.markManualSettlementAvailable(leaves[0].distributionId, 1, windowId, 0);
        vm.prank(GUARDIAN); vault.initiateShutdown();
        vm.warp(vault.shutdownAt());
        vm.prank(GUARDIAN); vault.terminate();
        vm.prank(address(distributor)); vault.startTerminalHolderLiability(leaves[0].distributionId, 1, windowId, 0);
        ID.ReplacementInput memory replacement = _replacement(tree.root, 2);
        vm.prank(FINALIZER); vm.expectRevert(); distributor.correctCandidate(leaves[0].distributionId, replacement);
        assertEq(uint8(vault.holderRewardEntry(leaves[0].distributionId, 0).status), uint8(IVaultHolder.HolderEntryStatus.TERMINAL_PENDING));
        _assertBuckets();
    }

    function testGuardianAndSettlerCannotRewriteRootOrExecutePayout() public {
        ID.Leaf[] memory leaves = _leaves(1, 1, _amounts(POOL), _recipients());
        Tree memory tree = _tree(leaves);
        _submitAndMaterialize(leaves, tree, 1);
        vm.prank(GUARDIAN); vm.expectRevert(); distributor.correctCandidate(leaves[0].distributionId, _replacement(tree.root, 2));
        vm.prank(address(this)); vm.expectRevert(); distributor.executeProof(leaves[0].distributionId, leaves[0], tree.proofs[0]);
        _assertBuckets();
    }

    function testReviewDeadlineUsesExactVaultBoundaryAndCannotBeBypassed() public {
        ID.Leaf[] memory leaves = _leaves(1, 1, _amounts(POOL), _recipients());
        Tree memory tree = _tree(leaves);
        _submitAndMaterialize(leaves, tree, 1);
        uint64 deadline = distributor.candidate(leaves[0].distributionId).executableAfter;
        vm.warp(deadline - 1);
        vm.prank(FINALIZER); vm.expectRevert(); distributor.finalizeCandidate(leaves[0].distributionId);
        vm.prank(AUTOMATION); vm.expectRevert(); distributor.executeProof(leaves[0].distributionId, leaves[0], tree.proofs[0]);
        vm.warp(deadline);
        vm.prank(FINALIZER); distributor.finalizeCandidate(leaves[0].distributionId);
        vm.prank(AUTOMATION); assertTrue(distributor.executeProof(leaves[0].distributionId, leaves[0], tree.proofs[0]));
        _assertBuckets();
    }

    function testFuzz_InvalidAmountProofNeverCreatesLiability(uint96 delta) public {
        ID.Leaf[] memory leaves = _leaves(1, 2, _amounts(0.04 ether, 0.06 ether), _recipients());
        Tree memory tree = _tree(leaves);
        _submit(leaves, tree.root, 2);
        uint256 beforeQuote = quote.balanceOf(address(vault));
        uint256 beforePool = vault.holderCandidateReviewPoolTotal();
        ID.Leaf memory altered = leaves[0]; altered.amount += uint256(delta) + 1;
        vm.prank(FINALIZER); vm.expectRevert(); distributor.materializeLeaf(leaves[0].distributionId, altered, tree.proofs[0]);
        assertEq(quote.balanceOf(address(vault)), beforeQuote);
        assertEq(vault.holderCandidateReviewPoolTotal(), beforePool);
        assertEq(uint8(vault.holderRewardEntry(leaves[0].distributionId, 0).status), uint8(IVaultHolder.HolderEntryStatus.NONE));
        _assertBuckets();
    }

    function testFuzz_CorrectionRejectsEveryNonSequentialVersion(uint32 requested) public {
        ID.Leaf[] memory leaves = _leaves(1, 1, _amounts(POOL), _recipients());
        Tree memory tree = _tree(leaves);
        _submitAndMaterialize(leaves, tree, 1);
        ID.ReplacementInput memory replacement = _replacement(tree.root, requested);
        if (requested != 2) {
            vm.prank(FINALIZER); vm.expectRevert(); distributor.correctCandidate(leaves[0].distributionId, replacement);
            assertEq(vault.holderDistributionVersion(leaves[0].distributionId), 1);
            assertEq(distributor.candidate(leaves[0].distributionId).commitmentVersion, 1);
        }
        _assertBuckets();
    }

    function testNestedSameLeafCrossLeafCorrectionAndMaterializationAllFailClosed() public {
        vm.etch(AUTOMATION, type(Phase3Relay).runtimeCode);
        vm.etch(FINALIZER, type(Phase3Relay).runtimeCode);
        ID.Leaf[] memory leaves = _leaves(1, 2, _amounts(0.04 ether, 0.06 ether), _recipients());
        Tree memory tree = _tree(leaves);
        _submitAndMaterialize(leaves, tree, 2);
        uint64 deadline = distributor.candidate(leaves[0].distributionId).executableAfter;
        _finalize(leaves[0].distributionId, deadline);
        bytes memory sameLeaf = abi.encodeCall(distributor.executeProof, (leaves[0].distributionId, leaves[0], tree.proofs[0]));
        bytes memory crossLeaf = abi.encodeCall(distributor.executeProof, (leaves[0].distributionId, leaves[1], tree.proofs[1]));
        ID.Leaf[] memory v2 = _leaves(2, 2, _amounts(0.04 ether, 0.06 ether), _recipients());
        Tree memory t2 = _tree(v2);
        ID.ReplacementInput memory replacement = ID.ReplacementInput(2, 2, 2, t2.root, v2[0].datasetHash, 1, keccak256("nested-correction"));
        bytes memory nestedCorrection = abi.encodeCall(distributor.correctCandidate, (leaves[0].distributionId, replacement));
        bytes memory finalizerCorrection = abi.encodeCall(Phase3Relay.relay, (address(distributor), nestedCorrection));
        bytes memory nestedMaterialize = abi.encodeCall(distributor.materializeLeaf, (leaves[0].distributionId, leaves[1], tree.proofs[1]));
        bytes memory finalizerMaterialize = abi.encodeCall(Phase3Relay.relay, (address(distributor), nestedMaterialize));
        address[] memory targets = new address[](4);
        bytes[] memory calls = new bytes[](4);
        bool[] memory forwarded = new bool[](4);
        targets[0] = address(distributor); calls[0] = sameLeaf;
        targets[1] = address(distributor); calls[1] = crossLeaf;
        targets[2] = FINALIZER; calls[2] = finalizerCorrection;
        targets[3] = FINALIZER; calls[3] = finalizerMaterialize;
        forwarded[2] = true; forwarded[3] = true;
        quote.setCallback(leaves[0].recipient, AUTOMATION, abi.encodeCall(Phase3Relay.relayBatch, (targets, calls, forwarded)));
        vm.prank(AUTOMATION); assertTrue(distributor.executeProof(leaves[0].distributionId, leaves[0], tree.proofs[0]));
        assertEq(quote.callbackCount(), 1); assertTrue(quote.callbackSucceeded());
        assertEq(quote.balanceOf(leaves[0].recipient), 0.04 ether);
        assertEq(quote.balanceOf(leaves[1].recipient), 0);
        assertEq(vault.holderDistributionVersion(leaves[0].distributionId), 1);
        assertEq(distributor.candidate(leaves[0].distributionId).commitmentVersion, 1);
        _assertBuckets();
    }

    function _expectBadCandidate(ID.CandidateInput memory bad) private {
        vm.prank(FINALIZER); vm.expectRevert(); distributor.submitCandidate(bad);
    }

    function _fundWindow() private view {}

    function _submit(ID.Leaf[] memory leaves, bytes32 root, uint16 positiveCount) private {
        ID.CandidateInput memory input = _candidate(leaves, root, positiveCount);
        vm.prank(FINALIZER); distributor.submitCandidate(input);
    }

    function _submitAndMaterialize(ID.Leaf[] memory leaves, Tree memory tree, uint16 positiveCount) private {
        _submit(leaves, tree.root, positiveCount);
        for (uint16 i; i < leaves.length; ++i) {
            vm.prank(FINALIZER); distributor.materializeLeaf(leaves[0].distributionId, leaves[i], tree.proofs[i]);
        }
    }

    function _finalize(bytes32 id, uint64 deadline) private {
        vm.warp(deadline);
        vm.prank(FINALIZER); distributor.finalizeCandidate(id);
    }

    function _candidate(ID.Leaf[] memory leaves, bytes32 root, uint16 positiveCount)
        private view returns (ID.CandidateInput memory c)
    {
        ID.Leaf memory first = leaves[0];
        c.domainSeparator = vault.holderDomainSeparator();
        c.distributionId = first.distributionId;
        c.commitmentVersion = first.commitmentVersion;
        c.windowId = first.windowId;
        c.windowStart = first.windowStart;
        c.windowEnd = first.windowEnd;
        c.rewardAsset = address(quote);
        c.windowPool = POOL;
        c.finalizedTotalPayable = POOL;
        c.recipientCount = uint16(leaves.length);
        c.positiveEntryCount = positiveCount;
        c.root = root;
        c.datasetHash = first.datasetHash;
        c.algorithmVersion = 1;
    }

    function _leaves(uint32 version, uint16 count, uint256[] memory amounts, address[] memory recipients)
        private view returns (ID.Leaf[] memory leaves)
    {
        bytes32 domain = vault.holderDomainSeparator();
        bytes32 id = keccak256(abi.encode(vault.HOLDER_DISTRIBUTION_TYPEHASH(), domain, windowId));
        bytes32 dataset = keccak256(abi.encode("test-dataset", version, count));
        Phase3LeafBuilder.Params memory p = Phase3LeafBuilder.Params(
            domain, id, version, windowId, windowStart, windowEnd, address(quote), POOL, dataset
        );
        leaves = leafBuilder.build(p, amounts, recipients);
    }

    function _tree(ID.Leaf[] memory leaves) private view returns (Tree memory result) {
        (result.root, result.proofs) = treeBuilder.build(leaves, address(distributor));
    }

    function _amounts(uint256 a) private pure returns (uint256[] memory v) { v = new uint256[](1); v[0] = a; }
    function _amounts(uint256 a, uint256 b) private pure returns (uint256[] memory v) { v = new uint256[](2); v[0] = a; v[1] = b; }
    function _recipients() private pure returns (address[] memory v) { v = new address[](2); v[0] = address(0xA11CE); v[1] = address(0xB0B); }
    function _oneRecipient(address a) private pure returns (address[] memory v) { v = new address[](1); v[0] = a; }
    function _replacement(bytes32 root, uint32 version) private pure returns (ID.ReplacementInput memory) {
        return ID.ReplacementInput(version, 1, 1, root, keccak256("replacement-dataset"), 1, keccak256("replacement-reason"));
    }

    function _copyLeaf(ID.Leaf memory leaf) private pure returns (ID.Leaf memory) {
        return ID.Leaf(leaf.domainSeparator, leaf.distributionId, leaf.commitmentVersion, leaf.windowId,
            leaf.windowStart, leaf.windowEnd, leaf.rewardAsset, leaf.windowPool, leaf.finalizedTotalPayable,
            leaf.recipientIndex, leaf.recipient, leaf.amount, leaf.datasetHash, leaf.algorithmVersion);
    }

    function _settleProfit(uint256 principal, uint256 profit) private returns (bytes32 id, uint64 start, uint64 end) {
        vm.prank(AUTOMATION);
        uint256 run = strategy.openPosition(keccak256("HOLDER_TEST_MARKET"), address(market), principal, principal);
        adapter.setReturn(run, principal + profit);
        oracle.set(1_000 ether, block.timestamp);
        vm.prank(AUTOMATION); strategy.closePosition(run);
        start = uint64(uint256(block.timestamp) / vault.HOLDER_WINDOW_SECONDS() * vault.HOLDER_WINDOW_SECONDS());
        end = start + vault.HOLDER_WINDOW_SECONDS();
        id = vault.holderWindowId(start, end);
    }

    function _sendRevenue(uint256 amount) private {
        quote.mint(address(receiver), amount);
        vm.prank(TAX_PROCESSOR); (bool ok,) = address(receiver).call(""); assertTrue(ok);
    }

    function _assertBuckets() private view {
        assertEq(vault.strategyCapital() + vault.buybackReserve() + vault.protocolReserve() + vault.holderRewardReserve(), vault.accountedQuote() + vault.activePrincipal());
        assertGe(quote.balanceOf(address(vault)), vault.accountedQuote());
        assertEq(vault.holderUnfinalizedWindowPoolTotal() + vault.holderCandidateReviewPoolTotal() + vault.holderFinalizedUnpaidLiabilityTotal() + vault.holderUnallocatedNoRecipientPoolTotal() + vault.holderRecoveryEligibleTotal(), vault.holderRewardReserve());
    }
}

contract Phase3DistributorInvariantHandler is Test {
    address private constant FINALIZER = address(0xFA11);
    CompdHolderRewardsDistributor private immutable distributor;
    bytes32 private immutable distributionId;
    ID.Leaf private _leaf;

    constructor(CompdHolderRewardsDistributor distributor_, ID.Leaf memory leaf_) {
        distributor = distributor_;
        distributionId = leaf_.distributionId;
        _leaf = leaf_;
    }

    function attemptMutatedProof(uint96 rawDelta, uint16 index) external {
        ID.Leaf memory altered = _leaf;
        altered.amount += uint256(rawDelta) + 1;
        altered.recipientIndex = index;
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(FINALIZER);
        (bool ok,) = address(distributor).call(abi.encodeCall(ID.materializeLeaf, (distributionId, altered, proof)));
        require(!ok, "invalid proof materialized");
    }
}

contract CompdHolderRewardsDistributorInvariantTest is Test {
    address private constant PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
    address private constant TAX_PROCESSOR = address(0xF1A9);
    address private constant GUARDIAN = 0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;
    address private constant AUTOMATION = 0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;
    address private constant FINALIZER = address(0xFA11);
    address private constant COMPD = 0x7b7Af51136574c91A12988989c0a08E98aE97777;
    uint64 private constant START = 10 days;
    uint256 private constant POOL = 0.1 ether;

    ControlledQuote private quote;
    MockProductionERC20 private market;
    MockCompdToken private mockCompd;
    CompdProductionVault private vault;
    CompdHolderRewardsDistributor private distributor;
    bytes32 private distributionId;
    bytes32 private root;
    uint256 private strategyBefore;
    uint256 private buybackBefore;
    uint256 private protocolBefore;
    Phase3DistributorInvariantHandler private handler;

    function setUp() public {
        vm.chainId(56); vm.roll(10_000); vm.warp(START + 100); vm.deal(TAX_PROCESSOR, 10 ether);
        quote = new ControlledQuote();
        market = new MockProductionERC20("Invariant Market", "IM", 18);
        mockCompd = new MockCompdToken(TAX_PROCESSOR); vm.etch(COMPD, address(mockCompd).code);
        vault = new CompdProductionVault(address(quote), address(this));
        CompdStrategyExecutor strategy = new CompdStrategyExecutor(address(vault), address(this));
        CompdBuybackExecutor buyback = new CompdBuybackExecutor(address(vault));
        CompdProductionVaultFactory factory = new CompdProductionVaultFactory(address(vault));
        vault.configureHolderRewardsActivation(1, bytes32(uint256(1)), START);
        distributor = new CompdHolderRewardsDistributor(address(vault), FINALIZER);
        vault.bindHolderRewardsDistributor(address(distributor));
        vault.bindStrategyExecutor(address(strategy)); vault.bindBuybackExecutor(address(buyback)); vault.bindReceiverFactory(address(factory));
        MockStrategyAdapter adapter = new MockStrategyAdapter(address(quote));
        MockEquityOracle oracle = new MockEquityOracle(); oracle.set(1_000 ether, block.timestamp);
        strategy.configureDependencies(address(adapter), address(oracle), 1 days);
        strategy.setMarketAsset(keccak256("PHASE3_INVARIANT"), address(market), true);
        vm.prank(PORTAL);
        CompdThinFlapReceiver receiver = CompdThinFlapReceiver(payable(factory.newVault(COMPD, address(quote), address(this), bytes(""))));
        quote.mint(address(receiver), 100 ether); vm.prank(TAX_PROCESSOR); (bool revenueOk,) = address(receiver).call(""); require(revenueOk);
        vault.grantRole(vault.HOLDER_REWARD_SETTLER_ROLE(), address(this));
        vm.prank(GUARDIAN); vault.resume();
        vm.prank(AUTOMATION); uint256 runId = strategy.openPosition(keccak256("PHASE3_INVARIANT"), address(market), 1 ether, 1 ether);
        adapter.setReturn(runId, 2 ether); oracle.set(1_000 ether, block.timestamp);
        vm.prank(AUTOMATION); strategy.closePosition(runId);
        uint64 windowStart = uint64(uint256(block.timestamp) / vault.HOLDER_WINDOW_SECONDS() * vault.HOLDER_WINDOW_SECONDS());
        uint64 windowEnd = windowStart + vault.HOLDER_WINDOW_SECONDS();
        bytes32 windowId = vault.holderWindowId(windowStart, windowEnd);
        vm.warp(windowEnd);
        bytes32 domain = vault.holderDomainSeparator();
        distributionId = keccak256(abi.encode(vault.HOLDER_DISTRIBUTION_TYPEHASH(), domain, windowId));
        ID.Leaf memory leaf;
        leaf.domainSeparator = domain; leaf.distributionId = distributionId; leaf.commitmentVersion = 1;
        leaf.windowId = windowId; leaf.windowStart = windowStart; leaf.windowEnd = windowEnd;
        leaf.rewardAsset = address(quote); leaf.windowPool = POOL; leaf.finalizedTotalPayable = POOL;
        leaf.recipientIndex = 0; leaf.recipient = address(0xC0FFEE); leaf.amount = POOL;
        leaf.datasetHash = keccak256("phase3-invariant-dataset"); leaf.algorithmVersion = 1;
        root = distributor.hashLeaf(leaf);
        ID.CandidateInput memory candidate = ID.CandidateInput(domain, distributionId, 1, windowId, windowStart, windowEnd,
            address(quote), POOL, POOL, 1, 1, root, leaf.datasetHash, 1);
        vm.prank(FINALIZER); distributor.submitCandidate(candidate);
        handler = new Phase3DistributorInvariantHandler(distributor, leaf);
        bytes4[] memory selectors = new bytes4[](1); selectors[0] = handler.attemptMutatedProof.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
        excludeContract(address(vault)); excludeContract(address(distributor)); excludeContract(address(handler));
        excludeContract(address(quote)); excludeContract(address(market)); excludeContract(address(strategy));
        excludeContract(address(buyback)); excludeContract(address(factory)); excludeContract(address(receiver));
        excludeContract(address(adapter)); excludeContract(address(oracle)); excludeContract(COMPD);
        excludeContract(address(mockCompd));
        strategyBefore = vault.strategyCapital(); buybackBefore = vault.buybackReserve(); protocolBefore = vault.protocolReserve();
    }

    function invariant_invalidProofCannotCreateVaultLiabilityOrMoveAnyBucket() public view {
        ID.CommitmentView memory current = distributor.candidate(distributionId);
        assertEq(current.root, root); assertEq(current.commitmentVersion, 1);
        assertEq(vault.holderDistributionVersion(distributionId), current.commitmentVersion);
        assertEq(uint8(current.status), uint8(ID.CandidateStatus.MATERIALIZING));
        assertEq(vault.holderRewardEntry(distributionId, 0).amount, 0);
        assertEq(vault.holderCandidateReviewPoolTotal(), POOL);
        assertEq(vault.strategyCapital(), strategyBefore);
        assertEq(vault.buybackReserve(), buybackBefore);
        assertEq(vault.protocolReserve(), protocolBefore);
        assertEq(quote.balanceOf(address(distributor)), 0);
        assertEq(vault.strategyCapital() + vault.buybackReserve() + vault.protocolReserve() + vault.holderRewardReserve(), vault.accountedQuote() + vault.activePrincipal());
        assertGe(quote.balanceOf(address(vault)), vault.accountedQuote());
        assertEq(vault.holderUnfinalizedWindowPoolTotal() + vault.holderCandidateReviewPoolTotal() + vault.holderFinalizedUnpaidLiabilityTotal() + vault.holderUnallocatedNoRecipientPoolTotal() + vault.holderRecoveryEligibleTotal(), vault.holderRewardReserve());
    }
}
