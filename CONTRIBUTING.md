# Contributing to COMPD

COMPD — The Compounder · **Built to Compound.**

Contributions should improve protocol clarity, reliability, security or developer experience. Keep proposals focused and support technical claims with source or reproducible evidence.

## Start with the relevant component

| Area | Location | Reference |
|---|---|---|
| Frontend and observation interface | `apps/` | [Frontend guide](apps/README.md) |
| Observation and strategy research | `packages/agent/` | [Component guide](packages/agent/README.md) |
| Solidity protocol and Foundry tests | `packages/protocol/` | [Protocol guide](packages/protocol/README.md) |
| Architecture and packaging evidence | `docs/` | [Architecture](docs/ARCHITECTURE.md) · [Snapshot notes](docs/PUBLIC-SNAPSHOT-NOTES.md) |

The current implementation targets BNB Chain. Solana and Pump.fun are proposed ecosystem directions, not active integrations. Discuss substantial architectural changes before implementation.

## Prepare a contribution

1. Read the [README](README.md), component guide and [security policy](SECURITY.md).
2. Create a focused branch in your fork and follow the component's existing conventions.
3. Make the smallest coherent change; explain new dependencies and configuration requirements.
4. Run the relevant component checks and include regression coverage for behavior changes.
5. Open a pull request describing the problem, resulting behavior and validation evidence.

Use the commands documented by the component you change. The frontend lives directly under `apps/`; root `interface:*` scripts currently reference `apps/interface/`, so use the component's own instructions rather than assuming those wrappers resolve.

## Review expectations

- **Protocol changes:** explain effects on permissions, custody, accounting, settlement, reserves and external calls. Include relevant Foundry tests.
- **Strategy research:** preserve data-freshness, qualification, lifecycle and execution boundaries. Fixtures and simulations must remain distinguishable from observed results.
- **Interface changes:** preserve unavailable-data behavior and the separation between presentation, evidence and authorization.
- **Documentation changes:** check links and diagrams; distinguish implemented behavior, proposed design and verified deployment evidence.

A contribution must not activate trading, alter production settings or deploy contracts without a separate, explicit operational review. Local and fork tests do not establish an independent audit or production readiness.

## Pull request checklist

- State the affected component and the reason for the change.
- Summarize tests performed, results and any checks that could not be run.
- Explain compatibility, permission or accounting implications where relevant.
- Update associated documentation and preserve third-party attribution.
- Exclude credentials, private operational data and generated runtime state.

## Security and licensing

Follow [SECURITY.md](SECURITY.md) for vulnerability reporting. Do not post exploitable details or secrets in public issues or pull requests.

Do not include private keys, seed phrases, credential-bearing URLs, production environment files or confidential user data. Use sanitized examples and disposable local fixtures.

COMPD first-party licensing awaits owner approval. Do not add a project license, relicense existing work or introduce third-party material without verified permission and required notices. Public availability alone does not grant unrestricted reuse rights.
