# Security Policy

## Overview

COMPD is a modular treasury and strategy execution framework built for BNB Chain. Its architecture separates treasury accounting, strategy execution, settlement, buyback operations, and holder reward distribution into distinct components with defined responsibilities.

Security is considered across contract permissions, asset custody, execution boundaries, accounting integrity, and operational controls.

## Security Architecture

COMPD is designed around several core principles:

- **Controlled Execution:** Strategy operations are subject to defined authorization and execution boundaries.
- **Treasury Separation:** Treasury accounting and reserve management are separated from strategy execution responsibilities.
- **Settlement Integrity:** Strategy outcomes are accounted for through dedicated settlement mechanisms.
- **Modular Responsibilities:** Kernel, StrategyExecutor, Buyback, and Holder Reward components maintain distinct protocol responsibilities.
- **Operational Safeguards:** Deployment configuration, privileged access, and external integrations require independent verification before production use.

These architectural principles describe the system's intended security boundaries and do not constitute a guarantee of security.

## Responsible Disclosure

We encourage responsible reporting of potential vulnerabilities affecting COMPD contracts, integrations, or supporting infrastructure.

If you identify a security issue:

1. Avoid publicly disclosing exploitable technical details before maintainers have had an opportunity to investigate.
2. Contact the maintainers through a verified private communication channel listed on the official GitHub profile.
3. Provide a clear description of the issue, affected components, reproduction steps, and potential impact.
4. Never include private keys, credentials, seed phrases, or unrelated personal information.

Security reports will be reviewed according to their potential impact and reproducibility. No fixed response or remediation timeline is currently guaranteed.

## Repository Security

Contributors must not commit sensitive information, including:

- Private keys, seed phrases, keystores, or signing credentials.
- Environment files containing secrets, API keys, authentication tokens, or private RPC credentials.
- Production server configurations, internal deployment credentials, or privileged infrastructure access.
- Private operational data, database backups, or confidential user information.

Any exposed credential should be treated as compromised and promptly revoked or rotated. Removing a secret from the latest source revision does not eliminate its exposure in Git history.

## Security Status & Limitations

COMPD remains under development. The availability of source code, automated tests, and architectural safeguards does not establish that the protocol has completed independent security auditing or production qualification.

Contract deployments, integrations, and automated strategy execution must undergo appropriate security review and operational validation before handling real assets.

**Agent trading is not currently live.**

Security documentation will evolve alongside the protocol's implementation and verification process.
