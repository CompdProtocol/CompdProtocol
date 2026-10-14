// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

/// @title IFlapVaultEx
/// @author The Flap Team
/// @notice Interface for vaultEX — The ultimate asynchronous DEX for vaults.
///
/// @dev  ── OVERVIEW ──────────────────────────────────────────────────────────────
///
/// FlapVaultEx is an asynchronous, intent-based settlement layer that lets a consumer
/// (typically a vault) swap any token for any other token without knowing anything about
/// DEX routing. The consumer submits an *intent* — "sell this much of `inputToken`, I want
/// `outputToken`" — and Flap's off-chain executor sources the best route across DEX
/// aggregators and settles it back on-chain.
///
/// It bridges on-chain custody with off-chain routing:
///   • The contract custodies the input and records a `PENDING` request.
///   • The off-chain executor finds the best route and calls `fulfillSwap` with the calldata.
///   • The contract measures the real output by balance delta, enforces an on-chain minimum,
///     takes the fee, and delivers the result straight back to the consumer via a callback.
///
/// There are no signatures and no routing logic in the consumer. Routes are bound by
/// on-chain whitelists, the output is verified by balance delta, and the executor can only
/// settle — never redirect — the funds.
///
///
/// ── SUPPORTED TOKENS ────────────────────────────────────────────────────────────
///
/// Standard ERC-20 tokens only. Fee-on-transfer (FOT) and rebasing tokens are NOT
/// supported: the contract verifies exact balance deltas on both sides, so a FOT token
/// makes `requestSwap` / settlement revert. The protocol may also block (denylist)
/// unsupported tokens, in which case any request using them reverts.
///
///
/// ── WORKFLOW ───────────────────────────────────────────────────────────────────
///
/// 1. The consumer calls `requestSwap` with `{inputToken, outputToken, inputAmount}`,
///    approving the input first. The input is custodied and a `PENDING` request is recorded;
///    `FlapVaultExRequested` is emitted.
/// 2. The off-chain executor indexes the event, quotes across DEX aggregators, and picks the
///    best route.
/// 3. The executor calls `fulfillSwap(requestId, target, allowanceTarget, minOutputAmount, data)`.
///    The contract approves exactly the input amount, performs the router call, resets the
///    approval, and measures the received output by balance delta.
/// 4. If the output is at least `minOutputAmount`, the fee is taken and the net output is
///    delivered to the consumer, which is then notified via `onFlapVaultExSettled`. If
///    anything fails, the whole call reverts.
///
///
/// ── CONSUMER IMPLEMENTATION GUIDE ──────────────────────────────────────────────
///
/// Your contract MUST implement `IFlapVaultExConsumer.onFlapVaultExSettled`. The callback is
/// invoked for both outcomes — branch on `status`:
///
///   • `status == 2` (FULFILLED): the output token was delivered, net of the fee.
///   • `status == 3` (REFUNDED):  the input token was returned, net of the input-side fee.
///
/// In both cases the funds are ALREADY in your contract when the callback runs. Validate
/// `msg.sender == flapVaultEx`, keep the callback cheap, and remember it is atomic with
/// settlement: if it reverts, the whole `fulfillSwap` reverts and nothing settles.
///
/// `requestSwap` requires `msg.sender` to be a real contract (plain EOAs and EIP-7702
/// delegated accounts are rejected), precisely so the callback can be delivered.
///
///   ```solidity
///   import {IFlapVaultEx, IFlapVaultExConsumer} from "src/flap/IFlapVaultEx.sol";
///
///   contract MyVault is IFlapVaultExConsumer {
///       IFlapVaultEx public immutable flapVaultEx;
///
///       function onFlapVaultExSettled(uint256 requestId, uint8 status, address token, uint256 amount)
///           external
///           override
///       {
///           require(msg.sender == address(flapVaultEx), "Only FlapVaultEx");
///           if (status == 2) {
///               // output token delivered — update accounting
///           } else if (status == 3) {
///               // input token refunded — handle the failure path
///           } else {
///               revert("unexpected status");
///           }
///       }
///   }
///   ```
///
///
/// ── FEES ───────────────────────────────────────────────────────────────────────
///
/// A single global `feeBps` is charged on the quote-token side (input or output, whichever is
/// a configured quote token; otherwise the admin-configured fallback side). The rate is
/// snapshotted at `requestSwap`, so settlement always uses the rate the request was created
/// with. `getRequest().swapInputAmount` (and the `FlapVaultExRequested` event) already expose
/// the net input actually swapped — quote on that and you never compute the fee yourself.
interface IFlapVaultEx {
    // ── Enums ────────────────────────────────────────────────────────────────

    /// @notice Lifecycle of a swap request.
    enum RequestStatus {
        NONE, // 0 — no such request
        PENDING, // 1 — input custodied; awaiting settlement or a refund
        FULFILLED, // 2 — swapped; output delivered to the consumer
        REFUNDED, // 3 — input returned to the consumer (fee taken from the input)
        FAILED // 4 — a failed batch item whose automatic refund could not be delivered
    }

    // ── Structs ──────────────────────────────────────────────────────────────

    /// @notice Parameters for swapping an exact input amount for an output token.
    /// @param inputToken  ERC-20 being sold.
    /// @param outputToken ERC-20 to buy.
    /// @param inputAmount Amount of `inputToken` to sell.
    struct ExactInputParams {
        address inputToken;
        address outputToken;
        uint256 inputAmount;
    }

    /// @notice One settlement entry for {batchFulfillSwap}.
    struct FulfillItem {
        uint256 requestId;
        address target;
        address allowanceTarget;
        uint256 minOutputAmount;
        bytes data;
    }

    /// @notice Read-only view of a request for explorers and integrations.
    /// @param swapInputAmount Net input actually swapped (after any input-side fee); quote on this.
    /// @param feeInInput Whether the fee is taken from the input (else the output).
    /// @param feeBps Fee rate snapshotted at request time (settlement uses this).
    /// @param createdAt Block timestamp the request was created at (informational; no expiry).
    struct SwapRequestView {
        uint256 requestId;
        address consumer;
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 swapInputAmount;
        bool feeInInput;
        uint64 feeBps;
        uint64 createdAt;
        RequestStatus status;
    }

    // ── Events ───────────────────────────────────────────────────────────────

    /// @notice Emitted when a new request is created.
    event FlapVaultExRequested(
        uint256 indexed requestId,
        address indexed consumer,
        address inputToken,
        uint256 inputAmount,
        address outputToken,
        uint256 swapInputAmount,
        bool feeInInput,
        uint64 feeBps,
        uint64 createdAt
    );

    /// @notice Emitted when a request is settled; `netOutputAmount` is what the consumer received.
    event FlapVaultExFulfilled(
        uint256 indexed requestId,
        address indexed consumer,
        address outputToken,
        uint256 netOutputAmount,
        uint256 feeAmount
    );

    /// @notice Emitted when a request is refunded; `refundAmount` is net of the input-side fee.
    event FlapVaultExRefunded(
        uint256 indexed requestId, address indexed consumer, address inputToken, uint256 refundAmount, uint256 feeAmount
    );

    /// @notice Diagnostic: the router did not consume the full `swapInput`; the leftover stays
    ///         custodied (it is not refunded automatically).
    event FlapVaultExUnspentInput(
        uint256 indexed requestId,
        address indexed consumer,
        address inputToken,
        uint256 swapInput,
        uint256 consumed,
        uint256 leftover
    );

    event FlapVaultExBatchItemFailed(uint256 indexed requestId, bytes reason);
    event FlapVaultExBatchItemRefunded(uint256 indexed requestId);
    event FlapVaultExBatchRefundFailed(uint256 indexed requestId, bytes reason);
    event FlapVaultExRequestFailed(uint256 indexed requestId, bytes reason);

    // ── Errors ───────────────────────────────────────────────────────────────

    error FlapVaultExZeroInputAmount();
    error FlapVaultExZeroMinOutputAmount();
    error FlapVaultExIdenticalTokens();
    error FlapVaultExConsumerNotContract(address consumer);
    error FlapVaultExEoa7702NotAllowed(address consumer);
    error FlapVaultExCallerBlocked(address caller);
    error FlapVaultExTokenBlocked(address token);
    error FlapVaultExNotPending(uint256 requestId);
    error FlapVaultExRouterNotAllowed(address router);
    error FlapVaultExAllowanceTargetNotAllowed(address allowanceTarget);
    error FlapVaultExSwapCallFailed(bytes reason);
    error FlapVaultExFeeOnTransferNotSupported(address token, uint256 expected, uint256 received);
    error FlapVaultExOutputFeeOnTransfer(address token, uint256 expected, uint256 received);
    error FlapVaultExInsufficientOutputAmount(uint256 outputAmount, uint256 minOutputAmount);
    error FlapVaultExConsumerCallbackFailed(uint256 requestId, bytes reason);

    // ── Consumer-facing ──────────────────────────────────────────────────────

    /// @notice Create a swap request, transferring `params.inputAmount` of `params.inputToken`
    ///         into this contract. The caller must approve this contract for `inputAmount`.
    ///         Emits {FlapVaultExRequested}.
    /// @dev Fee-on-transfer input tokens are rejected (the received balance delta must equal
    ///      `inputAmount`). Blocklisted callers and blocklisted input/output tokens are rejected.
    ///      `msg.sender` must be a real contract (not an EOA, not an EIP-7702 delegated account)
    ///      so the mandatory `onFlapVaultExSettled` callback can be delivered.
    /// @return requestId The id assigned to the request.
    function requestSwap(ExactInputParams calldata params) external returns (uint256 requestId);

    // ── Executor (`FULFILLER_ROLE`) ──────────────────────────────────────────

    /// @notice Settle a pending request using router calldata. Restricted to `FULFILLER_ROLE`.
    ///         Verifies the whitelists, executes the swap, requires the gross swap output to be
    ///         >= `minOutputAmount`, pays the fee, delivers the net output to the consumer and
    ///         invokes the consumer callback; the whole call reverts if the callback fails.
    /// @param minOutputAmount Floor on the GROSS output (before any output-side fee).
    /// @return netOutputAmount Amount of `outputToken` delivered to the consumer (after fees).
    function fulfillSwap(
        uint256 requestId,
        address target,
        address allowanceTarget,
        uint256 minOutputAmount,
        bytes calldata data
    ) external returns (uint256 netOutputAmount);

    /// @notice Settle many requests in one transaction. Each entry is settled independently; a
    ///         failure does not revert the rest and the failed request is auto-refunded in the
    ///         same transaction. Restricted to `FULFILLER_ROLE`.
    /// @return successCount Number of entries that settled successfully.
    function batchFulfillSwap(FulfillItem[] calldata items) external returns (uint256 successCount);

    /// @notice Refund a request, returning the custodied input to the consumer. Restricted to
    ///         `FULFILLER_ROLE`. The snapshotted `feeBps` is taken from the input side.
    function refundSwap(uint256 requestId) external;

    // ── Views ────────────────────────────────────────────────────────────────

    /// @notice Read a request. `swapInputAmount` is the net input the executor should quote on.
    function getRequest(uint256 requestId) external view returns (SwapRequestView memory view_);

    /// @notice Get a paginated list of ALL requests, newest first (for UI pagination).
    /// @param offset  Number of requests to skip from the newest (0 = start from newest).
    /// @param limit   Maximum number of requests to return.
    /// @return requests The page of request structs, newest first.
    /// @return total    Total number of requests ever created.
    function getRequestsPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (SwapRequestView[] memory requests, uint256 total);

    /// @notice Get a paginated list of requests for a specific requester, newest first.
    /// @param requester The consumer address whose requests to query.
    /// @param offset    Number of requests to skip from the newest (0 = start from newest).
    /// @param limit     Maximum number of requests to return.
    /// @return requests The page of request structs for the requester, newest first.
    /// @return total    Total number of requests ever made by this requester.
    function getRequestsByRequesterPaginated(address requester, uint256 offset, uint256 limit)
        external
        view
        returns (SwapRequestView[] memory requests, uint256 total);

    /// @notice The last request id created (0 when there are none) — i.e. the scan upper bound.
    function nextRequestId() external view returns (uint256);

    /// @notice The current fee rate and receiver.
    function feeConfig() external view returns (uint256 feeBps, address feeReceiver);

    /// @notice Maximum gas forwarded to `onFlapVaultExSettled`.
    function maxCallbackGas() external view returns (uint256);

    /// @notice Whether `token` is a configured quote token.
    function isQuoteToken(address token) external view returns (bool);

    /// @notice Whether `token` is blocked (requests using it revert).
    function isTokenBlocked(address token) external view returns (bool);

    /// @notice Whether the router allowlist is currently enforced.
    function routerWhitelistEnabled() external view returns (bool);
}

/// @title IFlapVaultExConsumer
/// @notice Interface a contract consumer MUST implement to receive settlements. Funds are
///         transferred before the callback fires, and the two are atomic: if the callback
///         reverts, the whole settlement reverts. A consumer with no code (EOA) is skipped.
interface IFlapVaultExConsumer {
    /// @notice Called by FlapVaultEx after a request has settled — fulfilled OR refunded.
    /// @dev The funds are already in the consumer when this runs. Validate
    ///      `msg.sender == flapVaultEx`, and keep the callback within `maxCallbackGas()`.
    /// @param requestId The request id.
    /// @param status    `RequestStatus.FULFILLED` (2) or `RequestStatus.REFUNDED` (3).
    /// @param token     ERC-20 delivered or returned.
    /// @param amount    Amount delivered or returned (after fees on fulfillment).
    function onFlapVaultExSettled(uint256 requestId, uint8 status, address token, uint256 amount) external;
}
