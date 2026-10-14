// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CompdPancakeV3XStocksAdapter as A,IXStocksV3Pool} from "../contracts/production/v3/phase7cr2ch/CompdPancakeV3XStocksAdapter.sol";
import {IXStockRouter,IXStockToken,IXStockIndependentGuard} from "../contracts/production/v3/phase7cr2ch/CompdPancakeXStocksAdapterV3.sol";
import {CompdIndependentXStocksGuardV3 as G} from "../contracts/production/v3/phase7cr2ch/CompdIndependentXStocksGuardV3.sol";
import {T,Kernel,Settlement,StrategyExecutor} from "./phase7cr2ci/Phase7CR2CISettlementLifecycle.t.sol";
import {MatrixModuleDeployer,MatrixKernelDeployer} from "./phase7cr2ci/Phase7CR2CIValidationMatrix.t.sol";
// This fixture is deliberately NOT an independent reference or a qualified calendar.
contract V3MechanicalGuard is IXStockIndependentGuard {
 address public token;address public pool;bool public blocked;uint64 public age;
 constructor(address t,address p){token=t;pool=p;}
 function configure(bool b,uint64 a) external {blocked=b;age=a;}
 function referenceOut(address,bool buy,uint256 n) external view returns(uint256,uint64,uint64,bool){
  address w=0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;address u=0x55d398326f99059fF775485246999027B3197955;address[] memory path=new address[](2);path[0]=buy?w:u;path[1]=buy?u:w;
  IXStockRouter router=IXStockRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);(uint160 sqrt,,,,,,)=IXStocksV3Pool(pool).slot0();bool z=buy?(IXStocksV3Pool(pool).token0()==u):(IXStocksV3Pool(pool).token0()==token);
  uint256 input=buy?router.getAmountsOut(n,path)[1]:n;uint256 q=z?Math.mulDiv(Math.mulDiv(input,sqrt,2**96),sqrt,2**96):Math.mulDiv(Math.mulDiv(input,2**96,sqrt),2**96,sqrt);q-=q*IXStocksV3Pool(pool).fee()/1000000;
  uint256 result=buy?q:router.getAmountsOut(q,path)[1];return(result,uint64(block.timestamp)-age,uint64(block.timestamp)+60,!blocked);
 }
}
contract UnknownHaltCalendarFixture {function session(address) external view returns(bool,uint64,uint64){return(false,uint64(block.timestamp),uint64(block.timestamp+60));}}
contract CompdPancakeV3ForkTest is Test {
 address constant ADMIN=0x7Ea65A566e08862ebaFabF564A7A069E10DFd5e9;address constant GUARDIAN=0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;address constant AGENT=0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;
 Kernel kernel;Settlement settlement;
 event ForkResult(uint8 asset,uint256 input,string outcome,uint256 returned,uint256 realizedLoss);
 function kernelAddressRecovery() private pure returns(address){return 0xFa8706AA97B07cb29096381f9101784bA0d1332b;}
 function fork() private {vm.createSelectFork(vm.envString("BSC_RPC_URL"),vm.envUint("COMPD_XSTOCKS_FORK_BLOCK"));assertEq(block.chainid,56);}
 function deployGraph() internal {vm.chainId(56);vm.roll(1000);if(block.timestamp<100000)vm.warp(100000);MatrixModuleDeployer md=new MatrixModuleDeployer();MatrixKernelDeployer kd=new MatrixKernelDeployer();address k=vm.computeCreateAddress(address(kd),1);address s=vm.computeCreateAddress(address(md),2);address d=vm.computeCreateAddress(address(md),3);address l=vm.computeCreateAddress(address(md),4);address e=vm.computeCreateAddress(address(md),5);address c=md.candidate(k,s,d,address(0xF1A1),address(0x70C0));s=md.state(k,d,l,e,address(0xF1A1),c,address(0x70C0),c.codehash);d=md.distributor(k,s,c,address(0xF1A1));l=md.liability(k,s);e=md.evidence(k,s);address recovery=md.recovery(k,e,e.codehash);address holder=md.holder(k,d,l,s);address probe=address(new StrategyExecutor(k,ADMIN,GUARDIAN));address executor=vm.computeCreateAddress(k,1);address settle=md.settlement(k,executor,probe.codehash);address policy=md.policy(k);address em=md.emergency(k,vm.computeCreateAddress(address(md),11));address registry=md.registry(k,em);address bb=md.buyback(k);address[6] memory modules=[settle,holder,policy,recovery,em,registry];bytes32[13] memory hashes=[probe.codehash,bb.codehash,d.codehash,l.codehash,e.codehash,c.codehash,s.codehash,settle.codehash,holder.codehash,policy.codehash,recovery.codehash,em.codehash,registry.codehash];kernel=Kernel(payable(kd.deploy(GUARDIAN,kernelAddressRecovery(),bb,d,l,e,c,address(0x70C0),modules,hashes)));settlement=Settlement(settle);
 vm.deal(ADMIN,1 ether);vm.prank(ADMIN);kernel.bootstrapTreasury{value:1 ether}();vm.prank(ADMIN);kernel.activate();uint64 activation=kernel.activationBlock();vm.roll(uint256(activation)+1);vm.setBlockhash(activation,keccak256("LOCAL_XSTOCKS_FIXTURE_HEADER"));assertTrue(kernel.sealActivationCheckpoint());vm.prank(GUARDIAN);kernel.pause();
}
 function prepare(uint8 asset) private returns(A a,V3MechanicalGuard g){fork();deployGraph();address token=asset==1?0x8aD3c73F833d3F9A523aB01476625F269aEB7Cf0:0x3557Ba345B01EFa20A1bdDC61F573BFD87195081;address pool=asset==1?0x5E12d6EdB2b7D5330e474ea2D2694A3b3E35d492:0x28A73f5bd589Fea90BA0D24117BF91D648be3ef2;g=new V3MechanicalGuard(token,pool);a=new A(kernel.strategyExecutor(),asset,address(g));StrategyExecutor ex=StrategyExecutor(payable(kernel.strategyExecutor()));bytes32 i=a.strategyIdentity();bytes32 risk=a.riskConfigCommitment();bytes32 v=a.venueDependencyCommitment();vm.prank(ADMIN);ex.proposeStrategy(address(a),i,risk,v);(,,,,uint64 at,)=ex.proposals(address(a));vm.warp(at);vm.prank(ADMIN);ex.activateStrategy(address(a));vm.prank(GUARDIAN);kernel.resume();vm.warp((block.timestamp/28800+1)*28800+1);}
 function mechanical(uint8 asset,uint256 n) private { (A a,)=prepare(asset);uint256 beforeBalance=address(kernel).balance;vm.prank(AGENT);
  try settlement.startRun(1,address(a),n,bytes32(uint256(1))) {
   assertGt(a.totalPositionShares(),0);assertEq(kernel.activePrincipal(),n);vm.prank(AGENT);settlement.requestExit(1,bytes32(uint256(101)));assertEq(uint256(StrategyExecutor(payable(kernel.strategyExecutor())).runState(1)),uint256(T.StrategyRunState.RETURN_PENDING),"SELL_NOT_EXECUTABLE");vm.prank(AGENT);settlement.closeRun(1,bytes32(uint256(201)));uint256 afterBalance=address(kernel).balance;assertEq(kernel.activePrincipal(),0);assertEq(a.totalPositionShares(),0);assertEq(IXStockToken(a.token()).sharesOf(address(a)),0);assertEq(kernel.accountedQuote(),afterBalance);uint256 returned=afterBalance+n-beforeBalance;assertGt(returned,0);emit ForkResult(asset,n,"MECHANICAL_BUY_SELL_SETTLEMENT",returned,kernel.cumulativeRealizedLoss());
  } catch(bytes memory reason) {
   assertGe(reason.length,4);bytes4 selector;assembly("memory-safe"){selector:=mload(add(reason,32))}assertEq(selector,A.Unavailable.selector,"UNEXPECTED_REJECTION");assertEq(kernel.activePrincipal(),0);assertEq(kernel.strategyCapital(),.1 ether);assertEq(address(kernel).balance,beforeBalance);assertEq(a.totalPositionShares(),0);emit ForkResult(asset,n,"ATOMIC_PRICE_IMPACT_OR_SLIPPAGE_REJECTION",0,0);
  }
 }
 function blockedFourSizes(uint8 asset,uint64 age,bool closed) private {(A a,V3MechanicalGuard g)=prepare(asset);g.configure(closed,age);uint256[4] memory ns=[uint256(1e15),3e15,5e15,1e16];for(uint256 i;i<4;i++){vm.prank(AGENT);vm.expectRevert(A.Unavailable.selector);settlement.startRun(i+1,address(a),ns[i],bytes32(i+1));assertEq(kernel.activePrincipal(),0);assertEq(a.totalPositionShares(),0);assertEq(kernel.strategyCapital(),.1 ether);}}
 function actualGuardBlocked(uint8 asset) private {fork();address token=asset==1?0x8aD3c73F833d3F9A523aB01476625F269aEB7Cf0:0x3557Ba345B01EFa20A1bdDC61F573BFD87195081;address feed=asset==1?0xEEA2ae9c074E87596A85ABE698B2Afebc9B57893:0x51d08ca89d3e8c12535BA8AEd33cDf2557ab5b2a;
  G guard=new G(token,18,feed,0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE,address(new UnknownHaltCalendarFixture()));A a=new A(address(guard),asset,address(guard));uint256[4] memory ns=[uint256(1e15),3e15,5e15,1e16];for(uint256 i;i<4;i++){vm.expectRevert(G.Unavailable.selector);a.quote(true,ns[i]);}
 }
 function testTSLAStaleFourSizes() public {blockedFourSizes(1,61,false);}
 function testAMZNStaleFourSizes() public {blockedFourSizes(2,61,false);}
 function testTSLAUnknownHaltFourSizes() public {blockedFourSizes(1,0,true);}
 function testAMZNUnknownHaltFourSizes() public {blockedFourSizes(2,0,true);}
 function testTSLAActualFeedsAndUnknownHaltBlocked() public {actualGuardBlocked(1);}
 function testAMZNActualFeedsAndUnknownHaltBlocked() public {actualGuardBlocked(2);}
 function testTSLA_001() public {mechanical(1,1e15);}
 function testTSLA_003() public {mechanical(1,3e15);}
 function testTSLA_005() public {mechanical(1,5e15);}
 function testTSLA_010() public {mechanical(1,1e16);}
 function testAMZN_001() public {mechanical(2,1e15);}
 function testAMZN_003() public {mechanical(2,3e15);}
 function testAMZN_005() public {mechanical(2,5e15);}
 function testAMZN_010() public {mechanical(2,1e16);}
}
