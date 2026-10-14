// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {C2G2BTypes as T} from "../../contracts/production/v2/phase7ar2/C2G2BTypesR2.sol";
// DISPOSABLE OFFLINE FIXTURES ONLY. These are not canonical Flap implementations,
// a production quote guard, a deployed COMPD token or proof of live compatibility.
contract OfflineToken {
    mapping(address=>uint256) public balanceOf;
    uint256 public totalSupply;
    address public taxProcessor;
    event Transfer(address indexed from,address indexed to,uint256 amount);
    function setProcessor(address p) external { taxProcessor=p; }
    function mint(address to,uint256 n) external {balanceOf[to]+=n;totalSupply+=n;emit Transfer(address(0),to,n);}
    function transfer(address to,uint256 n) external returns(bool){require(balanceOf[msg.sender]>=n);balanceOf[msg.sender]-=n;balanceOf[to]+=n;emit Transfer(msg.sender,to,n);return true;}
    function state() external pure returns(uint8){return 0;}
    function mainPool() external pure returns(address){return address(0);}
}
contract OfflinePurchasePortal {
    struct ExactInputParams {address inputToken;address outputToken;uint256 inputAmount;uint256 minOutputAmount;bytes permitData;}
    struct QuoteParams {address inputToken;address outputToken;uint256 inputAmount;}
    bool public fail;
    function setFail(bool b) external {fail=b;}
    function getTokenV8Safe(address) external pure returns(uint256[18] memory x){x[0]=1;x[4]=6;}
    function quoteExactInput(QuoteParams calldata) external pure returns(uint256){return 1000;}
    function swapExactInput(ExactInputParams calldata p) external payable returns(uint256){
        require(!fail&&p.inputToken==address(0)&&p.outputToken==0x7b7Af51136574c91A12988989c0a08E98aE97777&&p.inputAmount==msg.value&&p.minOutputAmount<=1000&&p.permitData.length==0);
        OfflineToken(p.outputToken).mint(msg.sender,1000);return 1000;
    }
}
interface IOfflineFactory {function newVault(address,address,address,bytes calldata) external returns(address);}
contract OfflineVaultPortal {
    function bind(address factory,address token) external returns(address){return IOfflineFactory(factory).newVault(token,address(0),msg.sender,"");}
}
contract OfflineQuoteGuard {
    uint64 public observed;
    uint64 public deadline;
    bool public valid;
    function configure(bool v,uint64 o,uint64 d) external {valid=v;observed=o;deadline=d;}
    function routeVerified(address p,address t,bytes32 h) external view returns(bool){return valid&&p==0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0&&t==0x7b7Af51136574c91A12988989c0a08E98aE97777&&t.codehash==h;}
    function quote(bytes32,uint256) external view returns(uint256,uint256,uint64,uint64){require(valid);return(1000,970,observed,deadline);}
}
contract OfflineTaxProcessor {
    address public taxToken;
    address public marketAddress;
    address public lastCaller;
    uint256 public dispatched;
    bool public fail;
    constructor(address t,address r){taxToken=t;marketAddress=r;}
    receive() external payable {}
    function setFail(bool b) external {fail=b;}
    function dispatch() external {require(!fail);lastCaller=msg.sender;uint256 n=address(this).balance;dispatched+=n;(bool ok,)=marketAddress.call{value:n}("");require(ok);}
}
contract OfflineStrategyAdapter {
    receive() external payable {}
    bytes32 public strategyIdentity;
    bytes32 public riskConfigCommitment;
    bytes32 public venueDependencyCommitment;
    constructor(bytes32 i,bytes32 r,bytes32 v){strategyIdentity=i;riskConfigCommitment=r;venueDependencyCommitment=v;}
    function open(uint256,bytes32,uint256,uint256) external payable returns(bytes32){return keccak256(abi.encode(msg.sender,msg.value,block.number));}
    function requestExit(bytes32,bytes32) external pure returns(T.AdapterPositionStatus){return T.AdapterPositionStatus.EXIT_REQUESTED;}
    function observe(bytes32) external pure returns(T.AdapterPositionStatus,uint256,bytes32){return(T.AdapterPositionStatus.EXIT_REQUESTED,0,bytes32(0));}
    function collect(bytes32,bytes32,uint256) external pure returns(uint256,bytes32){return(0,bytes32(0));}
    function close(bytes32 p,bytes32) external returns(bytes32){(bool ok,)=msg.sender.call{value:address(this).balance}("");require(ok);return p;}
}
contract OfflineHolderReceiver {
    bool public accept;
    function setAccept(bool b) external {accept=b;}
    receive() external payable {require(accept);}
}
