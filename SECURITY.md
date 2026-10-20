# Security Policy

## Overview

**COMPD — The Compounder**

Security is a foundational part of COMPD's architecture.

COMPD is designed around modular treasury infrastructure, controlled strategy execution, verifiable settlement, and clearly defined financial responsibilities.

Our security approach emphasizes capital protection, transparent accounting, restricted permissions, and verifiable on-chain operations.

**Built to Compound. Designed to Protect.**

---

## Security Principles

COMPD follows six fundamental security principles.

### 1. Capital Preservation

Capital protection takes priority over execution frequency.

Strategy operations are designed to operate within defined risk limits, allocation boundaries, and execution constraints. The Agent is not required to execute a trade during every operating cycle.

### 2. Treasury Isolation

Treasury custody and accounting are separated from strategy execution.

Dedicated accounting boundaries distinguish strategy capital, buyback reserves, protocol reserves, and holder reward obligations.

This separation helps prevent unauthorized movement or misallocation of funds.

### 3. Permissioned Execution

Sensitive protocol operations are governed by explicit authorization requirements.

The architecture defines distinct responsibilities for treasury management, strategy execution, settlement, and administrative controls.

Strategy execution must operate through authorized components and permitted execution paths.

### 4. Verifiable Settlement

Strategy outcomes are evaluated against actual returned assets.

Accounting mechanisms distinguish allocated capital, returned principal, and realized profit or loss.

Profit allocation is based on reconciled outcomes rather than projected performance or unrealized gains.

### 5. Controlled Buybacks

Buyback operations are designed around dedicated reserves and bounded execution permissions.

Buyback funding remains separate from strategy principal and holder reward obligations.

### 6. Holder Protection

Holder rewards follow defined eligibility, allocation, and settlement procedures.

Reward accounting is separated from discretionary strategy execution, with controls governing distribution, retry handling, and outstanding obligations.

---

## Security Architecture

| Component | Security Responsibility |
|---|---|
| Treasury Kernel | Custody boundaries, accounting integrity, reserve separation, and lifecycle controls |
| StrategyExecutor | Authorized execution, adapter restrictions, and execution safeguards |
| Settlement | Principal reconciliation and realized-profit accounting |
| Buyback Module | Reserve-limited execution and controlled asset operations |
| Holder Rewards | Eligibility verification, reward accounting, and payment controls |
| Strategy Agent | Risk evaluation, execution policy, and capital-preservation decisions |
| Interface | Transaction transparency and protocol information |

Each component operates within defined responsibilities to reduce unnecessary authority concentration.

---

## Operational Safeguards

COMPD's security design incorporates multiple layers of operational control:

- Authorization checks for privileged operations.
- Separation between treasury accounting and strategy execution.
- Strategy allocation limits and reserve boundaries.
- Runtime identity checks for authorized execution components.
- Explicit lifecycle and shutdown controls.
- Reconciliation of principal and realized financial outcomes.
- Defined holder reward accounting and recovery procedures.
- Protection of sensitive credentials and signing infrastructure.

These controls form part of the protocol's security architecture. Their effectiveness depends on the implementation and operational environment.

---

## Responsible Disclosure

We welcome responsible security research and vulnerability reports concerning COMPD.

If you discover a potential security issue:

1. Report the issue privately through a verified maintainer contact channel.
2. Include the affected component, reproduction steps, and potential impact.
3. Avoid publishing exploitable details before coordinated disclosure.
4. Never submit private keys, seed phrases, credentials, or unrelated personal information.

Reports are evaluated according to severity, reproducibility, and potential impact.

Please use an official, verified communication channel associated with the COMPD GitHub organization.

---

## Repository & Infrastructure Security

Contributors and maintainers must protect sensitive operational information.

The following materials must never be committed to public repositories:

- Private keys, wallet seed phrases, and signing credentials.
- API keys, authentication tokens, and confidential environment variables.
- Privileged infrastructure access credentials.
- Production database backups containing confidential information.
- Internal security secrets or private operational records.

Exposed credentials must be treated as compromised and rotated promptly.

Removing sensitive material from a repository does not automatically remove it from Git history.

---

## Audits & Verification

COMPD distinguishes architectural safeguards, automated testing, independent security review, and production deployment verification.

These are separate forms of assurance and should not be treated as interchangeable.

Independent audit completion, security certifications, or specific production guarantees will only be represented when supported by verifiable evidence.

Security documentation may be updated as the protocol and its integrations evolve.

---

## Security Commitment

COMPD prioritizes disciplined execution, explicit financial accounting, restricted authority, and transparent settlement.

**Capital preservation before execution.  
Verification before settlement.  
Accountability by design.**

*COMPD — Built to Compound.*
