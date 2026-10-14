// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IQuoteGuard, IPancakeV2RouterLike} from "../IQuoteGuard.sol";
import {
    ICompdProductionVaultView,
    ICompdBuybackReserveObserver,
    ICompdBurnSink
} from "./ICompdProductionInterfaces.sol";

/// @notice ACTIVE-only bounded COMPD buyback. It never custody-controls the reserve.
/// @dev Quote guards, route, intermediate allowlist, freshness and burn adapter are unset until reviewed.
contract CompdBuybackExecutor is ReentrancyGuard, ICompdBuybackReserveObserver {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MINIMUM_TRIGGER_BNB = 0.25 ether;
    uint256 public constant HARD_CAP_BNB = 0.50 ether;
    uint256 public constant CURRENT_RESERVE_SIZE_BPS = 2_000;
    uint256 public constant UTC_PERIOD_CAP_BPS = 4_000;
    uint256 public constant MAX_SLIPPAGE_BPS = 300;
    uint256 public constant MAX_QUOTE_DEVIATION_BPS = 300;
    uint256 public constant COOLDOWN = 6 hours;

    address public constant COMPD_TOKEN = 0x7b7Af51136574c91A12988989c0a08E98aE97777;
    address public constant AUTOMATION_EXECUTOR = 0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3;
    address public constant PROTOCOL_BUYBACK_ADMIN = 0x29BB16dB8e9f2371255BA75aF83aECaFB2CC00BA;

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidLifecycle();
    error SnapshotUnavailable();
    error ReserveBelowTrigger();
    error CooldownActive();
    error DailyCapExceeded();
    error QuoteRejected();
    error SlippageRejected();
    error SwapInvariant();
    error BurnNotVerified();

    ICompdProductionVaultView public immutable vault;
    address public router;
    address public wrappedNative;
    address public primaryQuoteGuard;
    address public referenceQuoteGuard;
    address public burnSink;
    uint64 public maxQuoteAge;
    uint64 public deadlineWindow;
    address[] private _buybackPath;
    address[] private _quoteToBnbPath;
    mapping(address => bool) public allowedIntermediateToken;

    uint256 public periodIndex;
    uint256 public periodStartReserveBnb;
    uint256 public spentThisPeriodBnb;
    uint256 public lastExecutionAt;
    bool public periodInitialized;
    bool public periodSnapshotValid;
    bool public routeConfigured;
    uint256 public cumulativeQuoteSpent;
    uint256 public cumulativeCompdBurned;

    event IntermediateTokenUpdated(address indexed token, bool allowed);
    event RouteConfigured(address indexed router, address indexed burnSink, address quoteGuard, address referenceGuard);
    event ReservePeriodSnapshotted(uint256 indexed period, uint256 reserveQuote, uint256 reserveBnbEquivalent, bool valid);
    event BuybackExecuted(uint256 quoteAmount, uint256 expectedOutMin, uint256 compdBurned, uint256 bnbEquivalentSpent, uint256 periodSpentBnb);

    constructor(address vault_) {
        if (vault_.code.length == 0) revert InvalidConfiguration();
        vault = ICompdProductionVaultView(vault_);
    }

    receive() external payable {
        if (msg.sender != address(vault) && msg.sender != router) revert Unauthorized();
    }

    function setAllowedIntermediateToken(address token, bool allowed) external {
        if (msg.sender != PROTOCOL_BUYBACK_ADMIN) revert Unauthorized();
        _requirePausedAndNoRouteExecution();
        if (token == address(0) || token == COMPD_TOKEN || token == vault.quoteToken()) revert InvalidConfiguration();
        allowedIntermediateToken[token] = allowed;
        routeConfigured = false;
        periodSnapshotValid = false;
        emit IntermediateTokenUpdated(token, allowed);
    }

    function configureRoute(
        address router_,
        address wrappedNative_,
        address primaryQuoteGuard_,
        address referenceQuoteGuard_,
        address burnSink_,
        uint64 maxQuoteAge_,
        uint64 deadlineWindow_,
        address[] calldata buybackPath_,
        address[] calldata quoteToBnbPath_
    ) external {
        if (msg.sender != PROTOCOL_BUYBACK_ADMIN) revert Unauthorized();
        _requirePausedAndNoRouteExecution();
        if (
            router_.code.length == 0 || wrappedNative_.code.length == 0 || primaryQuoteGuard_.code.length == 0
                || referenceQuoteGuard_.code.length == 0 || primaryQuoteGuard_ == referenceQuoteGuard_
                || burnSink_.code.length == 0 || maxQuoteAge_ == 0
                || deadlineWindow_ == 0 || buybackPath_.length < 2 || buybackPath_.length > 5
        ) revert InvalidConfiguration();
        address quote = vault.quoteToken();
        address expectedInput = quote == address(0) ? wrappedNative_ : quote;
        if (buybackPath_[0] != expectedInput || buybackPath_[buybackPath_.length - 1] != COMPD_TOKEN) {
            revert InvalidConfiguration();
        }
        _checkAllowedPath(buybackPath_);
        if (quote == address(0)) {
            if (quoteToBnbPath_.length != 0) revert InvalidConfiguration();
        } else {
            if (
                quoteToBnbPath_.length < 2 || quoteToBnbPath_.length > 5 || quoteToBnbPath_[0] != quote
                    || quoteToBnbPath_[quoteToBnbPath_.length - 1] != wrappedNative_
            ) revert InvalidConfiguration();
            _checkAllowedPath(quoteToBnbPath_);
        }

        router = router_;
        wrappedNative = wrappedNative_;
        primaryQuoteGuard = primaryQuoteGuard_;
        referenceQuoteGuard = referenceQuoteGuard_;
        burnSink = burnSink_;
        maxQuoteAge = maxQuoteAge_;
        deadlineWindow = deadlineWindow_;
        delete _buybackPath;
        delete _quoteToBnbPath;
        for (uint256 i; i < buybackPath_.length; ++i) _buybackPath.push(buybackPath_[i]);
        for (uint256 i; i < quoteToBnbPath_.length; ++i) _quoteToBnbPath.push(quoteToBnbPath_[i]);
        routeConfigured = true;
        // Never reuse an accounting-period snapshot obtained under a different route or quote source.
        periodInitialized = true;
        periodIndex = block.timestamp / 1 days;
        periodSnapshotValid = false;
        emit RouteConfigured(router_, burnSink_, primaryQuoteGuard_, referenceQuoteGuard_);
    }

    /// @notice The Vault invokes this before every Buyback Reserve mutation.
    function checkpointReserveBeforeChange(uint256 reserveBefore) external override {
        if (msg.sender != address(vault)) revert Unauthorized();
        _capturePeriodStart(reserveBefore);
    }

    /// @notice Triggered only by the approved automation EOA; all limits are enforced here.
    function executeBuyback() external nonReentrant returns (uint256 amountIn, uint256 compdBurned) {
        if (msg.sender != AUTOMATION_EXECUTOR) revert Unauthorized();
        if (vault.lifecycle() != 0) revert InvalidLifecycle();
        if (!routeConfigured || router == address(0) || burnSink == address(0)) revert InvalidConfiguration();
        if (lastExecutionAt != 0 && block.timestamp < lastExecutionAt + COOLDOWN) revert CooldownActive();

        uint256 reserve = vault.buybackReserve();
        _ensureCurrentPeriodSnapshot(reserve);
        if (!periodSnapshotValid) revert SnapshotUnavailable();
        (uint256 reserveBnbLow, uint256 reserveBnbHigh) = _bnbEquivalent(reserve);
        if (reserveBnbLow < MINIMUM_TRIGGER_BNB || reserveBnbHigh == 0) revert ReserveBelowTrigger();

        amountIn = reserve * CURRENT_RESERVE_SIZE_BPS / BPS;
        uint256 hardCapQuote = Math.mulDiv(reserve, HARD_CAP_BNB, reserveBnbHigh);
        uint256 periodCapBnb = periodStartReserveBnb * UTC_PERIOD_CAP_BPS / BPS;
        if (spentThisPeriodBnb >= periodCapBnb) revert DailyCapExceeded();
        uint256 remainingBnb = periodCapBnb - spentThisPeriodBnb;
        uint256 dailyCapQuote = Math.mulDiv(reserve, remainingBnb, reserveBnbHigh);
        if (hardCapQuote < amountIn) amountIn = hardCapQuote;
        if (dailyCapQuote < amountIn) amountIn = dailyCapQuote;
        if (amountIn == 0) revert DailyCapExceeded();

        (uint256 amountBnbLow, uint256 amountBnbHigh) = _bnbEquivalent(amountIn);
        if (amountBnbHigh > HARD_CAP_BNB || spentThisPeriodBnb + amountBnbHigh > periodCapBnb) {
            revert DailyCapExceeded();
        }
        (uint256 quoteA, uint256 quoteB) = _validatedBuybackQuote(amountIn);
        uint256 conservativeExpected = quoteA < quoteB ? quoteA : quoteB;
        uint256 amountOutMin = Math.mulDiv(
            conservativeExpected, BPS - MAX_SLIPPAGE_BPS, BPS, Math.Rounding.Ceil
        );
        if (amountOutMin == 0) revert QuoteRejected();

        address quote = vault.quoteToken();
        // Snapshot before the Vault releases the reserve. After the router consumes the
        // exact input, this executor must return to its original quote/native balance.
        uint256 quoteBalanceBefore = _quoteBalance(quote);

        lastExecutionAt = block.timestamp;
        spentThisPeriodBnb += amountBnbHigh;
        cumulativeQuoteSpent += amountIn;
        vault.releaseBuybackReserve(amountIn);

        IERC20 compd = IERC20(COMPD_TOKEN);
        uint256 compdBefore = compd.balanceOf(address(this));
        if (quote == address(0)) {
            IPancakeV2RouterLike(router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: amountIn}(
                amountOutMin, _buybackPath, address(this), block.timestamp + deadlineWindow
            );
        } else {
            IERC20(quote).forceApprove(router, amountIn);
            IPancakeV2RouterLike(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amountIn, amountOutMin, _buybackPath, address(this), block.timestamp + deadlineWindow
            );
            IERC20(quote).forceApprove(router, 0);
        }
        if (_quoteBalance(quote) != quoteBalanceBefore) revert SwapInvariant();

        uint256 compdAfter = compd.balanceOf(address(this));
        if (compdAfter < compdBefore) revert SwapInvariant();
        uint256 received = compdAfter - compdBefore;
        if (received == 0) revert SwapInvariant();

        uint256 supplyBefore = IERC20Metadata(COMPD_TOKEN).totalSupply();
        uint256 heldBeforeBurn = compd.balanceOf(address(this));
        compd.forceApprove(burnSink, received);
        ICompdBurnSink(burnSink).receiveBuyback(received);
        compd.forceApprove(burnSink, 0);
        uint256 heldAfterBurn = compd.balanceOf(address(this));
        uint256 supplyAfter = IERC20Metadata(COMPD_TOKEN).totalSupply();
        if (
            heldBeforeBurn - heldAfterBurn != received || supplyBefore < supplyAfter
                || supplyBefore - supplyAfter != received
        ) revert BurnNotVerified();

        compdBurned = received;
        cumulativeCompdBurned += received;
        emit BuybackExecuted(amountIn, amountOutMin, received, amountBnbLow, spentThisPeriodBnb);
    }

    function buybackPath() external view returns (address[] memory) {
        return _buybackPath;
    }

    function quoteToBnbPath() external view returns (address[] memory) {
        return _quoteToBnbPath;
    }

    function _capturePeriodStart(uint256 reserveBefore) private {
        uint256 currentPeriod = block.timestamp / 1 days;
        if (periodInitialized && currentPeriod == periodIndex) return;
        periodIndex = currentPeriod;
        periodInitialized = true;
        periodSnapshotValid = false;
        periodStartReserveBnb = 0;
        spentThisPeriodBnb = 0;
        if (routeConfigured) {
            try this.quoteBnbEquivalent(reserveBefore) returns (uint256 low, uint256 high) {
                low; // Both independent sources were checked; use the conservative lower value as the daily budget.
                periodStartReserveBnb = low;
                periodSnapshotValid = high != 0;
            } catch { }
        } else if (vault.quoteToken() == address(0)) {
            periodStartReserveBnb = reserveBefore;
            periodSnapshotValid = true;
        }
        emit ReservePeriodSnapshotted(currentPeriod, reserveBefore, periodStartReserveBnb, periodSnapshotValid);
    }

    function _ensureCurrentPeriodSnapshot(uint256 reserve) private {
        uint256 currentPeriod = block.timestamp / 1 days;
        if (!periodInitialized || currentPeriod != periodIndex) {
            _capturePeriodStart(reserve);
        }
    }

    /// @dev Self-only quote endpoint lets the reserve hook fail closed without breaking revenue accounting.
    function quoteBnbEquivalent(uint256 amount) external view returns (uint256 low, uint256 high) {
        if (msg.sender != address(this)) revert Unauthorized();
        return _bnbEquivalent(amount);
    }

    function _bnbEquivalent(uint256 amount) private view returns (uint256 low, uint256 high) {
        if (vault.quoteToken() == address(0)) return (amount, amount);
        if (primaryQuoteGuard == address(0) || referenceQuoteGuard == address(0) || _quoteToBnbPath.length < 2) {
            revert InvalidConfiguration();
        }
        (uint256 first, uint256 firstAt) = IQuoteGuard(primaryQuoteGuard).quote(_quoteToBnbPath, amount);
        (uint256 second, uint256 secondAt) = IQuoteGuard(referenceQuoteGuard).quote(_quoteToBnbPath, amount);
        _requireFresh(firstAt);
        _requireFresh(secondAt);
        _requireQuoteAgreement(first, second);
        low = first < second ? first : second;
        high = first > second ? first : second;
    }

    function _validatedBuybackQuote(uint256 amountIn) private view returns (uint256 first, uint256 second) {
        uint256 firstAt;
        uint256 secondAt;
        (first, firstAt) = IQuoteGuard(primaryQuoteGuard).quote(_buybackPath, amountIn);
        (second, secondAt) = IQuoteGuard(referenceQuoteGuard).quote(_buybackPath, amountIn);
        _requireFresh(firstAt);
        _requireFresh(secondAt);
        _requireQuoteAgreement(first, second);
        if (first == 0 || second == 0) revert QuoteRejected();
    }

    function _requireFresh(uint256 updatedAt) private view {
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxQuoteAge) revert QuoteRejected();
    }

    function _requireQuoteAgreement(uint256 first, uint256 second) private pure {
        if (first == 0 || second == 0) revert QuoteRejected();
        uint256 low = first < second ? first : second;
        uint256 high = first > second ? first : second;
        // Round up so a fractional basis point above the fixed limit cannot pass
        // because the integer division rounded it down to the threshold.
        if (Math.mulDiv(high - low, BPS, low, Math.Rounding.Ceil) > MAX_QUOTE_DEVIATION_BPS) {
            revert QuoteRejected();
        }
    }

    function _checkAllowedPath(address[] calldata path) private view {
        for (uint256 i = 1; i + 1 < path.length; ++i) {
            if (!allowedIntermediateToken[path[i]]) revert InvalidConfiguration();
        }
    }

    function _requirePausedAndNoRouteExecution() private view {
        if (vault.lifecycle() != 1) revert InvalidLifecycle(); // PAUSED only.
    }

    function _quoteBalance(address quote) private view returns (uint256) {
        return quote == address(0) ? address(this).balance : IERC20(quote).balanceOf(address(this));
    }

}
