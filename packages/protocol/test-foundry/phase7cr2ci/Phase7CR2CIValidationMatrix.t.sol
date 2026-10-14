// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {CompdVaultKernelV3 as Kernel} from "../../contracts/production/v3/phase7cr2ch/CompdVaultKernelV3.sol";
import {CompdCanonicalHolderStateV3 as State} from "../../contracts/production/v3/phase7cr2ch/CompdCanonicalHolderStateV3.sol";
import {CompdHolderCandidateModuleV3 as Candidate} from "../../contracts/production/v3/phase7cr2ch/CompdHolderCandidateModuleV3.sol";
import {CompdHolderDistributorV3 as Distributor} from "../../contracts/production/v3/phase7cr2ch/CompdHolderDistributorV3.sol";
import {CompdHolderLiabilityV3 as Liability} from "../../contracts/production/v3/phase7cr2ch/CompdHolderLiabilityV3.sol";
import {CompdRecoveryEvidenceV3 as Evidence} from "../../contracts/production/v3/phase7cr2ch/CompdRecoveryEvidenceV3.sol";
import {CompdRecoveryModuleV3 as Recovery} from "../../contracts/production/v3/phase7cr2ch/CompdRecoveryModuleV3.sol";
import {CompdHolderModuleV3 as Holder} from "../../contracts/production/v3/phase7cr2ch/CompdHolderModuleV3.sol";
import {CompdSettlementModuleV3 as Settlement} from "../../contracts/production/v3/phase7cr2ch/CompdSettlementModuleV3.sol";
import {CompdDisabledBuybackPolicyModuleV3 as Policy} from "../../contracts/production/v3/phase7cr2ch/CompdDisabledBuybackPolicyModuleV3.sol";
import {CompdEmergencyModuleV3 as Emergency} from "../../contracts/production/v3/phase7cr2ch/CompdEmergencyModuleV3.sol";
import {CompdEmergencyScopeRegistryV3 as Registry} from "../../contracts/production/v3/phase7cr2ch/CompdEmergencyScopeRegistryV3.sol";
import {CompdDisabledBuybackExecutorV3 as BuybackExecutor} from "../../contracts/production/v3/phase7cr2ch/CompdDisabledBuybackExecutorV3.sol";
import {CompdStrategyExecutorV2R2 as StrategyExecutor} from "../../contracts/production/v2/phase7ar2/CompdStrategyExecutorV2R2.sol";

contract WrongIdentityModule {
    address public immutable kernel;
    uint8 public immutable moduleId;
    uint32 public immutable moduleVersion;
    constructor(address k,uint8 id,uint32 version_){kernel=k;moduleId=id;moduleVersion=version_;}
}

contract MatrixModuleDeployer {
    function candidate(address k,address s,address d,address f,address t) external returns(address){return address(new Candidate(k,s,d,f,t));}
    function state(address k,address d,address l,address e,address f,address c,address t,bytes32 ch) external returns(address){return address(new State(k,d,l,e,f,c,t,ch));}
    function distributor(address k,address s,address c,address f) external returns(address){return address(new Distributor(k,s,c,f));}
    function liability(address k,address s) external returns(address){return address(new Liability(k,s));}
    function evidence(address k,address s) external returns(address){return address(new Evidence(k,s));}
    function recovery(address k,address e,bytes32 h) external returns(address){return address(new Recovery(k,e,h));}
    function holder(address k,address d,address l,address s) external returns(address){return address(new Holder(k,d,l,s));}
    function settlement(address k,address e,bytes32 h) external returns(address){return address(new Settlement(k,e,h));}
    function policy(address k) external returns(address){return address(new Policy(k));}
    function emergency(address k,address r) external returns(address){return address(new Emergency(k,r));}
    function registry(address k,address e) external returns(address){return address(new Registry(k,e));}
    function buyback(address k) external returns(address){return address(new BuybackExecutor(k));}
    function wrong(address k,uint8 id,uint32 version_) external returns(address){return address(new WrongIdentityModule(k,id,version_));}
}

contract MatrixKernelDeployer {
    function deploy(address ea,address ew,address b,address d,address l,address e,address c,address token,address[6] memory m,bytes32[13] memory h) external returns(address){return address(new Kernel(ea,ew,b,d,l,e,c,token,m,h));}
}

contract Phase7CR2CIValidationMatrixTest is Test {
    address constant FINALIZER=address(0xF1A1);
    address constant TOKEN=address(0x70C0);
    address constant ADMIN=0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;
    address constant GUARDIAN=0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;

    struct Graph { MatrixModuleDeployer md; MatrixKernelDeployer kd; address kernel; address buyback; address distributor; address liability; address evidence; address candidate; address state; address[6] modules; bytes32[13] hashes; }

    function _graph() private returns(Graph memory f) {
        f.md=new MatrixModuleDeployer(); f.kd=new MatrixKernelDeployer();
        f.kernel=vm.computeCreateAddress(address(f.kd),1);
        address s=vm.computeCreateAddress(address(f.md),2);
        address d=vm.computeCreateAddress(address(f.md),3); address l=vm.computeCreateAddress(address(f.md),4);
        address e=vm.computeCreateAddress(address(f.md),5);
        f.candidate=f.md.candidate(f.kernel,s,d,FINALIZER,TOKEN);
        f.state=f.md.state(f.kernel,d,l,e,FINALIZER,f.candidate,TOKEN,f.candidate.codehash);
        f.distributor=f.md.distributor(f.kernel,f.state,f.candidate,FINALIZER);
        f.liability=f.md.liability(f.kernel,f.state); f.evidence=f.md.evidence(f.kernel,f.state);
        address recovery=f.md.recovery(f.kernel,f.evidence,f.evidence.codehash);
        address holder=f.md.holder(f.kernel,f.distributor,f.liability,f.state);
        address strategyProbe=address(new StrategyExecutor(f.kernel,ADMIN,GUARDIAN));
        address strategy=vm.computeCreateAddress(f.kernel,1);
        address settlement=f.md.settlement(f.kernel,strategy,strategyProbe.codehash);
        address policy=f.md.policy(f.kernel);
        address emergency=f.md.emergency(f.kernel,vm.computeCreateAddress(address(f.md),11));
        address registry=f.md.registry(f.kernel,emergency);
        f.buyback=f.md.buyback(f.kernel);
        f.modules=[settlement,holder,policy,recovery,emergency,registry];
        f.hashes=[strategyProbe.codehash,f.buyback.codehash,f.distributor.codehash,f.liability.codehash,f.evidence.codehash,f.candidate.codehash,f.state.codehash,settlement.codehash,holder.codehash,policy.codehash,recovery.codehash,emergency.codehash,registry.codehash];
    }

    function _deploy(Graph memory f) private returns(address) {
        return f.kd.deploy(address(0xA11CE),address(0xB0B),f.buyback,f.distributor,f.liability,f.evidence,f.candidate,TOKEN,f.modules,f.hashes);
    }

    function testEveryComponentConstructsBeforeKernelThenKernelDeploysLast() public {
        Graph memory f=_graph();
        assertEq(f.kernel.code.length,0);
        assertGt(f.candidate.code.length,0); assertGt(f.state.code.length,0);
        assertGt(f.distributor.code.length,0); assertGt(f.liability.code.length,0);
        assertGt(f.evidence.code.length,0); assertGt(f.modules[0].code.length,0);
        assertGt(f.modules[1].code.length,0); assertGt(f.modules[2].code.length,0);
        assertGt(f.modules[3].code.length,0); assertGt(f.modules[4].code.length,0);
        assertGt(f.modules[5].code.length,0); assertGt(f.buyback.code.length,0);
        assertEq(_deploy(f),f.kernel); assertGt(f.kernel.code.length,0);
    }

    function testEveryManifestEntryRejectsZeroExpectedHash() public {
        for(uint8 i;i<13;++i){ Graph memory f=_graph(); f.hashes[i]=bytes32(0); vm.expectRevert(); _deploy(f); }
    }

    function testEveryManifestEntryRejectsNonzeroWrongHash() public {
        for(uint8 i;i<13;++i){ Graph memory f=_graph(); f.hashes[i]=bytes32(uint256(1)); vm.expectRevert(); _deploy(f); }
    }

    function testWrongModuleAddressAndWrongKernelFailClosed() public {
        Graph memory badModule=_graph(); badModule.modules[0]=address(0xBAD); vm.expectRevert(); _deploy(badModule);
        Graph memory badKernel=_graph();
        address wrongKernel=address(uint160(uint160(badKernel.kernel)+1));
        address strategyProbe=address(new StrategyExecutor(wrongKernel,ADMIN,GUARDIAN));
        badKernel.modules[0]=address(new Settlement(wrongKernel,vm.computeCreateAddress(badKernel.kernel,1),strategyProbe.codehash));
        badKernel.hashes[7]=badKernel.modules[0].codehash; vm.expectRevert(); _deploy(badKernel);
    }

    function testSettlementRejectsWrongExecutorAddressAndHash() public {
        Graph memory wrongAddress=_graph();
        wrongAddress.modules[0]=address(new Settlement(wrongAddress.kernel,address(0xE0),wrongAddress.hashes[0]));
        wrongAddress.hashes[7]=wrongAddress.modules[0].codehash;
        vm.expectRevert(); _deploy(wrongAddress);
        Graph memory wrongHash=_graph();
        wrongHash.modules[0]=address(new Settlement(wrongHash.kernel,vm.computeCreateAddress(wrongHash.kernel,1),bytes32(uint256(1))));
        wrongHash.hashes[7]=wrongHash.modules[0].codehash;
        vm.expectRevert(); _deploy(wrongHash);
    }

    function testWrongModuleIdVersionAndDuplicateFailClosed() public {
        Graph memory badId=_graph(); address wrongId=badId.md.wrong(badId.kernel,8,4); badId.modules[0]=wrongId; badId.hashes[7]=wrongId.codehash; vm.expectRevert(); _deploy(badId);
        Graph memory badVersion=_graph(); address wrongVersion=badVersion.md.wrong(badVersion.kernel,0,99); badVersion.modules[0]=wrongVersion; badVersion.hashes[7]=wrongVersion.codehash; vm.expectRevert(); _deploy(badVersion);
        Graph memory duplicate=_graph(); duplicate.modules[1]=duplicate.modules[0]; duplicate.hashes[8]=duplicate.hashes[7]; vm.expectRevert(); _deploy(duplicate);
    }

    function testWrongCanonicalStateCandidateAndEvidenceFailClosed() public {
        Graph memory badState=_graph();
        // The State passed to the Kernel graph is deliberately inconsistent with Distributor/Kernel pins.
        address altState=address(new State(badState.kernel,badState.distributor,badState.liability,badState.evidence,FINALIZER,badState.candidate,TOKEN,badState.candidate.codehash));
        address altLiability=address(new Liability(badState.kernel,altState)); badState.liability=altLiability; badState.hashes[3]=altLiability.codehash; vm.expectRevert(); _deploy(badState);
        Graph memory badCandidate=_graph(); badCandidate.candidate=badCandidate.distributor; badCandidate.hashes[5]=badCandidate.distributor.codehash; vm.expectRevert(); _deploy(badCandidate);
        Graph memory badEvidence=_graph(); badEvidence.evidence=badEvidence.candidate; badEvidence.hashes[4]=badEvidence.candidate.codehash; vm.expectRevert(); _deploy(badEvidence);
    }

    function testBoundedGraphSelectorsAreNotMutable() public {
        Graph memory f=_graph(); address kernel=_deploy(f);
        bytes4[20] memory selectors=[bytes4(keccak256("bindEmergencyModule(address)")),bytes4(keccak256("setEmergencyModule(address)")),bytes4(keccak256("bindKernel(address)")),bytes4(keccak256("setKernel(address)")),bytes4(keccak256("replaceModule(uint8,address)")),bytes4(keccak256("replaceModule(address,address)")),bytes4(keccak256("setModule(uint8,address)")),bytes4(keccak256("setModuleHash(uint8,bytes32)")),bytes4(keccak256("setCodeHash(address,bytes32)")),bytes4(keccak256("upgradeTo(address)")),bytes4(keccak256("execute(address,bytes)")),bytes4(keccak256("callTarget(address,bytes)")),bytes4(keccak256("approve(address,uint256)")),bytes4(keccak256("swap(address,address,uint256,uint256)")),bytes4(keccak256("burn(uint256)")),bytes4(keccak256("emergencyExit()")),bytes4(keccak256("rescue(address,uint256)")),bytes4(keccak256("setDestination(address)")),bytes4(keccak256("bindRegistry(address)")),bytes4(keccak256("replaceExecutor(address)"))];
        for(uint256 i;i<selectors.length;++i){(bool ok,)=kernel.call(abi.encodePacked(selectors[i],bytes32(uint256(1)),bytes32(uint256(2))));assertFalse(ok);(ok,)=f.modules[0].call(abi.encodePacked(selectors[i],bytes32(uint256(1)),bytes32(uint256(2))));assertFalse(ok);(ok,)=f.modules[1].call(abi.encodePacked(selectors[i],bytes32(uint256(1)),bytes32(uint256(2))));assertFalse(ok);(ok,)=f.modules[2].call(abi.encodePacked(selectors[i],bytes32(uint256(1)),bytes32(uint256(2))));assertFalse(ok);(ok,)=f.modules[3].call(abi.encodePacked(selectors[i],bytes32(uint256(1)),bytes32(uint256(2))));assertFalse(ok);(ok,)=f.modules[4].call(abi.encodePacked(selectors[i],bytes32(uint256(1)),bytes32(uint256(2))));assertFalse(ok);(ok,)=f.modules[5].call(abi.encodePacked(selectors[i],bytes32(uint256(1)),bytes32(uint256(2))));assertFalse(ok);(ok,)=f.buyback.call(abi.encodePacked(selectors[i],bytes32(uint256(1)),bytes32(uint256(2))));assertFalse(ok);}
        vm.expectRevert(); Settlement(f.modules[0]).startRun(1,address(0x999),1,bytes32(uint256(1)));
        vm.expectRevert(); Emergency(f.modules[4]).initialize(new bytes32[](0),new uint8[](0));
        vm.expectRevert(); Emergency(f.modules[4]).recoverBNB(bytes32(uint256(1)),bytes32(uint256(2)),1,1,bytes32(uint256(3)));
        vm.expectRevert(); Registry(f.modules[5]).beginAttempt(bytes32(uint256(1)),bytes32(uint256(2)),bytes32(uint256(3)),1);
        assertEq(Kernel(payable(kernel)).emergencyWallet(),address(0xB0B));
        vm.expectRevert(); Policy(f.modules[2]).attempt(bytes32(uint256(1)),bytes32(uint256(2)));
        vm.expectRevert(); BuybackExecutor(payable(f.buyback)).executeExactInput(bytes32(uint256(1)),bytes32(uint256(2)));
        vm.expectRevert(Kernel.QuotePolicyUnavailable.selector); Kernel(payable(kernel)).activateBuyback(bytes32(uint256(1)));
        vm.expectRevert(); Kernel(payable(kernel)).allocateStrategyPrincipal(1,address(0x999),1,bytes32(uint256(1)));
    }
}
