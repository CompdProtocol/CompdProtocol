// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CompdHolderRewardsDistributor} from "../contracts/production/CompdHolderRewardsDistributor.sol";
import {ICompdHolderRewardsDistributor as ID} from "../contracts/production/ICompdHolderRewardsDistributor.sol";

contract Phase4HashOnlyVault {
    function quoteToken() external pure returns (address) { return address(0x99); }
    function COMPD_TOKEN() external pure returns (address) { return address(0x11); }
    function AUTOMATION_EXECUTOR() external pure returns (address) { return address(0x10); }
}

/// @dev Cross-language golden vector from offchain/holder-rewards-v1/fixtures/half-window-transfer.json.
contract CompdHolderRewardsPhase4CompatibilityTest is Test {
    CompdHolderRewardsDistributor internal distributor;

    function setUp() public {
        distributor = new CompdHolderRewardsDistributor(address(new Phase4HashOnlyVault()), address(0x20));
    }

    function testOffchainGoldenDomainWindowDistributionAndDatasetHashes() public view {
        bytes32 protocolId = keccak256(bytes("COMPD_HOLDER_REWARDS_V1"));
        bytes32 domainType = keccak256(bytes("CompdHolderRewardsDomain(bytes32 protocolId,uint256 chainId,address compdToken,address vault,address distributor,address rewardAsset)"));
        bytes32 domain = keccak256(abi.encode(domainType, protocolId, uint256(56), address(0x11), address(0x22), address(0x33), address(0x99)));
        assertEq(domain, 0x95a47c9e34334698202acda1b9b33af2d562d4785972cbbe9e9a14d556522a78);

        bytes32 windowType = keccak256(bytes("CompdHolderRewardWindow(bytes32 domainSeparator,uint256 activationBlock,bytes32 activationBlockHash,uint64 activationTimestamp,uint64 windowStart,uint64 windowEnd)"));
        bytes32 windowId = keccak256(abi.encode(windowType, domain, uint256(1), bytes32(uint256(1)), uint64(2_879_999), uint64(2_880_000), uint64(2_908_800)));
        assertEq(windowId, 0xbf4e8be75da929a2f5e78f3d82f758310187632661d054cf6aa70471bd93f229);
        bytes32 distributionType = keccak256(bytes("CompdHolderRewardDistribution(bytes32 domainSeparator,bytes32 windowId)"));
        bytes32 distributionId = keccak256(abi.encode(distributionType, domain, windowId));
        assertEq(distributionId, 0x6d42f1f1e145974828d5d770c15f8b6dcabde8570cf6a07b003efa7305af4e0a);

        bytes32 exclusionType = keccak256(bytes("CompdHolderRewardExclusionSet(uint32 exclusionSetVersion,address[] sortedExcludedAddresses)"));
        address[] memory excluded = new address[](1);
        excluded[0] = address(0xdead);
        bytes32 exclusionHash = keccak256(abi.encode(exclusionType, uint32(1), excluded));
        bytes32 entriesType = keccak256(bytes("CompdHolderRewardEntries(uint16[] recipientIndices,address[] recipients,uint256[] weights,uint256[] floorQuotients,uint256[] remainderNumerators,uint256[] finalPayouts)"));
        uint16[] memory indices = new uint16[](2); indices[0] = 0; indices[1] = 1;
        address[] memory recipients = new address[](2); recipients[0] = address(0xa1); recipients[1] = address(0xb2);
        uint256[] memory weights = new uint256[](2); weights[0] = 1_000_000 ether * 14_400; weights[1] = 1_000_000 ether * 14_400;
        uint256[] memory quotients = new uint256[](2); quotients[0] = 50; quotients[1] = 50;
        uint256[] memory remainders = new uint256[](2);
        uint256[] memory payouts = new uint256[](2); payouts[0] = 50; payouts[1] = 50;
        bytes32 entriesHash = keccak256(abi.encode(entriesType, indices, recipients, weights, quotients, remainders, payouts));
        bytes32 datasetType = keccak256(bytes("CompdHolderRewardDataset(bytes32 domainSeparator,bytes32 distributionId,bytes32 windowId,uint64 windowStart,uint64 windowEnd,uint256 windowPool,uint256 finalizedTotalPayable,uint16 recipientCount,uint32 algorithmVersion,uint32 exclusionSetVersion,bytes32 exclusionSetHash,uint256 activationBlock,bytes32 activationBlockHash,uint64 activationTimestamp,uint256 sourceStartBlock,uint256 finalityBlock,bytes32 finalityBlockHash,bytes32 entriesHash)"));
        bytes32 datasetHash = keccak256(abi.encode(datasetType, domain, distributionId, windowId, uint64(2_880_000), uint64(2_908_800), uint256(100), uint256(100), uint16(2), uint32(1), uint32(1), exclusionHash, uint256(1), bytes32(uint256(1)), uint64(2_879_999), uint256(1), uint256(3), bytes32(uint256(3)), entriesHash));
        assertEq(datasetHash, 0xd2df877525f8769656bd1695ad2a3119abddc2daf19fd0b6591dfc6ce537a736);
    }

    function testOffchainGoldenLeafAndMerkleNodeHashes() public view {
        ID.Leaf memory leaf = ID.Leaf({
            domainSeparator: 0x95a47c9e34334698202acda1b9b33af2d562d4785972cbbe9e9a14d556522a78,
            distributionId: 0x6d42f1f1e145974828d5d770c15f8b6dcabde8570cf6a07b003efa7305af4e0a,
            commitmentVersion: 1,
            windowId: 0xbf4e8be75da929a2f5e78f3d82f758310187632661d054cf6aa70471bd93f229,
            windowStart: 2_880_000,
            windowEnd: 2_908_800,
            rewardAsset: address(0x99),
            windowPool: 100,
            finalizedTotalPayable: 100,
            recipientIndex: 0,
            recipient: address(0xa1),
            amount: 50,
            datasetHash: 0xd2df877525f8769656bd1695ad2a3119abddc2daf19fd0b6591dfc6ce537a736,
            algorithmVersion: 1
        });
        bytes32 firstLeaf = distributor.hashLeaf(leaf);
        assertEq(firstLeaf, 0xba76e5f44acba18d2ad7a660e61ab73a38f2d5819191b00621b85af8cc72ffe2);
        leaf.recipientIndex = 1;
        leaf.recipient = address(0xb2);
        bytes32 secondLeaf = distributor.hashLeaf(leaf);
        assertEq(secondLeaf, 0x53edd8c8cceaa972a2795ae1f027fc1e4b7a9f410570558083119155a2b9008a);
        assertEq(distributor.hashNode(firstLeaf, secondLeaf), 0x5ee84d858c56051214d41e42dbb2d7db441a07fb7b410b21dd8c44462dc6f463);
    }

    function testOffchainGoldenPaddingLeafHash() public view {
        assertEq(
            distributor.hashPadding(
                0x95a47c9e34334698202acda1b9b33af2d562d4785972cbbe9e9a14d556522a78,
                0x6d42f1f1e145974828d5d770c15f8b6dcabde8570cf6a07b003efa7305af4e0a,
                1,
                3
            ),
            0xae1b268e149bd79793687eab3654409447aa4ee2dd1b6b2a8aded9b543230a82
        );
    }
}
