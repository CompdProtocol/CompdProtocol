// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ICompdProductionVaultView,
    ICompdStrategyAdapter,
    ICompdEquityOracle
} from "./ICompdProductionInterfaces.sol";

/// @notice Narrow Strategy Capital executor with fixed V1 risk caps.
/// @dev It fails closed until an audited execution adapter, fresh equity source and allowlists are configured.
contract CompdStrategyExecutor is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_TOTAL_EXPOSURE_BPS = 3_000;
    uint256 public constant MAX_POSITION_BPS = 1_000;
    uint256 public constant DAILY_REALIZED_LOSS_BPS = 500;
    uint256 public constant MAX_DRAWDOWN_BPS = 1_000;
    uint256 public constant MAX_DESIGNED_LOSS_BPS = 300;
    uint256 public constant MAX_CONCURRENT_POSITIONS = 3;

    address public constant AUTOMATION_EXECUTOR = 0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;
    address public constant GUARDIAN = 0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1;

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidLifecycle();
    error InvalidPosition();
    error RiskLimitExceeded();
    error DependencyUnavailable();
    error StaleEquity(uint256 updatedAt);
    error DrawdownLatched();

    struct Position {
        bytes32 market;
        address asset;
        uint256 principal;
        uint256 declaredMaxLoss;
        bool active;
    }

    ICompdProductionVaultView public immutable vault;
    address public adapter;
    address public equityOracle;
    uint64 public maxEquityAge;

    uint256 public activePositionCount;
    uint256 public outstandingPrincipal;
    uint256 public activeExposure;
    uint256 public nextRunId = 1;
    uint256 public equityHighWaterMark;
    uint256 public dailyPeriod;
    uint256 public dailyStartStrategyCapital;
    uint256 public dailyRealizedLoss;
    bool public drawdownTripped;
    bool public designedLossBreachTripped;

    mapping(bytes32 => address) public marketAsset;
    mapping(uint256 => Position) public positions;
    mapping(uint256 => bool) public isActiveRun;
    mapping(uint256 => uint8) public runStatus;
    mapping(uint256 => bytes32) public strategyIdForRun;

    event AdapterConfigured(address indexed adapter);
    event EquityOracleConfigured(address indexed oracle, uint64 maxAge);
    event MarketAllowlistUpdated(bytes32 indexed market, address indexed asset, bool allowed);
    event PositionOpened(uint256 indexed runId, bytes32 indexed market, address indexed asset, uint256 principal, uint256 declaredMaxLoss);
    event PositionClosed(uint256 indexed runId, uint256 principal, uint256 returnedAmount, uint256 realizedProfit, uint256 realizedLoss);
    event DrawdownCircuitBreakerTripped(uint256 highWaterMark, uint256 currentEquity, uint256 drawdownBps);
    event DrawdownCircuitBreakerResumed(uint256 highWaterMark, uint256 currentEquity);
    event DesignedLossLimitBreached(uint256 indexed runId, uint256 declaredMaxLoss, uint256 actualLoss);
    event DesignedLossBreachCleared(address indexed guardian);
    event RiskStatusRefreshed(uint256 currentEquity, uint256 highWaterMark, bool tripped);

    constructor(address vault_, address configurationAdmin) {
        if (vault_.code.length == 0 || configurationAdmin == address(0)) revert InvalidConfiguration();
        vault = ICompdProductionVaultView(vault_);
        _grantRole(DEFAULT_ADMIN_ROLE, configurationAdmin);
    }

    receive() external payable {
        if (msg.sender != address(vault) && msg.sender != adapter) revert Unauthorized();
    }

    function configureDependencies(address adapter_, address oracle_, uint64 maxAge)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _requireConfigurable();
        if (adapter_.code.length == 0 || oracle_.code.length == 0 || maxAge == 0) revert InvalidConfiguration();
        adapter = adapter_;
        equityOracle = oracle_;
        maxEquityAge = maxAge;
        emit AdapterConfigured(adapter_);
        emit EquityOracleConfigured(oracle_, maxAge);
    }

    function setMarketAsset(bytes32 market, address asset, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireConfigurable();
        if (market == bytes32(0) || (allowed && asset.code.length == 0)) revert InvalidConfiguration();
        if (allowed) marketAsset[market] = asset;
        else {
            if (marketAsset[market] != asset) revert InvalidConfiguration();
            delete marketAsset[market];
        }
        emit MarketAllowlistUpdated(market, asset, allowed);
    }

    function openPosition(bytes32 market, address asset, uint256 amount, uint256 declaredMaxLoss)
        external
        nonReentrant
        returns (uint256 runId)
    {
        if (msg.sender != AUTOMATION_EXECUTOR) revert Unauthorized();
        if (vault.lifecycle() != 0) revert InvalidLifecycle(); // ACTIVE only.
        if (adapter == address(0) || equityOracle == address(0) || marketAsset[market] != asset || asset.code.length == 0) {
            revert DependencyUnavailable();
        }
        if (drawdownTripped || designedLossBreachTripped) revert DrawdownLatched();
        if (amount == 0 || declaredMaxLoss == 0 || activePositionCount >= MAX_CONCURRENT_POSITIONS) {
            revert InvalidPosition();
        }

        uint256 capital = vault.strategyCapital();
        if (
            amount > capital * MAX_POSITION_BPS / BPS || activeExposure + amount > capital * MAX_TOTAL_EXPOSURE_BPS / BPS
                || declaredMaxLoss > capital * MAX_DESIGNED_LOSS_BPS / BPS
        ) revert RiskLimitExceeded();

        _rollDailyPeriod();
        if (dailyRealizedLoss >= dailyStartStrategyCapital * DAILY_REALIZED_LOSS_BPS / BPS) revert RiskLimitExceeded();

        (uint256 equity,) = _readEquity();
        if (equityHighWaterMark == 0) equityHighWaterMark = equity;
        else if (equity > equityHighWaterMark) equityHighWaterMark = equity;
        uint256 drawdown = equityHighWaterMark > equity
            ? (equityHighWaterMark - equity) * BPS / equityHighWaterMark
            : 0;
        if (drawdown >= MAX_DRAWDOWN_BPS) {
            drawdownTripped = true;
            emit DrawdownCircuitBreakerTripped(equityHighWaterMark, equity, drawdown);
            return 0; // Latch safely; do not revert away the breaker state.
        }

        runId = nextRunId++;
        positions[runId] = Position(market, asset, amount, declaredMaxLoss, true);
        isActiveRun[runId] = true;
        runStatus[runId] = 1;
        strategyIdForRun[runId] = market;
        activePositionCount += 1;
        activeExposure += amount;
        outstandingPrincipal += amount;

        address quote = vault.quoteToken();
        uint256 beforeBalance = _quoteBalance(quote);
        vault.allocateStrategyPrincipal(runId, amount);
        if (_quoteBalance(quote) - beforeBalance != amount) revert InvalidConfiguration();
        uint256 afterAllocation = _quoteBalance(quote);
        if (quote == address(0)) {
            ICompdStrategyAdapter(adapter).openPosition{value: amount}(runId, market, asset, amount, declaredMaxLoss);
        } else {
            IERC20(quote).forceApprove(adapter, amount);
            ICompdStrategyAdapter(adapter).openPosition(runId, market, asset, amount, declaredMaxLoss);
            IERC20(quote).forceApprove(adapter, 0);
        }
        if (_quoteBalance(quote) != afterAllocation - amount) revert InvalidConfiguration();
        emit PositionOpened(runId, market, asset, amount, declaredMaxLoss);
    }

    /// @notice Closes through the one configured adapter and settles measured quote proceeds.
    /// @dev Closing is permitted while paused or shutdown-pending; new exposure is not.
    function closePosition(uint256 runId) external nonReentrant {
        if (msg.sender != AUTOMATION_EXECUTOR) revert Unauthorized();
        Position memory position = positions[runId];
        if (!position.active || adapter == address(0)) revert InvalidPosition();
        address quote = vault.quoteToken();
        uint256 beforeBalance = _quoteBalance(quote);
        uint256 reported;
        if (quote == address(0)) reported = ICompdStrategyAdapter(adapter).closePosition(runId);
        else reported = ICompdStrategyAdapter(adapter).closePosition(runId);
        uint256 afterBalance = _quoteBalance(quote);
        if (afterBalance < beforeBalance) revert InvalidConfiguration();
        uint256 returnedAmount = afterBalance - beforeBalance;
        if (reported != returnedAmount) revert InvalidConfiguration();

        _rollDailyPeriod();
        delete positions[runId];
        isActiveRun[runId] = false;
        runStatus[runId] = 2;
        activePositionCount -= 1;
        outstandingPrincipal -= position.principal;
        activeExposure -= position.principal;
        uint256 loss;
        uint256 profit;
        if (returnedAmount < position.principal) {
            loss = position.principal - returnedAmount;
            dailyRealizedLoss += loss;
            if (loss > position.declaredMaxLoss) {
                designedLossBreachTripped = true;
                emit DesignedLossLimitBreached(runId, position.declaredMaxLoss, loss);
            }
        } else if (returnedAmount > position.principal) {
            profit = returnedAmount - position.principal;
        }

        if (quote == address(0)) {
            vault.settleStrategyPrincipal{value: returnedAmount}(runId, returnedAmount);
        } else {
            if (returnedAmount != 0) IERC20(quote).forceApprove(address(vault), returnedAmount);
            vault.settleStrategyPrincipal(runId, returnedAmount);
            if (returnedAmount != 0) IERC20(quote).forceApprove(address(vault), 0);
        }
        _tryRefreshAfterSettlement();
        emit PositionClosed(runId, position.principal, returnedAmount, profit, loss);
    }

    /// @notice Anyone can refresh the authenticated equity feed; a breached drawdown stays latched.
    function refreshRiskStatus() external returns (uint256 equity) {
        (equity,) = _readEquity();
        if (equityHighWaterMark == 0 || equity > equityHighWaterMark) equityHighWaterMark = equity;
        uint256 drawdown = equityHighWaterMark > equity
            ? (equityHighWaterMark - equity) * BPS / equityHighWaterMark
            : 0;
        if (drawdown >= MAX_DRAWDOWN_BPS && !drawdownTripped) {
            drawdownTripped = true;
            emit DrawdownCircuitBreakerTripped(equityHighWaterMark, equity, drawdown);
        }
        emit RiskStatusRefreshed(equity, equityHighWaterMark, drawdownTripped);
    }

    function resumeAfterDrawdown() external {
        if (msg.sender != GUARDIAN) revert Unauthorized();
        if (!drawdownTripped) revert InvalidPosition();
        (uint256 equity,) = _readEquity();
        uint256 minimumEquity = equityHighWaterMark * (BPS - MAX_DRAWDOWN_BPS) / BPS;
        if (equity < minimumEquity) revert RiskLimitExceeded();
        drawdownTripped = false;
        emit DrawdownCircuitBreakerResumed(equityHighWaterMark, equity);
    }

    function clearDesignedLossBreachAfterReview() external {
        if (msg.sender != GUARDIAN) revert Unauthorized();
        if (!designedLossBreachTripped || activePositionCount != 0 || vault.lifecycle() != 1) {
            revert InvalidLifecycle();
        }
        designedLossBreachTripped = false;
        emit DesignedLossBreachCleared(msg.sender);
    }

    function canFinalizeShutdown() external view returns (bool) {
        return activePositionCount == 0 && outstandingPrincipal == 0;
    }

    /// @notice Vault hook snapshots the exact strategy bucket before its first mutation in each UTC day.
    function checkpointCapitalBeforeChange(uint256 capitalBefore) external {
        if (msg.sender != address(vault)) revert Unauthorized();
        uint256 period = block.timestamp / 1 days;
        if (period != dailyPeriod) {
            dailyPeriod = period;
            dailyStartStrategyCapital = capitalBefore;
            dailyRealizedLoss = 0;
        }
    }

    function _readEquity() private view returns (uint256 equity, uint256 updatedAt) {
        if (equityOracle == address(0) || maxEquityAge == 0) revert DependencyUnavailable();
        (equity, updatedAt) = ICompdEquityOracle(equityOracle).strategyEquity();
        if (equity == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxEquityAge) {
            revert StaleEquity(updatedAt);
        }
    }

    function _rollDailyPeriod() private {
        uint256 period = block.timestamp / 1 days;
        if (period != dailyPeriod) {
            dailyPeriod = period;
            dailyStartStrategyCapital = vault.strategyCapital();
            dailyRealizedLoss = 0;
        }
        // If the protocol began a UTC period with zero Strategy Capital, the first
        // positive-capital exposure establishes that day's denominator.
        if (dailyStartStrategyCapital == 0 && vault.strategyCapital() != 0) {
            dailyStartStrategyCapital = vault.strategyCapital();
        }
    }

    function _tryRefreshAfterSettlement() private {
        // Settlement is risk-reducing and must not be blocked by a temporarily stale oracle.
        if (equityOracle == address(0) || maxEquityAge == 0) return;
        (bool ok, bytes memory data) = equityOracle.staticcall(
            abi.encodeCall(ICompdEquityOracle.strategyEquity, ())
        );
        if (!ok || data.length < 64) return;
        (uint256 equity, uint256 updatedAt) = abi.decode(data, (uint256, uint256));
        if (equity == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxEquityAge) return;
        if (equity > equityHighWaterMark) equityHighWaterMark = equity;
        uint256 drawdown = equityHighWaterMark > equity
            ? (equityHighWaterMark - equity) * BPS / equityHighWaterMark
            : 0;
        if (drawdown >= MAX_DRAWDOWN_BPS && !drawdownTripped) {
            drawdownTripped = true;
            emit DrawdownCircuitBreakerTripped(equityHighWaterMark, equity, drawdown);
        }
    }

    function _quoteBalance(address quote) private view returns (uint256) {
        return quote == address(0) ? address(this).balance : IERC20(quote).balanceOf(address(this));
    }

    function _requireConfigurable() private view {
        if (vault.lifecycle() != 1 || activePositionCount != 0) revert InvalidLifecycle();
    }
}
