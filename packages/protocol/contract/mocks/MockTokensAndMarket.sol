// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IQuoteGuard} from "../IQuoteGuard.sol";
import {IStrategyRunStatus} from "../IQuoteGuard.sol";

contract MockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev Test-only wrapped-native token used to exercise native Flap quote settlement.
contract MockWrappedNative is ERC20 {
    constructor() ERC20("Wrapped Native", "WNATIVE") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, "native withdraw failed");
    }
}

contract MockStrategyRegistry is IStrategyRunStatus {
    struct Run { bool active; uint8 status; bytes32 strategyId; }
    mapping(uint256 => Run) public runs;
    function setRun(uint256 runId, bool active, uint8 status, bytes32 strategyId) external {
        runs[runId] = Run(active, status, strategyId);
    }
    function isActiveRun(uint256 runId) external view returns (bool) { return runs[runId].active; }
    function runStatus(uint256 runId) external view returns (uint8) { return runs[runId].status; }
    function strategyIdForRun(uint256 runId) external view returns (bytes32) { return runs[runId].strategyId; }
}

/// @dev Test-only fixed-rate quote and router. Never deploy these mocks.
contract MockQuoteGuard is IQuoteGuard {
    uint256 public multiplier = 2;
    uint256 public timestampOffset;

    function setMultiplier(uint256 value) external { multiplier = value; }
    function setTimestampOffset(uint256 value) external { timestampOffset = value; }

    function quote(address[] calldata, uint256 amountIn) external view returns (uint256, uint256) {
        uint256 updatedAt = block.timestamp;
        if (timestampOffset > updatedAt) updatedAt = 0;
        else updatedAt -= timestampOffset;
        return (amountIn * multiplier, updatedAt);
    }
}

contract MockPancakeRouter {
    using SafeERC20 for IERC20;

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external {
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 amountOut = amountIn * 2;
        require(amountOut >= amountOutMin, "slippage");
        IERC20(path[path.length - 1]).safeTransfer(to, amountOut);
    }
}

contract MockRevertingRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256, uint256, address[] calldata, address, uint256
    ) external pure { revert("mock router failure"); }
}

contract MockShortOutputRouter {
    using SafeERC20 for IERC20;
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn, uint256, address[] calldata path, address to, uint256
    ) external {
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(path[path.length - 1]).safeTransfer(to, amountIn); // deliberately less than the quote
    }
}

contract MockPartialSpendRouter {
    using SafeERC20 for IERC20;
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn, uint256, address[] calldata path, address to, uint256
    ) external {
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn / 2);
        IERC20(path[path.length - 1]).safeTransfer(to, amountIn * 2);
    }
}

contract MockNativePancakeRouter {
    using SafeERC20 for IERC20;
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256
    ) external {
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * 2;
        require(out >= amountOutMin, "slippage");
        IERC20(path[path.length - 1]).safeTransfer(to, out);
    }
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin, address[] calldata path, address to, uint256
    ) external payable {
        uint256 out = msg.value * 2;
        require(out >= amountOutMin, "slippage");
        IERC20(path[path.length - 1]).safeTransfer(to, out);
    }
}

contract ReenteringRouter {
    using SafeERC20 for IERC20;

    address public target;
    bytes public reentryCall;
    bool private attempted;
    uint256 public calls;

    function configure(address target_, bytes calldata callData) external {
        target = target_;
        reentryCall = callData;
        attempted = false;
        calls = 0;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external {
        ++calls;
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        if (!attempted) {
            attempted = true;
            (bool success,) = target.call(reentryCall);
            require(!success, "reentrant strategy call succeeded");
        }
        uint256 amountOut = amountIn * 2;
        require(amountOut >= amountOutMin, "slippage");
        IERC20(path[path.length - 1]).safeTransfer(to, amountOut);
    }
}
