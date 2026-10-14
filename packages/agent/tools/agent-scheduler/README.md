# COMPD Agent scheduler

## Automatic lifecycle extension

Without `--plan`, the worker now evaluates the canonical graph automatically. It discovers runs from append-only Settlement history in batches of 64, prioritizes recovery, and persists deterministic domain-bound plans. Each lifecycle step/run has one action key per 8-hour slot; confirmations allow subsequent distinct exit/collect/close steps in the same slot. Collection repeats at most once per run per slot. Dry-run never treats simulated state changes as mined execution. Closed runs, confirmations and planning decisions are recorded in SQLite.

```powershell
python -u agent_scheduler.py --config config.json --policy approved-standing-policy.json --state agent-state.sqlite
```

`--policy` is a standing operational rule, not a manual per-cycle plan. `policy.blocked.json` is intentionally unusable. No production trading policy or production adapter implementation was found in the canonical inventory. Entry/holding/settlement rules therefore remain undefined until owner-approved. The supported optional policy template requires an admitted, pinned adapter, explicit position fraction (at most 1000 bps), explicit holding seconds, `ADMITTED_ADAPTER_EACH_8H_SLOT` entry instruction and `FULL_PRINCIPAL_NO_PENDING_CLAIM` settlement instruction. These are opt-in implementation capabilities, **not inferred existing approvals**. Actual adapter semantics must justify that instruction; zero reported pendingClaim is not an independent finality proof. No loss write-off/finality rule is implemented.

With no policy, only permissionless principal collection for existing exited runs reporting recoverable funds is planned. Reported recovery amounts are informational: the unchanged Kernel credits only physical balance deltas. New entries and automated exits/closing remain blocked. Emergency/terminated states halt this ordinary worker; PAUSED/SHUTDOWN permit only existing-run recovery/explicit approved exits/settlement, as allowed by canonical contracts.

Automatic sizing obeys canonical 10% position / 30% aggregate / three-run ceilings, liquid accounted capital and additional operator caps. Every action is still simulated against the actual pinned graph from the fixed Agent. Queued retries preserve original IDs/amounts and recheck current policy/lifecycle eligibility. Chain timestamp must belong to the same UTC slot as the host; block hash changes halt evaluation. Standing-policy changes against a persisted database halt for reconciliation.

Python standard library + existing free Foundry Cast. Continuous foreground worker; UTC slots are 00:00, 08:00 and 16:00. Manual-plan compatibility still permits one action per slot. Automatic mode permits distinct bounded lifecycle steps, with at most one fresh entry per standing-policy slot. Missed slots are never replayed. The PowerShell wrapper restarts a crashed dry-run worker after 30 seconds. SQLite state survives restarts.

Use the same durable local SQLite file for every instance of this Agent. Do not delete/copy/reset it or run this wallet from another state database or service. SQLite locks coordinate workers sharing that file; they do not coordinate distinct hosts/databases. Secure the state/config/plan/key files with OS permissions, use synchronized UTC time, and keep this wallet dedicated to the scheduler. An approval reference is an operator record, not cryptographic approval or on-chain authorization.

## Dry-run

Populate a COPY of `config.blocked.json` with independently verified deployed graph addresses, exact full-runtime Keccak hashes, a canonical chain anchor, approved adapters and explicit operating limits. The blocked template deliberately cannot run; synthetic test addresses are not production defaults. Configuration changes against an existing database halt for reconciliation.

Set `BSC_RPC_URL` and `COMPD_CAST_BIN` in the process environment. Never put credential-bearing URLs in logs. Then:

```powershell
python -u agent_scheduler.py --config config.json --plan approved-plan.json --state agent-state.sqlite
# One iteration:
python agent_scheduler.py --config config.json --plan approved-plan.json --state agent-state.sqlite --once
# Optional foreground crash recovery (dry-run only):
./Run-AgentDryRun.ps1 -Python python -Config config.json -Plan approved-plan.json -State agent-state.sqlite
```

A manual compatibility plan has exactly `cycle` (integer Unix seconds divided by 28800), `approvalReference`, and `action`. Action fields: `method`, positive `runId`, nonzero bytes32 `reference`; `startRun` additionally needs approved `adapter` and integer/string `amountWei`. Only `startRun`, `requestExit`, `collectRun`, `closeRun` are supported. They target the canonical Settlement module from the fixed Agent wallet with zero native value. Reference means allocation ID, exit ID, collection-attempt ID or close ID respectively. Automatic mode generates these plans from the optional approved standing policy and canonical state, without manual cycle files. No strategy algorithm, finality/write-off decision, adapter admission, guardian intervention, Buyback or holder payout is invented.

## Safety / future execution

Default is read-only: no keys loaded and no send method exposed by the RPC client. Tests use fake signing/RPC plus actual offline Cast ABI encoding. An optional future `--execute --execution-approval <reference>` adapter is included but has NOT been activated, signed or broadcast during this task. It additionally requires `COMPD_AGENT_KEYSTORE` and `COMPD_AGENT_PASSWORD_FILE`; keystore address must equal the approved Agent. An argument is not a grant of owner authorization. Separate owner activation approval and funded-gas operational evidence remain required.

Each submission reserves worst-case `maxGas * currentGasPrice` and start principal against its UTC submission-day budgets before invoking Cast. Reservations are conservative and never automatically refunded/released. Native transaction value is always zero. On-chain capital/risk/adapter/lifecycle limits remain enforced by simulation and unchanged contracts; off-chain caps only add restrictions. Bootstrap 10/90 and profit 65/15/10/10 remain in unchanged Kernel code.

Pre-submit failures retry at bounded exponential intervals; exhausted cycles stay exhausted. Pending transactions block new cycles until a matching canonical receipt reaches the configured confirmation depth. Receipt identity, sender, target, calldata, nonce, value, block hash and gas limit are checked. Reorg receipts remain pending. This confirmation depth is an explicit operational policy, not a finality proof; a deep reorg after confirmation requires operational reconciliation. No automatic nonce replacement or gas bump occurs.

Crash/timeout after durable SUBMITTING returns SUBMISSION_UNKNOWN and never resends. Mined reverts stop subsequent execution. Keep the database, reconcile the wallet nonce/hash/receipt and obtain operator review; there is intentionally no automatic reset/bypass command. Per-day caps are submission reservation limits, not claimed measurements of actual calendar-day chain expenditure.

## Local tests

```powershell
$env:COMPD_CAST_BIN = 'C:/path/to/cast.exe'
# Optional sandbox workaround: existing writable test-temp directory
$env:COMPD_TEST_TEMP = 'C:/path/to/writable/temp'
python -m unittest discover -s . -p test_agent_scheduler.py -v
```

Remaining decisions: admitted adapter/trading policy and per-slot plans, settlement criteria, verified deployed graph, operating limits/confirmation policy, independent integration and eventual execution authorization. No production readiness or security clearance is implied. All previous security findings and historical failures remain unchanged.
