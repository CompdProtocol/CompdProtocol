# Stable read-only frontend API — schemaVersion1

GET /api/protocol/status returns:

- availability: NOT_AVAILABLE or BACKEND_OBSERVATION. This is not production qualification.
- observedAt: response-generation ISO timestamp. snapshot: nullable block number/hash/timestamp.
- policy: canonical source-independent policy values, separate from observed balances.
- treasury: decimal-string Wei fields or null. Zero is shown only when supplied by the observer. Fee coverage is RECEIPT_SAMPLE_ONLY, not complete lifetime history.
- agent: approved assets,28800-second cadence, inactive status, nullable run count/positions/unrealized PnL, recorded job state/hash list.
- flow: fee sample, interface-observed bonding state, inactive buyback/holder status, confirmed observer burn receipts and NON-PAYING first-window checkpoint.
- protocol: chain56, reserved CA/status, nullable launch/fee transaction hashes, code-pin-matched contract observations when block-pinned extended observer data exists.

Backend errors/timeouts/reorgs yield503 with a generic NOT_AVAILABLE response; browser clears old balances and records. Every request is same-origin. A connected backend's timestamped observation does not prove live/independent mainnet deployment. Missing data is null, never a fake0.

GET /api/health reports tradingEnabled=false, paperTradingEnabled=false by default, holder eligibility configured=false. GET /api/assets returns only the five approved labels, no prices, deployments or verified freshness. GET /api/eligibility syntax-checks addresses and returns configured=false,eligible=null,balance=null until a real holder integration exists.

/api/paper/* is503 by default. With explicit local --paper-demo, it retains the historical in-memory response shape/mode=paper-mock,transactionsSent=false,waiting_for_data.1/3/7-day horizons are PAPER ONLY. No holder balance is fabricated. These controls cannot affect the live Agent or treasury.

There are no activation, execution, claim, configuration or signer endpoints. COMPD_STATUS_URL is private server configuration restricted to credential-free loopback /status and cannot be overridden by request parameters. No dependencies added.
