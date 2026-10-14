// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {CompdHReadyQualificationBase} from "./CompdHReadyLocalQualification.t.sol";
import {CompdHolderCandidateTypesV3 as H} from "../../contracts/production/v3/phase7cr2ch/CompdHolderCandidateTypesV3.sol";

contract CompdHReadyMaximumShapeTest is CompdHReadyQualificationBase {
    function _coolGraph() internal {
        address liability_=kernel.liability();address evidence_=kernel.recoveryEvidence();vm.cool(address(candidate));vm.cool(address(state));vm.cool(address(distributor));vm.cool(address(holder));vm.cool(liability_);vm.cool(address(recovery));vm.cool(evidence_);vm.cool(address(kernel));
    }
    function leafHashForMax(H.Leaf calldata l) external view returns(bytes32){return keccak256(abi.encode(candidate.LEAF_TYPEHASH(),l));}
    function datasetForMax(H.Candidate calldata c,H.CandidateEvidence calldata e) external view returns(bytes32){
        bytes memory first=abi.encode(candidate.DATASET_TYPEHASH(),candidate.domainSeparator(),c.distributionId,c.windowId,c.windowStart,c.windowEnd,c.windowPool,c.payableTotal,c.recipientCount,c.algorithmVersion);
        bytes memory last=abi.encode(e.exclusionSetVersion,e.exclusionSetHash,uint256(kernel.activationBlock()),kernel.activationBlockHash(),kernel.activationTimestamp(),e.sourceStartBlock,e.finalityBlock,e.finalityBlockHash,e.entriesHash);
        return keccak256(bytes.concat(first,last));
    }
    function testRemainingMaximumThirtyRecipientsColdCallsAndExactTotal() public {
        _settle(1.1 ether);(H.Candidate memory c,H.CandidateEvidence memory e,H.Leaf memory template)=_vector(address(0xBEEF));assertEq(candidate.MAX_RECIPIENTS(),30);c.recipientCount=30;
        uint16[] memory ix=new uint16[](30);address[] memory rs=new address[](30);uint256[] memory weights=new uint256[](30);uint256[] memory floors=new uint256[](30);uint256[] memory remainders=new uint256[](30);uint256[] memory payouts=new uint256[](30);
        for(uint16 i;i<30;++i){ix[i]=i;rs[i]=address(uint160(0x100000+i));weights[i]=1;floors[i]=c.windowPool/30;remainders[i]=c.windowPool%30;payouts[i]=floors[i]+(i<c.windowPool%30?1:0);}
        e.entriesHash=keccak256(abi.encode(keccak256("CompdHolderRewardEntries(uint16[] recipientIndices,address[] recipients,uint256[] weights,uint256[] floorQuotients,uint256[] remainderNumerators,uint256[] finalPayouts)"),ix,rs,weights,floors,remainders,payouts));
        e.manifestHash=keccak256(abi.encode("LOCAL_30_EQUAL_WEIGHT_ROWS",c.windowId,e.entriesHash));
        c.datasetHash=this.datasetForMax(c,e);
        H.Leaf[30] memory leaves;bytes32[64] memory tree;
        for(uint16 i;i<30;++i){H.Leaf memory l=abi.decode(abi.encode(template),(H.Leaf));l.recipientIndex=i;l.recipient=rs[i];l.amount=payouts[i];l.datasetHash=c.datasetHash;leaves[i]=l;tree[32+i]=this.leafHashForMax(l);}
        for(uint16 i=30;i<32;++i)tree[32+i]=keccak256(abi.encode(keccak256("CompdHolderRewardPadding(bytes32 domainSeparator,bytes32 distributionId,uint32 commitmentVersion,uint16 paddedIndex)"),template.domainSeparator,c.distributionId,uint32(1),i));
        for(uint256 i=31;i>0;--i)tree[i]=keccak256(abi.encode(candidate.NODE_TYPEHASH(),tree[2*i],tree[2*i+1]));c.root=tree[1];
        _coolGraph();vm.prank(FINALIZER);uint256 before_=gasleft();distributor.submitCandidate(c,e);emit log_named_uint("cold 30 recipient submit call gas",before_-gasleft());
        uint256 maxMaterialize;bytes32 first;
        for(uint16 i;i<30;++i){bytes32[] memory proof=new bytes32[](5);uint256 node=32+i;for(uint256 depth;depth<5;++depth){proof[depth]=tree[node^1];node/=2;}
            _coolGraph();vm.prank(FINALIZER);before_=gasleft();bytes32 leaf=distributor.materializeLeaf(c.distributionId,1,leaves[i],proof);uint256 used=before_-gasleft();if(used>maxMaterialize)maxMaterialize=used;if(i==0)first=leaf;
        }
        emit log_named_uint("maximum cold depth five materialize call gas",maxMaterialize);vm.warp(vm.getBlockTimestamp()+1800);
        _coolGraph();before_=gasleft();distributor.finalizeCandidate(c.distributionId,1);uint256 finalGas=before_-gasleft();emit log_named_uint("cold 30 recipient finalize call gas",finalGas);assertLt(finalGas,16_777_216);
        assertEq(state.outstandingHolderLiability(),c.windowPool);_coolGraph();vm.cool(rs[0]);vm.prank(0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3);before_=gasleft();assertTrue(holder.pay(first));emit log_named_uint("cold holder payment call gas",before_-gasleft());_assertAccounting();
    }
    function testRemainingColdProtocolRecoveryCallCap() public {
        _terminatedProfit();bytes32 id=state.bucketRecoveryId(0);address treasury_=kernel.RECOVERY_TREASURY();_coolGraph();vm.cool(treasury_);vm.prank(GUARDIAN);uint256 before_=gasleft();
        (bool ok,)=address(recovery).call{gas:16_777_216}(abi.encodeWithSignature("recoverProtocol(bytes32)",id));assertTrue(ok);emit log_named_uint("cold protocol recovery call gas",before_-gasleft());_assertAccounting();
    }
}
