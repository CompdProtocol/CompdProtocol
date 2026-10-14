// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VaultBaseV3} from "../../src/flap/VaultBaseV3.sol";
import {VaultUISchema, VaultMethodSchema} from "../../src/flap/IVaultSchemasV1.sol";
import {ICompdProductionVaultReceiver} from "../production/ICompdProductionInterfaces.sol";

/// @notice Minimal Flap V3 ingress receiver. It has no treasury roles and no arbitrary transfer path.
contract CompdThinFlapReceiver is VaultBaseV3, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant COMPD_TOKEN = 0x7b7Af51136574c91A12988989c0a08E98aE97777;

    address public immutable taxToken;
    address public immutable productionVault;
    address public immutable factory;
    address private immutable _quoteToken;
    /// @notice Revenue received from the Flap TaxProcessor but not yet delivered to the Vault.
    uint256 public accountedQuote;
    /// @notice Direct/unrecognized quote assets; never classified as Flap revenue.
    uint256 public unrecognizedSurplus;

    error InvalidConfiguration();
    error UnauthorizedSelfCall();
    error UnsupportedQuote();
    error BalanceInvariant();
    error InvalidLifecycle();
    error NoSurplus();

    event RevenueObserved(address indexed quoteToken, uint256 amount, uint256 receiverBalance);
    event RevenueForwarded(address indexed quoteToken, uint256 amount);
    event RevenueForwardDeferred(address indexed quoteToken, uint256 amount);
    event SurplusQuarantined(address indexed quoteToken, uint256 amount, uint256 totalQuarantined);
    event SurplusSweptToVault(address indexed quoteToken, uint256 amount);

    constructor(address taxToken_, address quoteToken_, address productionVault_) {
        if (taxToken_ != COMPD_TOKEN || productionVault_.code.length == 0) revert InvalidConfiguration();
        if (ICompdProductionVaultReceiver(productionVault_).quoteToken() != quoteToken_) revert InvalidConfiguration();
        taxToken = taxToken_;
        productionVault = productionVault_;
        factory = msg.sender;
        _quoteToken = quoteToken_;
    }

    receive() external payable nonReentrant {
        if (_isFlapTaxProcessor(msg.sender)) _syncAndTryForward();
        else _quarantineUnrecognizedBalance();
    }

    /// @notice Retry only revenue previously recognized from Flap's TaxProcessor.
    function forward() external nonReentrant returns (bool forwarded) {
        if (accountedQuote == 0) return false;
        return _forwardPending();
    }

    /// @notice After permanent termination, move recorded direct surplus to the fixed Vault for final recovery.
    function sweepQuarantinedSurplusAfterTermination() external nonReentrant returns (uint256 amount) {
        if (ICompdProductionVaultReceiver(productionVault).lifecycle() != 3) revert InvalidLifecycle();
        amount = unrecognizedSurplus;
        if (amount == 0) revert NoSurplus();
        uint256 balance = _quoteBalance();
        if (balance < accountedQuote + amount) revert BalanceInvariant();
        unrecognizedSurplus = 0;
        if (_quoteToken == address(0)) {
            (bool ok,) = payable(productionVault).call{value: amount}("");
            if (!ok) revert BalanceInvariant();
        } else {
            uint256 vaultBefore = IERC20(_quoteToken).balanceOf(productionVault);
            uint256 receiverBefore = IERC20(_quoteToken).balanceOf(address(this));
            IERC20(_quoteToken).safeTransfer(productionVault, amount);
            uint256 vaultAfter = IERC20(_quoteToken).balanceOf(productionVault);
            uint256 receiverAfter = IERC20(_quoteToken).balanceOf(address(this));
            if (
                vaultAfter < vaultBefore || vaultAfter - vaultBefore != amount || receiverAfter > receiverBefore
                    || receiverBefore - receiverAfter != amount
            ) revert BalanceInvariant();
        }
        emit SurplusSweptToVault(_quoteToken, amount);
    }

    /// @notice Move accidental non-quote assets to the fixed Vault after termination.
    /// @dev The Vault has no arbitrary recipient path and its own recovery destination is fixed.
    function sweepOtherAssetAfterTermination(address asset) external nonReentrant returns (uint256 amount) {
        if (ICompdProductionVaultReceiver(productionVault).lifecycle() != 3) revert InvalidLifecycle();
        if (asset == _quoteToken) revert NoSurplus();

        amount = asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
        if (amount == 0) revert NoSurplus();

        if (asset == address(0)) {
            (bool ok,) = payable(productionVault).call{value: amount}("");
            if (!ok) revert BalanceInvariant();
        } else {
            uint256 vaultBefore = IERC20(asset).balanceOf(productionVault);
            uint256 receiverBefore = IERC20(asset).balanceOf(address(this));
            IERC20(asset).safeTransfer(productionVault, amount);
            uint256 vaultAfter = IERC20(asset).balanceOf(productionVault);
            uint256 receiverAfter = IERC20(asset).balanceOf(address(this));
            if (
                vaultAfter < vaultBefore || vaultAfter - vaultBefore != amount || receiverAfter > receiverBefore
                    || receiverBefore - receiverAfter != amount
            ) revert BalanceInvariant();
        }
        emit SurplusSweptToVault(asset, amount);
    }

    /// @dev Only this contract's guarded self-call can perform the fixed-destination forward.
    function forwardPending(uint256 amount) external {
        if (msg.sender != address(this)) revert UnauthorizedSelfCall();
        if (amount == 0) revert BalanceInvariant();
        if (_quoteToken == address(0)) {
            ICompdProductionVaultReceiver(productionVault).registerFlapRevenue{value: amount}(amount);
        } else {
            uint256 beforeBalance = IERC20(_quoteToken).balanceOf(productionVault);
            uint256 receiverBefore = IERC20(_quoteToken).balanceOf(address(this));
            IERC20(_quoteToken).safeTransfer(productionVault, amount);
            uint256 afterBalance = IERC20(_quoteToken).balanceOf(productionVault);
            uint256 receiverAfter = IERC20(_quoteToken).balanceOf(address(this));
            if (
                afterBalance < beforeBalance || afterBalance - beforeBalance != amount || receiverAfter > receiverBefore
                    || receiverBefore - receiverAfter != amount
            ) revert BalanceInvariant();
            ICompdProductionVaultReceiver(productionVault).registerFlapRevenue(amount);
        }
    }

    function vaultQuoteToken() public view override returns (address) {
        return _quoteToken;
    }

    function description() public view override returns (string memory) {
        return string.concat("COMPD Flap V3 receiver; pending quote proceeds: ", _decimalString(accountedQuote));
    }

    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "COMPD Thin Flap Receiver";
        schema.description = "Forwards Flap tax revenue to the fixed COMPD Production Vault.";
        schema.methods = new VaultMethodSchema[](0);
    }

    function _syncAndTryForward() private returns (bool forwarded) {
        uint256 balance = _quoteBalance();
        uint256 recognized = accountedQuote + unrecognizedSurplus;
        if (balance < recognized) revert BalanceInvariant();
        uint256 newlyObserved = balance - recognized;
        if (newlyObserved != 0) {
            accountedQuote += newlyObserved;
            emit RevenueObserved(_quoteToken, newlyObserved, balance);
        }
        return _forwardPending();
    }

    function _forwardPending() private returns (bool forwarded) {
        uint256 pendingRevenue = accountedQuote;
        if (pendingRevenue == 0) return false;
        if (_quoteBalance() < pendingRevenue + unrecognizedSurplus) revert BalanceInvariant();

        // The self-call isolates a temporarily failing downstream Vault. If it reverts,
        // only the already recognized Flap amount remains pending for retry.
        accountedQuote = 0;
        (bool ok,) = address(this).call(abi.encodeCall(this.forwardPending, (pendingRevenue)));
        if (ok) {
            emit RevenueForwarded(_quoteToken, pendingRevenue);
            return true;
        }
        accountedQuote = pendingRevenue;
        emit RevenueForwardDeferred(_quoteToken, pendingRevenue);
        return false;
    }

    function _quarantineUnrecognizedBalance() private {
        uint256 balance = _quoteBalance();
        uint256 recognized = accountedQuote + unrecognizedSurplus;
        if (balance < recognized) revert BalanceInvariant();
        uint256 amount = balance - recognized;
        if (amount != 0) {
            unrecognizedSurplus += amount;
            emit SurplusQuarantined(_quoteToken, amount, unrecognizedSurplus);
        }
    }

    function _isFlapTaxProcessor(address caller) private view returns (bool) {
        (bool ok, bytes memory data) = taxToken.staticcall(
            abi.encodeWithSignature("taxProcessor()")
        );
        return ok && data.length >= 32 && abi.decode(data, (address)) == caller;
    }

    function _quoteBalance() private view returns (uint256) {
        return _quoteToken == address(0) ? address(this).balance : IERC20(_quoteToken).balanceOf(address(this));
    }

    function _decimalString(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 digits;
        uint256 cursor = value;
        while (cursor != 0) {
            digits++;
            cursor /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(buffer);
    }
}
