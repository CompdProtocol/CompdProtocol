# COMPD — The Compounder

**Built to Compound.**

<img width="2172" height="724" alt="COMPD — The Compounder" src="https://github.com/user-attachments/assets/2d931a88-f453-4f65-93ae-c27e6de9f1df" />

Solana Mainnet · Meteora Dynamic Bonding Curve · COMPD/SOL

COMPD is a Solana-native treasury accounting and authorized-execution protocol. It gives capital a defined lifecycle: verify receipts, allocate reserves, authorize bounded strategy capital and reconcile realized results.

The primary source repository is **[compd-solana](https://github.com/CompdProtocol/compd-solana)**. It contains the Anchor program, integer accounting crate, Solana Agent interfaces and Meteora integration. Solana Mainnet is the target network; source publication is not evidence of a completed mainnet deployment, live trading or an independent audit.

[Source](https://github.com/CompdProtocol/compd-solana) · [Architecture](https://github.com/CompdProtocol/compd-solana/blob/main/docs/ARCHITECTURE.md) · [Program reference](https://github.com/CompdProtocol/compd-solana/blob/main/docs/PROTOCOL.md) · [Contributing](https://github.com/CompdProtocol/compd-solana/blob/main/CONTRIBUTING.md)

## Protocol architecture

COMPD separates custody, attribution, policy, execution preparation and reconciliation. An accounting reserve is not an executed swap or holder payment.

| Component | Implemented responsibility | Source |
|---|---|---|
| Treasury program | SOL custody, authority checks, fixed recipients, allocation, settlement and funded holder claims | [Anchor program](https://github.com/CompdProtocol/compd-solana/blob/main/programs/compd-treasury/src/lib.rs) |
| Integer ledger | Checked balances, principal recovery, allocation limits and profit splits | [Rust accounting](https://github.com/CompdProtocol/compd-solana/blob/main/crates/accounting/src/lib.rs) |
| Meteora adapter | Pool/mint validation, unsigned creator-fee claims and attributed receipts | [DBC adapter](https://github.com/CompdProtocol/compd-solana/blob/main/packages/meteora-dbc/index.mjs) |
| Strategy Agent | Eight-hour observation cycles, policy evaluation, unsigned preparation and durable reconciliation | [Agent modules](https://github.com/CompdProtocol/compd-solana/tree/main/packages/agent) |
| Holder tooling | Qualified snapshots, Merkle allocations and funded claim reconciliation | [Holder SDK](https://github.com/CompdProtocol/compd-solana/blob/main/packages/sdk/holders.mjs) |

## Solana smart contracts

The Rust/Anchor treasury uses separate `Treasury`, `Run`, `Distribution` and `Claimed` accounts. Its instructions cover initialization, physical revenue deposits, bounded allocation, settlement, pause control, fixed-recipient reserve release, distribution funding and holder claims.

Treasury authority remains privileged. Allocation pays only the configured executor; settlement requires authority and executor signatures. The current program limits individual allocation to 10% of liquid plus deployed strategy capital, aggregate deployment to 30%, and active runs to three. A realized loss pauses new allocation.

[Instructions, constraints and accounting invariants](https://github.com/CompdProtocol/compd-solana/blob/main/docs/PROTOCOL.md) explain what these controls enforce and where off-chain trust remains.

## Meteora DBC integration

Meteora Dynamic Bonding Curve is COMPD's selected launch infrastructure for the COMPD/SOL pair. The source verifies configured cluster, pool, creator, config and mint identities using official SDK interfaces.

Creator-fee receipt processing binds finalized transaction evidence to the expected claim and physical SOL receipt. A receipt at the configured receiver is separate from a deposit into treasury custody; aggregate vault balances are not assumed to be COMPD revenue.

Qualified DBC-to-DAMM-v2 position-fee handling is implemented separately. Mixed asset receipts remain distinct and are not silently counted as SOL income. [Integration documentation](https://github.com/CompdProtocol/compd-solana/blob/main/docs/METEORA-DBC.md) describes supported paths and migration limits.

## Autonomous Agent

The Agent supplies an eight-hour UTC observation scheduler, executable quote qualification, spend/exposure controls, receipt journaling and custody reconciliation. The scheduler observes; it does not automatically invoke a trading loop.

Transaction preparation remains unsigned. Exact-message approval, external wallet submission, finalized confirmation and treasury settlement are distinct stages. The repository contains no enabled signing or broadcasting service. [Agent documentation](https://github.com/CompdProtocol/compd-solana/blob/main/docs/AGENT.md) maps the implemented interfaces and remaining orchestration requirements.

## Two financial flows. One treasury.

| Source | Strategy Capital | Buyback Reserve | Holder Rewards | Protocol Reserve |
|---|---:|---:|---:|---:|
| Eligible revenue | 35% | 15% | 0% | 50% |
| Positive realized strategy profit | 65% | 15% | 10% | 10% |

Returned principal is recovered before positive profit is allocated. Calculations use integer arithmetic, with rounding remainder assigned to Protocol Reserve. Unrealized price changes and executable quotes are not settled profit.

A buyback reserve release is separate from market execution. The prepared buyback path combines a bounded SOL-to-COMPD swap with a checked burn of the protected minimum output; excess output requires separate handling.

## Holder Rewards

The 10% profit allocation credits a reward reserve. Snapshot tooling aggregates eligible standard-SPL balances, constructs distribution-bound Merkle proofs and reconciles funded distributions against claim accounts.

The authority reviews eligibility and funds a Distribution PDA. A holder signs a valid claim; a unique index account prevents replay. Rewards are conditional on settled profit, eligibility and funding, not a fixed yield or automatic payment for holding tokens. [Holder Rewards](https://github.com/CompdProtocol/compd-solana/blob/main/docs/HOLDER-REWARDS.md) documents exclusions and snapshot limits.

## Technology stack

- **Rust and Anchor 0.31.1:** treasury custody and accounting.
- **JavaScript ES modules and Node.js 24+:** Agent and SDK wrappers.
- **Official Solana and Meteora SDKs:** account validation and unsigned transaction construction.
- **SQLite and integer accounting:** durable local evidence and deterministic allocation.

The client code is JavaScript, not a claimed first-party TypeScript implementation. [Dependency provenance](https://github.com/CompdProtocol/compd-solana/blob/main/docs/DEPENDENCIES.md) and [all 14 disclosed dependency findings](https://github.com/CompdProtocol/compd-solana/blob/main/docs/DEPENDENCY-SECURITY.md) remain public. Source availability does not establish mainnet security approval.

## Featured repositories

| Repository | Purpose |
|---|---|
| **[compd-solana](https://github.com/CompdProtocol/compd-solana)** | Primary Solana-native protocol source, tests and technical documentation |
| [CompdProtocol](https://github.com/CompdProtocol/CompdProtocol) | GitHub profile presentation and retained historical project records |

Historical material is not presented as deployed Solana code. The active implementation and contributor entry point are in `compd-solana`.

## Open Source Contributions

CompdProtocol has submitted two focused documentation contributions to the Meteora DBC SDK. Both are **OPEN — pending review, not merged**, checked on 23 October 2026.

| Contribution | Scope | Status |
|---|---|---|
| [Meteora DBC SDK #131](https://github.com/MeteoraAg/dynamic-bonding-curve-sdk/pull/131) | Correct case-sensitive function anchors in the SDK reference | Open, unmerged |
| [Meteora DBC SDK #132](https://github.com/MeteoraAg/dynamic-bonding-curve-sdk/pull/132) | Correct creator-fee receiver parameter types in the documentation | Open, unmerged |

These are independent external contributions. They do not imply Meteora affiliation, endorsement or partnership. Linked pull requests are the authoritative source for subsequent status changes.

## Technical documentation

- [Architecture and trust boundaries](https://github.com/CompdProtocol/compd-solana/blob/main/docs/ARCHITECTURE.md)
- [Anchor program, accounts and instructions](https://github.com/CompdProtocol/compd-solana/blob/main/docs/PROTOCOL.md)
- [Meteora DBC and migration interfaces](https://github.com/CompdProtocol/compd-solana/blob/main/docs/METEORA-DBC.md)
- [Agent lifecycle and recovery](https://github.com/CompdProtocol/compd-solana/blob/main/docs/AGENT.md)
- [Holder snapshots and funded claims](https://github.com/CompdProtocol/compd-solana/blob/main/docs/HOLDER-REWARDS.md)
- [Security architecture](https://github.com/CompdProtocol/compd-solana/blob/main/docs/SECURITY.md) and [reporting policy](https://github.com/CompdProtocol/compd-solana/blob/main/SECURITY.md)
- [Contribution guide](https://github.com/CompdProtocol/compd-solana/blob/main/CONTRIBUTING.md)
- [First-party license scope and third-party exclusions](https://github.com/CompdProtocol/compd-solana/blob/main/LICENSE-SCOPE.md)

**COMPD — The Compounder · Built to Compound.**
