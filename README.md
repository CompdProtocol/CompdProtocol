# COMPD — The Compounder

**Built to Compound.**

Treasury discipline. Modular execution. Evidence-led settlement.

![Implementation: BNB Chain](https://img.shields.io/badge/Implementation-BNB_Chain-C9A44C?style=flat-square&labelColor=111111)
![Direction: Solana research](https://img.shields.io/badge/Direction-Solana_research-9945FF?style=flat-square&labelColor=111111)
![Pump.fun: proposed](https://img.shields.io/badge/Pump.fun-Proposed-7AD9B2?style=flat-square&labelColor=111111)

[Overview](#overview) · [Architecture](#architecture) · [Ecosystem direction](#ecosystem-direction) · [Repositories](#repositories) · [Security](#security-and-release)

---

## Overview

COMPD is a modular treasury accounting and execution protocol being developed for **BNB Chain**. It separates capital accounting, strategy dispatch, realized-profit settlement, buyback policy and holder rewards into defined responsibilities.

The design follows a clear principle: account for capital explicitly, constrain execution at permission boundaries, and settle outcomes against actual returned assets.

## Architecture

The current implementation uses **Solidity contracts and Foundry tests**. The Kernel holds native BNB and maintains accounting buckets; authorized modules coordinate execution and reserve operations.

| Component | Responsibility in the BNB Chain source |
|---|---|
| Kernel / Treasury | Custody, principal and reserve accounting, lifecycle controls and allocation limits |
| StrategyExecutor | Dispatch strategy runs through admitted adapters with runtime identity checks |
| Settlement | Coordinate allocation, exit, collection and closure; reconcile physically returned principal and realized results |
| Buyback | Request bounded execution from the dedicated buyback reserve |
| Holder Rewards | Review eligibility evidence, finalize distributions and control payment/retry accounting |
| Interface | Present protocol information, optional read-only observations and transaction-evidence review |

Capital allocation updates accounting buckets. Transfers occur through explicit execution and payment paths. Positive realized profit is allocated only after reconciliation; reserve balances alone do not establish a buyback or payout.

## Ecosystem direction

**Solana and Pump.fun are a proposed ecosystem direction.** Future work would evaluate ecosystem compatibility, treasury boundaries and venue integration.

This direction is separate from the existing BNB Chain implementation. No Solana deployment or active Pump.fun integration is established. Any future implementation needs its own native programs, integration work and deployment evidence; the existing Solidity contracts remain BNB Chain contracts.

## Repositories

| Repository | Focus | Access |
|---|---|---|
| [compd-protocol](https://github.com/CompdProtocol/compd-protocol) | Solidity contracts, Foundry tests, ABI exports and recorded evidence | Private |
| [compd-interface](https://github.com/CompdProtocol/compd-interface) | Frontend, protocol observation and evidence-review interface | Private |

The standalone repositories listed above require authorized access. The existing public repository retains its source and documentation unchanged by this refresh.

## Development status

The BNB Chain codebase contains the protocol modules and local validation tooling described above. **Agent trading is not live.** Source implementation and deployment evidence are distinct milestones; active buyback, burn and holder-payment services are not established by this profile.

## Security and release

Permission boundaries, runtime identity checks and physical-return reconciliation are central to the implementation. No completed independent security audit or production-readiness claim is made.

- [Release v0.1.0](https://github.com/CompdProtocol/CompdProtocol/releases/tag/v0.1.0)
- [Security policy](SECURITY.md)
- [Existing architecture reference and repository layout](docs/ARCHITECTURE.md)
- [Contribution guidance](CONTRIBUTING.md)

The architecture reference describes the existing public monorepo layout; the standalone repositories above are separate projects. Existing release documentation remains unchanged.

Public source release remains subject to licensing, attribution and historical-privacy review. COMPD first-party licensing awaits owner approval; third-party components retain their own terms.
