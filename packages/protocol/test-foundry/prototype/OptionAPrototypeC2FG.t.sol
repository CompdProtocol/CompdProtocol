// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import "../../contracts/prototype/OptionAPrototypeC2FG.sol";
import "./OptionAPrototype.t.sol";

interface VmC2FG { function prank(address) external; function getNonce(address) external view returns(uint64); function computeCreateAddress(address,uint256) external pure returns(address); }

contract C2FGMockToken {
    mapping(address=>uint256) public balanceOf;
    function set(address who,uint256 amount) external {balanceOf[who]=amount;}
}
contract C2FGMockWorkflow {
    function partitions() external pure returns(uint256,uint256,uint256,uint256,uint256){return(10,20,30,15,25);}
}
contract C2FGMockVault {
    uint8 public lifecycle=4;
    uint256 public strategyCapital=100;
    uint256 public buybackReserve=20;
    uint256 public protocolReserve=30;
    uint256 public holderRewardReserve=100;
    uint256 public accountedQuote=200;
    uint256 public activePrincipal=40;
    address public quote;
    address public settlement;
    address public holder;
    address public emergency;
    address public workflow;
    address public liability;
    address public registry;
    address public distributor;
    address public strategyExecutor;
    address public buybackExecutor;
    address public flapReceiver;
    bytes32 public settlementHash;
    bytes32 public holderHash;
    bytes32 public emergencyHash;
    uint256 public preEmergencyDeficit=5;
    uint8 public emergencyProcessingStatus=1;
    constructor(address q,address w){quote=q;workflow=w;}
    function sourceHash(uint8) external pure returns(bytes32){return bytes32(0);}
    function sourceAddress(uint8) external pure returns(address){return address(0);}
    function emergencySnapshot() external pure returns(bytes32){return bytes32(uint256(1));}
    function readOnlyDiagnostics() external pure returns(uint256,uint256,uint64,uint256,uint256,uint256,uint64){return(11,12,13,14,15,16,17);}
}

contract C2FGLensRegistryTest {
    VmC2FG constant vm=VmC2FG(address(uint160(uint256(keccak256("hevm cheat code")))));
    struct CEnv { MockTokenP token; CompdProductionVaultV2KernelC2FGProto vault; CompdSettlementControllerV2Proto settlement; CompdHolderControllerV2Proto holder; CompdEmergencyControllerV2Proto emergency; MockWorkflowP workflow; MockLiabilityP liability; MockDistributorP distributor; MockRegistryP registry; MockModuleP exec; }
    function _cenv() internal returns(CEnv memory e){address predicted=vm.computeCreateAddress(address(this),uint256(vm.getNonce(address(this)))+7);e.settlement=new CompdSettlementControllerV2Proto(predicted);e.holder=new CompdHolderControllerV2Proto(predicted);e.emergency=new CompdEmergencyControllerV2Proto(predicted);e.token=new MockTokenP();e.exec=new MockModuleP(predicted,address(e.token));MockBuybackP bx=new MockBuybackP(predicted);MockReceiverP rx=new MockReceiverP(predicted);e.vault=new CompdProductionVaultV2KernelC2FGProto(address(e.token),address(this),address(this),address(0xBEEF),address(0xCAFE),address(e.settlement).codehash,address(e.holder).codehash,address(e.emergency).codehash);require(address(e.vault)==predicted);e.workflow=new MockWorkflowP(predicted);e.liability=new MockLiabilityP(predicted);e.distributor=new MockDistributorP(predicted);e.registry=new MockRegistryP(predicted);e.vault.bind(1,address(e.settlement));e.vault.bind(2,address(e.holder));e.vault.bind(3,address(e.emergency));bytes32[7] memory hashes=[address(e.workflow).codehash,address(e.liability).codehash,address(e.registry).codehash,address(e.distributor).codehash,address(e.exec).codehash,address(bx).codehash,address(rx).codehash];e.vault.bindSources(address(e.workflow),address(e.liability),address(e.registry),address(e.distributor),address(e.exec),address(bx),address(rx),hashes);e.token.mint(predicted,10_000);e.vault.seed(10_000);e.vault.activate();}
    function _settle(CEnv memory e,uint256 run) internal {vm.prank(address(e.exec));e.vault.allocate(run,1000);e.token.mint(address(e.exec),1200);e.exec.setRun(run,1000,1200,2,true);uint64 n=uint64(e.vault.consumed(1));bytes32 evidence=keccak256(abi.encode(run,address(e.token),uint256(1000),uint256(1200),uint8(2),true));uint64 st=uint64(block.timestamp/28800*28800);bytes32 wid=keccak256(abi.encode(block.timestamp/28800));bytes32 c=keccak256(abi.encode(block.chainid,address(e.vault),address(e.settlement),uint8(1),run,address(e.token),uint256(1000),uint256(1200),n,evidence,wid,st,st+28800));vm.prank(address(e.exec));e.vault.settle(run,1200,n,c);}
    function testLensAggregatesReadOnlyHolderAndBacking() external {
        C2FGMockToken token=new C2FGMockToken(); C2FGMockWorkflow workflow=new C2FGMockWorkflow();
        C2FGMockVault vault=new C2FGMockVault(address(token),address(workflow));
        token.set(address(vault),250); CompdProtocolLensV2 lens=new CompdProtocolLensV2();
        (uint8 life,uint256 sc,uint256 bb,uint256 pr,uint256 hr,uint256 aq,uint256 active)=lens.bucketState(address(vault));
        require(life==4&&sc==100&&bb==20&&pr==30&&hr==100&&aq==200&&active==40);
        (uint256 a,uint256 b,uint256 c,uint256 d,uint256 e,uint256 total,bool matches)=lens.holderPartitions(address(vault));
        require(a==10&&b==20&&c==30&&d==15&&e==25&&total==100&&matches);
        (uint256 available,uint256 deficit,uint256 caused)=lens.holderBacking(address(vault));
        require(available==100&&deficit==0&&caused==0);
        require(lens.cumulativeProfit(address(vault))==11&&lens.cumulativeLoss(address(vault))==12&&lens.cumulativeRevenue(address(vault))==16);
    }
    function testLensHasNoMutationOrVaultCallbackSurface() external {
        C2FGMockToken token=new C2FGMockToken(); C2FGMockWorkflow workflow=new C2FGMockWorkflow();
        C2FGMockVault vault=new C2FGMockVault(address(token),address(workflow)); CompdProtocolLensV2 lens=new CompdProtocolLensV2();
        (bool ok,)=address(lens).call(abi.encodeWithSignature("emergencyEnter()"));
        require(!ok&&vault.lifecycle()==4);
    }
    function testLensActivationDiagnosticsMirrorVaultBindings() external {
        CEnv memory e=_cenv(); CompdProtocolLensV2 lens=new CompdProtocolLensV2(); bool[10] memory flags=lens.activationDiagnostics(address(e.vault));
        for(uint256 i;i<flags.length;i++)require(flags[i]);
    }
    function testC2FGVaultActivatesSettlesPaysAndEntersEmergencyWithoutLens() external {
        CEnv memory e=_cenv(); _settle(e,801); require(e.vault.holderRewardReserve()==20);
        bytes32 id=keccak256("c2fg-dist"); bytes32 root=keccak256("c2fg-root"); bytes32 leaf=keccak256("c2fg-leaf");
        e.workflow.setDist(root,1,20,uint64(block.timestamp),1);e.distributor.set(root,1,20,1,uint64(block.timestamp));
        e.distributor.setLeaf(id,1,0,leaf,address(0x1234),address(e.token),20,1);e.liability.set(leaf,address(0x1234),address(e.token),20,1);
        e.vault.finalize(id,1);e.distributor.setLeaf(id,1,0,leaf,address(0x1234),address(e.token),20,2);
        e.vault.pay(id,1,0,leaf,address(0x1234),address(e.token),20);require(e.vault.holderRewardReserve()==0);
        vm.prank(address(0xCAFE));e.vault.emergencyEnter();require(e.vault.lifecycle()==4&&e.vault.emergencySnapshot()!=bytes32(0));
    }
    function testC2FGActivationFailsClosedWithoutLensOrRequiredComponents() external {
        MockTokenP token=new MockTokenP();CompdProductionVaultV2KernelC2FGProto v=new CompdProductionVaultV2KernelC2FGProto(address(token),address(this),address(this),address(0xBEEF),address(0xCAFE),bytes32(0),bytes32(0),bytes32(0));
        (bool ok,)=address(v).call(abi.encodeCall(v.activate,()));require(!ok&&v.lifecycle()==1);
    }
    function testRegistryUnresolvedPreventsCompletionAndTypedResolutionAllowsIt() external {
        CompdEmergencyRegistryAggregateV2Proto r=new CompdEmergencyRegistryAggregateV2Proto(address(this)); bytes32 s=keccak256("snap");
        r.registerAsset(s,1,address(0x1111));
        (uint64 a0,uint64 a1,uint64 a2,uint64 m0,uint64 m1,uint64 m2,uint64 r0,uint64 r1,uint64 r2,bool complete0)=r.scopeSummary(s); require(!complete0);
        r.attemptAsset(s,1,address(0x1111)); r.resolveAsset(s,1,address(0x1111));
        (uint64 ta,uint64 ra,uint64 ua,uint64 mta,uint64 mra,uint64 mua,uint64 rta,uint64 rra,uint64 rua,bool complete1)=r.scopeSummary(s);
        require(ta==1&&ra==1&&ua==0&&complete1);
    }
    function testRegistryCannotResolveBeforeAttemptOrDoubleResolve() external {
        CompdEmergencyRegistryAggregateV2Proto r=new CompdEmergencyRegistryAggregateV2Proto(address(this)); bytes32 s=keccak256("snap");
        r.registerModule(s,2,address(0x2222));
        (bool early,)=address(r).call(abi.encodeCall(r.resolveModule,(s,uint8(2),address(0x2222)))); require(!early);
        r.attemptModule(s,2,address(0x2222)); r.resolveModule(s,2,address(0x2222));
        (bool twice,)=address(r).call(abi.encodeCall(r.resolveModule,(s,uint8(2),address(0x2222)))); require(!twice);
        (uint64 at,uint64 ar,uint64 au,uint64 mt,uint64 mr,uint64 mu,uint64 rt,uint64 rr,uint64 ru,bool moduleComplete)=r.scopeSummary(s);
        require(mt==1&&mr==1&&mu==0&&moduleComplete);
    }
    function testRegistryRunCountsAndLateRegistrationReopensCompletion() external {
        CompdEmergencyRegistryAggregateV2Proto r=new CompdEmergencyRegistryAggregateV2Proto(address(this)); bytes32 s=keccak256("snap");
        r.registerRun(s,77); r.attemptRun(s,77); r.resolveRun(s,77);
        (uint64 at,uint64 ar,uint64 au,uint64 mt,uint64 mr,uint64 mu,uint64 tr,uint64 rr,uint64 ur,bool runComplete)=r.scopeSummary(s); require(tr==1&&rr==1&&ur==0&&runComplete);
        r.registerAsset(s,0,address(0x3333));
        (uint64 at2,uint64 ar2,uint64 unresolved,uint64 mt2,uint64 mr2,uint64 mu2,uint64 tr2,uint64 rr2,uint64 ru2,bool completeAfter)=r.scopeSummary(s); require(unresolved==1&&!completeAfter);
    }
    function testRegistryRejectsExternalWriterAndDuplicateRegistration() external {
        CompdEmergencyRegistryAggregateV2Proto r=new CompdEmergencyRegistryAggregateV2Proto(address(this)); bytes32 s=keccak256("snap");
        vm.prank(address(0xBAD)); (bool outsider,)=address(r).call(abi.encodeCall(r.registerRun,(s,uint256(9)))); require(!outsider);
        r.registerRun(s,9); (bool duplicate,)=address(r).call(abi.encodeCall(r.registerRun,(s,uint256(9)))); require(!duplicate);
    }
    function testEmptyScopeIsNotReportedClean() external {
        CompdEmergencyRegistryAggregateV2Proto r=new CompdEmergencyRegistryAggregateV2Proto(address(this));
        (uint64 a0,uint64 a1,uint64 a2,uint64 m0,uint64 m1,uint64 m2,uint64 r0,uint64 r1,uint64 r2,bool complete)=r.scopeSummary(keccak256("empty")); require(!complete);
    }
}
