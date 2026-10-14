// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {C2G2BTypes as T, IC2G2BStrategyAdapterR4} from "../../v2/phase7ar2/C2G2BTypesR2.sol";
import {IXStockToken, IXStockIndependentGuard} from "./CompdPancakeXStocksAdapterV3.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IAMZNxV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool);
    function swap(address, bool, int256, uint160, bytes calldata) external returns (int256, int256);
}

interface IAMZNxV3Factory { function getPool(address, address, uint24) external view returns (address); }
interface IAMZNxERC20 { function balanceOf(address) external view returns (uint256); function transfer(address,uint256) external returns (bool); }
interface IAMZNxWBNB is IAMZNxERC20 { function deposit() external payable; function withdraw(uint256) external; }
interface IAMZNxGuardBinding is IXStockIndependentGuard { function token() external view returns(address); }

/// @notice Fixed AMZNx WBNB -> USDT -> AMZNx PancakeSwap V3/V3 strategy adapter.
/// @dev No route, recipient, router, or calldata setters. Adapter execution is
///      restricted to its immutable StrategyExecutor; quotes fail closed unless
///      the immutable independent guard reports fresh, open-market evidence.
///      Position custody is tracked in xStock shares to tolerate rebases.
contract CompdAMZNxV3V3Adapter is IC2G2BStrategyAdapterR4 {
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public constant AMZNX = 0x3557Ba345B01EFa20A1bdDC61F573BFD87195081;
    address public constant V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address public constant WBNB_USDT_POOL = 0x172fcD41E0913e95784454622d1c3724f546f849;
    address public constant USDT_AMZNX_POOL = 0x28A73f5bd589Fea90BA0D24117BF91D648be3ef2;
    uint24 public constant WBNB_USDT_FEE = 100;
    uint24 public constant USDT_AMZNX_FEE = 100;
    uint256 private constant BPS = 10_000;
    uint256 private constant Q96 = 2 ** 96;
    uint256 private constant FEE_DENOMINATOR = 1_000_000;
    uint256 private constant MAX_REFERENCE_DEVIATION_BPS = 300;
    uint256 private constant MIN_OUTPUT_SLIPPAGE_BPS = 50;
    uint256 private constant MAX_AVERAGE_IMPACT_BPS = 100;
    uint256 private constant MAX_SQRT_MOVE_BPS = 50;
    uint256 private constant MAX_FEED_AGE = 60;
    uint160 private constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
    uint160 private constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

    address public immutable executor;
    address public immutable guard;
    bytes32 public immutable guardHash;
    bytes32 public immutable wbnbHash;
    bytes32 public immutable usdtHash;
    bytes32 public immutable amznHash;
    bytes32 public immutable factoryHash;
    bytes32 public immutable wbnbUsdtPoolHash;
    bytes32 public immutable usdtAmznPoolHash;
    bytes32 public immutable strategyIdentity;
    bytes32 public immutable riskConfigCommitment;
    bytes32 public immutable venueDependencyCommitment;

    struct Position { uint256 principal; uint256 proceeds; uint256 shares; bytes32 exitId; bool exists; bool closed; }
    mapping(bytes32 => Position) public positions;
    mapping(bytes32 => uint256) public positionShares;
    mapping(uint256 => bool) public runUsed;
    mapping(bytes32 => bool) public allocationUsed;
    uint256 public totalPositionShares;

    bool private entered;
    bool private swapping;
    bool private callbackPaid;
    address private callbackPool;
    address private callbackToken;
    uint256 private callbackInput;
    uint256 private callbackShareInput;

    error Invalid(); error Unauthorized(); error Unavailable(); error TransferFailed();
    event Bought(bytes32 indexed position,uint256 bnb,uint256 tokenUnderlying,uint256 shares);
    event Sold(bytes32 indexed position,uint256 tokenUnderlying,uint256 shares,uint256 bnb);

    modifier onlyExecutor() { if (msg.sender != executor) revert Unauthorized(); _; }
    modifier lock() { if (entered) revert Unauthorized(); entered = true; _; entered = false; }

    constructor(address executor_, address guard_) {
        if (block.chainid != 56 || executor_.code.length == 0 || guard_.code.length == 0) revert Invalid();
        if (IAMZNxV3Factory(V3_FACTORY).getPool(WBNB, USDT, WBNB_USDT_FEE) != WBNB_USDT_POOL ||
            IAMZNxV3Factory(V3_FACTORY).getPool(USDT, AMZNX, USDT_AMZNX_FEE) != USDT_AMZNX_POOL) revert Invalid();
        _validatePool(WBNB_USDT_POOL, WBNB, USDT, WBNB_USDT_FEE);
        _validatePool(USDT_AMZNX_POOL, USDT, AMZNX, USDT_AMZNX_FEE);
        if (AMZNX.code.length == 0 || WBNB.code.length == 0 || USDT.code.length == 0 ||
            IAMZNxGuardBinding(guard_).token() != AMZNX) revert Invalid();

        executor = executor_; guard = guard_;
        guardHash = guard_.codehash; wbnbHash = WBNB.codehash; usdtHash = USDT.codehash;
        amznHash = AMZNX.codehash; factoryHash = V3_FACTORY.codehash;
        wbnbUsdtPoolHash = WBNB_USDT_POOL.codehash; usdtAmznPoolHash = USDT_AMZNX_POOL.codehash;
        strategyIdentity = keccak256(abi.encode("COMPD_PANCAKE_V3V3_AMZNX", block.chainid, AMZNX));
        riskConfigCommitment = keccak256(abi.encode(MAX_REFERENCE_DEVIATION_BPS, MIN_OUTPUT_SLIPPAGE_BPS, MAX_FEED_AGE, MAX_AVERAGE_IMPACT_BPS, guard_, guardHash));
        venueDependencyCommitment = keccak256(abi.encode(WBNB, USDT, AMZNX, V3_FACTORY, WBNB_USDT_POOL, WBNB_USDT_FEE, USDT_AMZNX_POOL, USDT_AMZNX_FEE, wbnbHash, usdtHash, amznHash, factoryHash, wbnbUsdtPoolHash, usdtAmznPoolHash));
    }

    receive() external payable { if (msg.sender != WBNB) revert Unauthorized(); }

    function _validatePool(address pool, address a, address b, uint24 fee_) private view {
        if (pool.code.length == 0 || IAMZNxV3Pool(pool).fee() != fee_ || IAMZNxV3Pool(pool).liquidity() == 0) revert Invalid();
        address t0 = IAMZNxV3Pool(pool).token0(); address t1 = IAMZNxV3Pool(pool).token1();
        if (!((t0 == a && t1 == b) || (t0 == b && t1 == a))) revert Invalid();
    }

    function _checkDependencies() private view {
        if (block.chainid != 56 || guard.codehash != guardHash || WBNB.codehash != wbnbHash || USDT.codehash != usdtHash ||
            AMZNX.codehash != amznHash || V3_FACTORY.codehash != factoryHash || WBNB_USDT_POOL.codehash != wbnbUsdtPoolHash ||
            USDT_AMZNX_POOL.codehash != usdtAmznPoolHash || IAMZNxGuardBinding(guard).token() != AMZNX ||
            IAMZNxV3Factory(V3_FACTORY).getPool(WBNB, USDT, WBNB_USDT_FEE) != WBNB_USDT_POOL ||
            IAMZNxV3Factory(V3_FACTORY).getPool(USDT, AMZNX, USDT_AMZNX_FEE) != USDT_AMZNX_POOL ||
            IAMZNxV3Pool(WBNB_USDT_POOL).liquidity() == 0 || IAMZNxV3Pool(USDT_AMZNX_POOL).liquidity() == 0) revert Unavailable();
    }

    function _freshReference(bool buy, uint256 amount) private view returns (uint256 ref) {
        (uint256 value,uint64 observedAt,uint64 validUntil,bool marketOpen) = IXStockIndependentGuard(guard).referenceOut(AMZNX, buy, amount);
        if (!marketOpen || value == 0 || observedAt == 0 || observedAt > block.timestamp || block.timestamp - observedAt > MAX_FEED_AGE ||
            validUntil <= block.timestamp || validUntil > block.timestamp + MAX_FEED_AGE) revert Unavailable();
        return value;
    }

    function _sqrt(address pool) private view returns (uint160 price) {
        bool unlocked;
        (price,,,,,,unlocked) = IAMZNxV3Pool(pool).slot0();
        if (!unlocked || price == 0) revert Unavailable();
    }

    function _spotOut(address pool, address tokenIn, uint256 amountIn) private view returns (uint256 out) {
        address t0 = IAMZNxV3Pool(pool).token0(); address t1 = IAMZNxV3Pool(pool).token1();
        if (tokenIn != t0 && tokenIn != t1) revert Unavailable();
        uint160 s = _sqrt(pool); bool zeroForOne = tokenIn == t0;
        out = zeroForOne ? Math.mulDiv(Math.mulDiv(amountIn, s, Q96), s, Q96) : Math.mulDiv(Math.mulDiv(amountIn, Q96, s), Q96, s);
        uint24 fee_ = IAMZNxV3Pool(pool).fee();
        out -= Math.mulDiv(out, fee_, FEE_DENOMINATOR);
        if (out == 0) revert Unavailable();
    }

    function _spotRoute(bool buy, uint256 amount) private view returns (uint256 output) {
        if (buy) return _spotOut(USDT_AMZNX_POOL, USDT, _spotOut(WBNB_USDT_POOL, WBNB, amount));
        return _spotOut(WBNB_USDT_POOL, USDT, _spotOut(USDT_AMZNX_POOL, AMZNX, amount));
    }

    function quote(bool buy, uint256 amount) external view returns (uint256) { return _minimum(buy, amount); }

    function _minimum(bool buy, uint256 amount) private view returns (uint256 minimum) {
        _checkDependencies(); uint256 refPrice = _freshReference(buy, amount); uint256 estimate = _spotRoute(buy, amount);
        uint256 difference = estimate > refPrice ? estimate - refPrice : refPrice - estimate;
        if (Math.mulDiv(difference, BPS, refPrice) > MAX_REFERENCE_DEVIATION_BPS) revert Unavailable();
        uint256 basis = estimate > refPrice ? estimate : refPrice;
        minimum = basis - Math.mulDiv(basis, MIN_OUTPUT_SLIPPAGE_BPS, BPS);
        if (minimum == 0) revert Unavailable();
    }

    function _sqrtLimit(address pool, bool zeroForOne) private view returns (uint160 limit) {
        uint256 s = _sqrt(pool);
        uint256 l = zeroForOne ? Math.mulDiv(s, BPS - MAX_SQRT_MOVE_BPS, BPS) : Math.mulDiv(s, BPS + MAX_SQRT_MOVE_BPS, BPS);
        if (l <= MIN_SQRT_RATIO_PLUS_ONE || l >= MAX_SQRT_RATIO_MINUS_ONE) revert Unavailable();
        return uint160(l);
    }

    function _swapExactInput(address pool, address tokenIn, uint256 amountIn, uint256 sharesIn) private returns (uint256 amountOut) {
        if (amountIn == 0 || amountIn > uint256(type(int256).max)) revert Invalid();
        address t0 = IAMZNxV3Pool(pool).token0(); bool zeroForOne = tokenIn == t0;
        address t1 = IAMZNxV3Pool(pool).token1(); if (!zeroForOne && tokenIn != t1) revert Invalid();
        uint160 s = _sqrt(pool); uint256 spot = _spotOut(pool, tokenIn, amountIn);
        callbackPool = pool; callbackToken = tokenIn; callbackInput = amountIn; callbackShareInput = sharesIn; callbackPaid = false; swapping = true;
        (int256 d0,int256 d1) = IAMZNxV3Pool(pool).swap(address(this), zeroForOne, int256(amountIn), _sqrtLimit(pool, zeroForOne), "");
        swapping = false; callbackPool = address(0); callbackToken = address(0); callbackInput = 0; callbackShareInput = 0;
        int256 used = zeroForOne ? d0 : d1; int256 received = zeroForOne ? d1 : d0;
        if (!callbackPaid || used != int256(amountIn) || received >= 0 || received == type(int256).min) revert Unavailable();
        amountOut = uint256(-received);
        uint256 impactFloor = spot - Math.mulDiv(spot, MAX_AVERAGE_IMPACT_BPS, BPS);
        if (amountOut < impactFloor) revert Unavailable();
        // Ensure the pool moved no farther than the configured sqrt-price bound.
        (uint160 afterSqrt,,,,,,) = IAMZNxV3Pool(pool).slot0();
        if (zeroForOne ? afterSqrt < _sqrtLimitFrom(s, true) : afterSqrt > _sqrtLimitFrom(s, false)) revert Unavailable();
    }

    function _sqrtLimitFrom(uint160 s, bool zeroForOne) private pure returns (uint160) {
        uint256 l = zeroForOne ? Math.mulDiv(s, BPS - MAX_SQRT_MOVE_BPS, BPS) : Math.mulDiv(s, BPS + MAX_SQRT_MOVE_BPS, BPS);
        if (l <= MIN_SQRT_RATIO_PLUS_ONE || l >= MAX_SQRT_RATIO_MINUS_ONE) revert Unavailable();
        return uint160(l);
    }

    function pancakeV3SwapCallback(int256 d0, int256 d1, bytes calldata) external {
        if (msg.sender != callbackPool || !entered || !swapping || callbackPaid) revert Unauthorized();
        bool zeroForOne = IAMZNxV3Pool(msg.sender).token0() == callbackToken;
        int256 owed = zeroForOne ? d0 : d1; int256 other = zeroForOne ? d1 : d0;
        if (owed <= 0 || uint256(owed) != callbackInput || other >= 0) revert Invalid();
        callbackPaid = true;
        if (callbackToken == AMZNX) {
            if (callbackShareInput == 0 || IXStockToken(AMZNX).getUnderlyingAmountByShares(callbackShareInput) != callbackInput ||
                !IXStockToken(AMZNX).transferShares(msg.sender, callbackShareInput)) revert TransferFailed();
        } else if (!IAMZNxERC20(callbackToken).transfer(msg.sender, callbackInput)) revert TransferFailed();
    }

    function open(uint256 run, bytes32 allocation, uint256 principal, uint256) external payable onlyExecutor lock returns (bytes32 id) {
        if (run == 0 || allocation == bytes32(0) || principal == 0 || msg.value != principal || runUsed[run] || allocationUsed[allocation]) revert Invalid();
        uint256 minimum = _minimum(true, principal); uint256 nativeBefore = address(this).balance - msg.value;
        uint256 wbnbBefore = IAMZNxERC20(WBNB).balanceOf(address(this)); uint256 usdtBefore = IAMZNxERC20(USDT).balanceOf(address(this));
        uint256 sharesBefore = IXStockToken(AMZNX).sharesOf(address(this)); uint256 underlyingBefore = IXStockToken(AMZNX).balanceOf(address(this));
        runUsed[run] = true; allocationUsed[allocation] = true; id = keccak256(abi.encode(block.chainid,address(this),run,allocation));
        IAMZNxWBNB(WBNB).deposit{value: principal}();
        uint256 intermediate = _swapExactInput(WBNB_USDT_POOL,WBNB,principal,0);
        uint256 acquiredBySwap = _swapExactInput(USDT_AMZNX_POOL,USDT,intermediate,0);
        uint256 shares = IXStockToken(AMZNX).sharesOf(address(this)) - sharesBefore;
        uint256 underlying = IXStockToken(AMZNX).getUnderlyingAmountByShares(shares);
        if (acquiredBySwap < minimum || underlying < minimum || IXStockToken(AMZNX).balanceOf(address(this)) - underlyingBefore < minimum || shares == 0 ||
            IAMZNxERC20(WBNB).balanceOf(address(this)) != wbnbBefore || IAMZNxERC20(USDT).balanceOf(address(this)) != usdtBefore || address(this).balance != nativeBefore) revert Unavailable();
        positionShares[id] = shares; totalPositionShares += shares; positions[id] = Position(principal,0,shares,bytes32(0),true,false);
        emit Bought(id,principal,underlying,shares);
    }

    function requestExit(bytes32 id, bytes32 exitId) external onlyExecutor lock returns (T.AdapterPositionStatus) {
        Position storage p = positions[id];
        if (!p.exists || p.closed || exitId == bytes32(0)) revert Invalid();
        if (p.exitId != bytes32(0)) { if (p.exitId != exitId) revert Invalid(); return T.AdapterPositionStatus.RETURN_PENDING; }
        uint256 owned = positionShares[id]; uint256 allShares = IXStockToken(AMZNX).sharesOf(address(this));
        if (owned == 0 || allShares < totalPositionShares) revert Invalid();
        uint256 tokenInput = IXStockToken(AMZNX).getUnderlyingAmountByShares(owned); uint256 minimum = _minimum(false,tokenInput);
        uint256 usdtBefore = IAMZNxERC20(USDT).balanceOf(address(this)); uint256 wbnbBefore = IAMZNxERC20(WBNB).balanceOf(address(this));
        uint256 nativeBefore = address(this).balance; uint256 sharesBefore = IXStockToken(AMZNX).sharesOf(address(this));
        uint256 stable = _swapExactInput(USDT_AMZNX_POOL,AMZNX,tokenInput,owned);
        uint256 wrapped = _swapExactInput(WBNB_USDT_POOL,USDT,stable,0);
        if (wrapped < minimum || IXStockToken(AMZNX).sharesOf(address(this)) != sharesBefore - owned ||
            IAMZNxERC20(USDT).balanceOf(address(this)) != usdtBefore || IAMZNxERC20(WBNB).balanceOf(address(this)) != wbnbBefore + wrapped) revert Unavailable();
        IAMZNxWBNB(WBNB).withdraw(wrapped); uint256 received = address(this).balance - nativeBefore;
        if (received < minimum) revert Unavailable();
        positionShares[id] = 0; totalPositionShares -= owned; p.shares = 0; p.proceeds = received; p.exitId = exitId;
        emit Sold(id,tokenInput,owned,received); return T.AdapterPositionStatus.RETURN_PENDING;
    }

    function positionUnderlying(bytes32 id) external view returns (uint256) { return IXStockToken(AMZNX).getUnderlyingAmountByShares(positionShares[id]); }
    function observe(bytes32 id) external view returns (T.AdapterPositionStatus,uint256,bytes32) {
        Position storage p = positions[id]; if (!p.exists) revert Invalid();
        return (p.closed ? T.AdapterPositionStatus.CLOSED : p.exitId == bytes32(0) ? T.AdapterPositionStatus.OPEN : T.AdapterPositionStatus.RETURN_PENDING,p.proceeds,bytes32(0));
    }
    function collect(bytes32,bytes32,uint256) external onlyExecutor view returns (uint256,bytes32) { return (0,bytes32(0)); }
    function close(bytes32 id, bytes32 closeId) external onlyExecutor lock returns (bytes32) {
        Position storage p = positions[id];
        if (!p.exists || p.closed || p.exitId == bytes32(0) || closeId == bytes32(0) || p.shares != 0 || positionShares[id] != 0) revert Invalid();
        uint256 amount = p.proceeds; p.proceeds = 0; p.closed = true;
        (bool ok,) = payable(executor).call{value:amount}(""); if (!ok) revert TransferFailed(); return id;
    }
}
