// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {C2G2BTypes as T} from "../contracts/production/v2/phase7ar2/C2G2BTypesR2.sol";
import {CompdStrategyExecutorV2R2} from "../contracts/production/v2/phase7ar2/CompdStrategyExecutorV2R2.sol";
import {IXStockIndependentGuard} from "../contracts/production/v3/phase7cr2ch/CompdPancakeXStocksAdapterV3.sol";
import {CompdAMZNxV3V3Adapter as Adapter} from "../contracts/production/v3/phase7cr2ch/CompdAMZNxV3V3Adapter.sol";

interface ISwapCallback { function pancakeV3SwapCallback(int256,int256,bytes calldata) external; }

contract AMZNMockToken {
    mapping(address=>uint256) public balanceOf;
    bool public failTransfer;
    function mint(address to,uint256 n) external { balanceOf[to]+=n; }
    function transfer(address to,uint256 n) external returns(bool) { if(failTransfer)return false; balanceOf[msg.sender]-=n; balanceOf[to]+=n; return true; }
    function setFailTransfer(bool v) external { failTransfer=v; }
}

contract AMZNMockWBNB is AMZNMockToken {
    function deposit() external payable { balanceOf[msg.sender]+=msg.value; }
    function withdraw(uint256 n) external { balanceOf[msg.sender]-=n; (bool ok,)=payable(msg.sender).call{value:n}(""); require(ok); }
    receive() external payable {}
}

contract AMZNMockXStock {
    mapping(address=>uint256) private _shares;
    uint256 public multiplier;
    function initialize() external {multiplier=1e18;}
    function sharesOf(address a) external view returns(uint256){return _shares[a];}
    function balanceOf(address a) external view returns(uint256){return getUnderlyingAmountByShares(_shares[a]);}
    function getUnderlyingAmountByShares(uint256 s) public view returns(uint256){return s*multiplier/1e18;}
    function getSharesByUnderlyingAmount(uint256 n) public view returns(uint256){return (n*1e18+multiplier-1)/multiplier;}
    function mint(address a,uint256 underlying) external {_shares[a]+=getSharesByUnderlyingAmount(underlying);}
    function transferShares(address to,uint256 shares) external returns(bool){_shares[msg.sender]-=shares;_shares[to]+=shares;return true;}
    function transfer(address to,uint256 underlying) external returns(bool){uint256 shares=getSharesByUnderlyingAmount(underlying);_shares[msg.sender]-=shares;_shares[to]+=shares;return true;}
    function rebase(uint256 next) external {require(next!=0);multiplier=next;}
}

contract AMZNMockV3Factory {
    mapping(bytes32=>address) private _pools;
    function setPool(address a,address b,uint24 fee,address pool) external {_pools[keccak256(abi.encode(a,b,fee))]=pool;_pools[keccak256(abi.encode(b,a,fee))]=pool;}
    function getPool(address a,address b,uint24 fee) external view returns(address){return _pools[keccak256(abi.encode(a,b,fee))];}
}

contract AMZNMockV3Pool {
    address public token0;address public token1;uint24 public fee;uint128 public liquidity=1e18;
    uint160 private constant Q96=2**96;uint16 public fillBps=10_000;bool public unlocked=true;
    function initialize(address a,address b,uint24 f) external {token0=a;token1=b;fee=f;liquidity=1e18;fillBps=10_000;unlocked=true;}
    function slot0() external view returns(uint160,int24,uint16,uint16,uint16,uint32,bool){return(Q96,0,0,0,0,0,unlocked);}
    function setFillBps(uint16 n) external {fillBps=n;}
    function setLiquidity(uint128 n) external {liquidity=n;}
    function swap(address recipient,bool zeroForOne,int256 amountSpecified,uint160,bytes calldata) external returns(int256 amount0,int256 amount1){
        require(amountSpecified>0);uint256 used=uint256(amountSpecified);uint256 out=used*(1_000_000-fee)/1_000_000*fillBps/10_000;
        address input=zeroForOne?token0:token1;address output=zeroForOne?token1:token0;
        require(AMZNMockToken(output).transfer(recipient,out));
        if(zeroForOne){amount0=int256(used);amount1=-int256(out);}else{amount1=int256(used);amount0=-int256(out);}
        ISwapCallback(msg.sender).pancakeV3SwapCallback(amount0,amount1,"");input;
    }
}

contract AMZNMockGuard is IXStockIndependentGuard {
    address public immutable token;uint256 public rateBps=9_980;uint64 public age;uint64 public expiry=60;bool public open=true;
    constructor(address t){token=t;}
    function configure(uint256 rate,uint64 age_,uint64 expiry_,bool open_) external {rateBps=rate;age=age_;expiry=expiry_;open=open_;}
    function referenceOut(address asset,bool,uint256 input) external view returns(uint256,uint64,uint64,bool){require(asset==token);return(input*rateBps/10_000,uint64(block.timestamp)-age,uint64(block.timestamp)+expiry,open);}
}

contract AMZNKernelHarness {
    CompdStrategyExecutorV2R2 public executor;T.Lifecycle public lifecycle=T.Lifecycle.PAUSED;bool public hasActivated=true;
    constructor(){executor=new CompdStrategyExecutorV2R2(address(this),address(0xA11CE),address(0xB0B));}
    receive() external payable{}
    function open(Adapter a,uint256 id,uint256 amount) external returns(bytes32){return executor.openRun{value:amount}(id,address(a),amount,amount*300/10_000,bytes32(id));}
    function exit(uint256 id,bytes32 exitId) external {executor.requestExit(id,exitId);}
    function close(uint256 id,bytes32 closeId) external returns(uint256,uint256,bytes32){return executor.closeToKernel(id,closeId);}
}

contract CompdAMZNxV3V3AdapterTest is Test {
    address constant WBNB=0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant USDT=0x55d398326f99059fF775485246999027B3197955;
    address constant AMZNX=0x3557Ba345B01EFa20A1bdDC61F573BFD87195081;
    address constant FACTORY=0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant P1=0x172fcD41E0913e95784454622d1c3724f546f849;
    address constant P2=0x28A73f5bd589Fea90BA0D24117BF91D648be3ef2;
    address constant ADMIN=address(0xA11CE);uint256 constant AMOUNT=0.001 ether;
    AMZNMockWBNB wbnb;AMZNMockToken usdt;AMZNMockXStock stock;AMZNMockV3Pool pool1;AMZNMockV3Pool pool2;
    AMZNMockV3Factory factory;AMZNMockGuard guard;AMZNKernelHarness kernel;CompdStrategyExecutorV2R2 executor;Adapter adapter;

    function setUp() public {
        vm.chainId(56);vm.warp(1_800_000_000);
        AMZNMockWBNB wi=new AMZNMockWBNB();vm.etch(WBNB,address(wi).code);wbnb=AMZNMockWBNB(payable(WBNB));vm.deal(WBNB,100 ether);
        AMZNMockToken ui=new AMZNMockToken();vm.etch(USDT,address(ui).code);usdt=AMZNMockToken(USDT);
        AMZNMockXStock xi=new AMZNMockXStock();vm.etch(AMZNX,address(xi).code);stock=AMZNMockXStock(AMZNX);stock.initialize();
        address t0a=WBNB<USDT?WBNB:USDT;address t1a=WBNB<USDT?USDT:WBNB;
        address t0b=USDT<AMZNX?USDT:AMZNX;address t1b=USDT<AMZNX?AMZNX:USDT;
        AMZNMockV3Pool p1i=new AMZNMockV3Pool();vm.etch(P1,address(p1i).code);pool1=AMZNMockV3Pool(P1);pool1.initialize(t0a,t1a,100);
        AMZNMockV3Pool p2i=new AMZNMockV3Pool();vm.etch(P2,address(p2i).code);pool2=AMZNMockV3Pool(P2);pool2.initialize(t0b,t1b,100);
        AMZNMockV3Factory fi=new AMZNMockV3Factory();vm.etch(FACTORY,address(fi).code);factory=AMZNMockV3Factory(FACTORY);
        factory.setPool(WBNB,USDT,100,P1);factory.setPool(USDT,AMZNX,100,P2);
        usdt.mint(P1,1_000_000 ether);wbnb.mint(P1,1_000_000 ether);stock.mint(P2,1_000_000 ether);usdt.mint(P2,1_000_000 ether);
        guard=new AMZNMockGuard(AMZNX);kernel=new AMZNKernelHarness();executor=kernel.executor();assertEq(executor.configurationAdmin(),ADMIN);adapter=new Adapter(address(executor),address(guard));
        vm.startPrank(ADMIN);executor.proposeStrategy(address(adapter),adapter.strategyIdentity(),adapter.riskConfigCommitment(),adapter.venueDependencyCommitment());
        vm.warp(block.timestamp+24 hours);executor.activateStrategy(address(adapter));vm.stopPrank();
        assertEq(stock.multiplier(),1e18);assertEq(stock.getUnderlyingAmountByShares(AMOUNT),AMOUNT);vm.deal(address(kernel),1 ether);
    }

    function testV3V3ExactInputBuySellAndKernelReceipt() public {
        uint256 before=address(kernel).balance;bytes32 pos=kernel.open(adapter,1,AMOUNT);
        assertGt(adapter.positionShares(pos),0);assertGt(adapter.positionUnderlying(pos),0);
        kernel.exit(1,bytes32(uint256(11)));(uint256 principal,uint256 returned,)=kernel.close(1,bytes32(uint256(12)));
        assertEq(principal,AMOUNT);assertGt(returned,0);assertEq(address(kernel).balance,before-AMOUNT+returned);
        assertEq(adapter.positionShares(pos),0);assertEq(uint256(executor.runState(1)),uint256(T.StrategyRunState.CLOSED));
    }


    function testStaleOrUnknownGuardFailsBeforeCustody() public {
        guard.configure(9_980,61,60,true);vm.expectRevert(Adapter.Unavailable.selector);kernel.open(adapter,2,AMOUNT);
        guard.configure(9_980,0,60,false);vm.expectRevert(Adapter.Unavailable.selector);kernel.open(adapter,2,AMOUNT);
        assertEq(address(kernel).balance,1 ether);assertEq(adapter.totalPositionShares(),0);
    }

    function testGuardValidityExpiryAndPriceDeviationFailClosed() public {
        guard.configure(9_980,0,0,true);vm.expectRevert(Adapter.Unavailable.selector);kernel.open(adapter,3,AMOUNT);
        guard.configure(5_000,0,60,true);vm.expectRevert(Adapter.Unavailable.selector);kernel.open(adapter,3,AMOUNT);
    }

    function testPartialV3FillRevertsAndRestoresAllBalances() public {
        pool2.setFillBps(9_900);uint256 kernelBefore=address(kernel).balance;vm.expectRevert(Adapter.Unavailable.selector);kernel.open(adapter,4,AMOUNT);
        assertEq(address(kernel).balance,kernelBefore);assertEq(adapter.totalPositionShares(),0);assertEq(adapter.positionShares(bytes32(0)),0);
    }

    function testZeroPoolLiquidityFailsClosed() public {
        pool1.setLiquidity(0);vm.expectRevert(Adapter.Unavailable.selector);kernel.open(adapter,5,AMOUNT);
    }

    function testOnlyExecutorCanEnterOrRequestExit() public {
        vm.expectRevert(Adapter.Unauthorized.selector);adapter.open{value:AMOUNT}(1,bytes32(uint256(1)),AMOUNT,0);
        vm.expectRevert(Adapter.Unauthorized.selector);adapter.requestExit(bytes32(uint256(1)),bytes32(uint256(1)));
    }

    function testRebaseUsesPositionSharesForExit() public {
        bytes32 pos=kernel.open(adapter,6,AMOUNT);uint256 shares=adapter.positionShares(pos);
        stock.rebase(2e18);assertEq(adapter.positionShares(pos),shares);assertEq(adapter.positionUnderlying(pos),shares*2);
        kernel.exit(6,bytes32(uint256(61)));(,uint256 returned,)=kernel.close(6,bytes32(uint256(62)));
        assertGt(returned,0);assertEq(stock.sharesOf(address(adapter)),0);
    }

    function testDuplicateRunAndExitIdentityRejected() public {
        kernel.open(adapter,7,AMOUNT);vm.expectRevert();kernel.open(adapter,7,AMOUNT);
        kernel.exit(7,bytes32(uint256(71)));vm.expectRevert();kernel.exit(7,bytes32(uint256(72)));
    }
}
