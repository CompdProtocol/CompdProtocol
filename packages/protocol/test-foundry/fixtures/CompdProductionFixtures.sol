// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// TEST-ONLY fixtures. None of these contracts are referenced by production deployment code.

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Local-only code-bearing stand-in for the future, separately implemented Distributor.
contract MockHolderRewardsDistributor {}
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IQuoteGuard, IPancakeV2RouterLike} from "../../contracts/IQuoteGuard.sol";
import {
    ICompdStrategyAdapter,
    ICompdEquityOracle,
    ICompdBurnSink
} from "../../contracts/production/ICompdProductionInterfaces.sol";

contract MockProductionERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) { return _decimals; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(address from, uint256 amount) external { _burn(from, amount); }
}

/// @dev Local-only token that can burn a configurable percentage from transfers
///      and simulate an unexpected balance loss for accounting-invariant tests.
contract MockFeeOnTransferERC20 is ERC20 {
    uint16 public feeBps;
    bool public senderPaysExtraFee;

    constructor() ERC20("Fee Test Quote", "FTQ") { }

    function setFeeBps(uint16 feeBps_) external {
        require(feeBps_ <= 2_000, "fee too high");
        feeBps = feeBps_;
    }

    function setSenderPaysExtraFee(bool enabled) external { senderPaysExtraFee = enabled; }

    function mint(address to, uint256 amount) external { _mint(to, amount); }

    function confiscate(address from, uint256 amount) external { _burn(from, amount); }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && feeBps != 0) {
            uint256 fee = value * feeBps / 10_000;
            if (senderPaysExtraFee) {
                super._update(from, to, value);
                if (fee != 0) super._update(from, address(0), fee);
            } else {
                super._update(from, to, value - fee);
                if (fee != 0) super._update(from, address(0), fee);
            }
        } else {
            super._update(from, to, value);
        }
    }
}

/// @dev Runtime-etched at the canonical COMPD address in local tests only.
contract MockCompdToken {
    string public constant name = "COMPD Test Fixture";
    string public constant symbol = "tCOMPD";
    uint8 public constant decimals = 18;
    address public immutable taxProcessor;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(address taxProcessor_) { taxProcessor = taxProcessor_; }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

contract MockEquityOracle is ICompdEquityOracle {
    uint256 public equity;
    uint256 public updatedAt;

    function set(uint256 equity_, uint256 updatedAt_) external {
        equity = equity_;
        updatedAt = updatedAt_;
    }

    function strategyEquity() external view returns (uint256 quoteValue, uint256 timestamp) {
        return (equity, updatedAt);
    }
}

contract MockStrategyAdapter is ICompdStrategyAdapter {
    using SafeERC20 for IERC20;

    address public immutable quoteToken;
    mapping(uint256 => uint256) public principalByRun;
    mapping(uint256 => uint256) public returnByRun;
    mapping(uint256 => bool) public returnConfigured;

    constructor(address quoteToken_) { quoteToken = quoteToken_; }

    receive() external payable { }

    function setReturn(uint256 runId, uint256 amount) external {
        returnByRun[runId] = amount;
        returnConfigured[runId] = true;
    }

    function openPosition(uint256 runId, bytes32, address, uint256 amount, uint256) external payable {
        principalByRun[runId] = amount;
        if (quoteToken == address(0)) {
            require(msg.value == amount, "wrong BNB principal");
        } else {
            require(msg.value == 0, "unexpected BNB");
            IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    function closePosition(uint256 runId) external returns (uint256 quoteReturned) {
        uint256 principal = principalByRun[runId];
        require(principal != 0, "no position");
        quoteReturned = returnConfigured[runId] ? returnByRun[runId] : principal;
        if (quoteToken == address(0)) {
            require(address(this).balance >= quoteReturned, "fixture BNB shortfall");
            (bool ok,) = payable(msg.sender).call{value: quoteReturned}("");
            require(ok, "BNB return failed");
        } else {
            uint256 held = IERC20(quoteToken).balanceOf(address(this));
            if (quoteReturned > held) MockProductionERC20(quoteToken).mint(address(this), quoteReturned - held);
            if (quoteReturned < held) MockProductionERC20(quoteToken).burn(address(this), held - quoteReturned);
            IERC20(quoteToken).safeTransfer(msg.sender, quoteReturned);
        }
        delete principalByRun[runId];
    }
}

contract MockQuoteGuard is IQuoteGuard {
    mapping(bytes32 => uint256) public rateWad;
    mapping(bytes32 => uint256) public updatedAtForPath;

    function setRate(address[] calldata path, uint256 rate, uint256 updatedAt_) external {
        bytes32 key = keccak256(abi.encode(path));
        rateWad[key] = rate;
        updatedAtForPath[key] = updatedAt_;
    }

    function quote(address[] calldata path, uint256 amountIn)
        external
        view
        returns (uint256 expectedNetAmountOut, uint256 updatedAt)
    {
        bytes32 key = keccak256(abi.encode(path));
        return (amountIn * rateWad[key] / 1e18, updatedAtForPath[key]);
    }
}

contract MockBuybackRouter is IPancakeV2RouterLike {
    using SafeERC20 for IERC20;
    uint256 public outputRateWad = 2e18;
    uint256 public outputAdjustment;
    bool public subtractOutputAdjustment;

    function setOutputRate(uint256 rate) external { outputRateWad = rate; }
    function setOutputAdjustment(uint256 adjustment, bool subtract) external {
        outputAdjustment = adjustment;
        subtractOutputAdjustment = subtract;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external {
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 out = _adjustOutput(amountIn * outputRateWad / 1e18);
        require(out >= amountOutMin, "slippage");
        MockCompdToken(path[path.length - 1]).mint(to, out);
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external payable {
        uint256 out = _adjustOutput(msg.value * outputRateWad / 1e18);
        require(out >= amountOutMin, "slippage");
        MockCompdToken(path[path.length - 1]).mint(to, out);
    }

    function _adjustOutput(uint256 amount) private view returns (uint256) {
        if (subtractOutputAdjustment) return amount - outputAdjustment;
        return amount + outputAdjustment;
    }
}

contract MockBurnSink is ICompdBurnSink {
    address public immutable token;
    constructor(address token_) { token = token_; }

    function receiveBuyback(uint256 amount) external {
        MockCompdToken(token).transferFrom(msg.sender, address(this), amount);
        MockCompdToken(token).burn(address(this), amount);
    }
}
