# COMPD — The Compounder

**Built to Compound.**

COMPD brings its interface, agent systems, and on-chain protocol into one developer-facing monorepo. The project is organized around three connected areas: an interface for understanding protocol state, agent software for evaluating observations and planning actions, and Solidity contracts that define protocol accounting and lifecycle rules.

This repository is the public home for the COMPD codebase. It includes the components listed below, their development workflows, tests, and supporting documentation.

> **Smart contracts included.** This repository contains Solidity source, ABI exports, and contract tests. Contract source and passing tests are not a substitute for an independent security audit, nor do they prove that a contract is deployed, active, or ready to handle real assets. Verify deployment addresses and runtime code independently before relying on them.

## Project components

| Path | Component | Purpose |
|---|---|---|
| `apps/interface/` | Interface | Web UI, dashboard views, local development server, and frontend tests |
| `packages/agent/` | Agent | Observation, evaluation, planning, and supporting test/fixture code |
| `packages/protocol/` | Protocol | Solidity contracts, ABI exports, Foundry tests, and protocol documentation |
| `docs/` | Project docs | Monorepo architecture and public-repository guidance |

Each component remains in its own directory to preserve its existing paths and tooling while making the overall project easier to explore and develop.

## What COMPD contains

- A web interface for exploring protocol and agent-related views.
- Agent observation and planning code, with offline fixtures and regression tests.
- Solidity contracts covering protocol accounting, strategy lifecycle, settlement, and related modules.
- ABI exports, contract tests, and technical documentation.
- Local development commands for working on each component independently.

Some private operational material—such as server deployment configuration, service unit files, credentials, runtime state, and selected operational helpers—is intentionally not included in this public repository. The repository is intended for project development and review, not as a turnkey production server deployment.

## Quick start

Install the tools needed for the component you want to work on. The interface uses Node.js 20+ and npm; the agent tests use Python 3.12+; the protocol uses Foundry and the dependencies declared in its package configuration.

### Interface

```bash
cd apps/interface
npm ci
npm run check
npm test
npm run build
npm run dev
```

Open the local URL printed by the development server (normally `http://127.0.0.1:4173`). See [`apps/interface/README.md`](apps/interface/README.md) for details.

### Agent

```bash
cd packages/agent
python -m unittest discover -s tools/agent-scheduler -p test_dashboard_api.py
python -m unittest discover -s tools/agent-scheduler -p test_xstocks_agent.py
```

Some optional tests and modules require additional dependencies. See [`packages/agent/README.md`](packages/agent/README.md).

### Protocol and smart contracts

```bash
cd packages/protocol
npm install
npm run build
npm test
```

These commands require Foundry (`forge`) and the package dependencies. Review [`packages/protocol/README.md`](packages/protocol/README.md) for contract structure, documented addresses, and execution-related warnings.

## Architecture

At a high level, COMPD separates the user-facing interface, agent observation/planning logic, and on-chain protocol rules. The interface can present observed data; the agent code can evaluate available observations and form plans; the protocol contracts define on-chain accounting and lifecycle constraints. These components have different responsibilities and should not be treated as interchangeable sources of truth.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) and the component READMEs for implementation details.

## Security and deployment

- Never commit private keys, seed phrases, passwords, API tokens, `.env` files, production RPC credentials, or private runtime state.
- Treat dashboard values, fixtures, and offline tests according to their documented data source; they are not automatically live or authoritative financial data.
- Verify contract addresses, deployed bytecode, configuration, and the complete contract graph against the intended chain before integration.
- Review any script that can broadcast transactions before running it. A build or test command should not be interpreted as deployment approval.
- Obtain independent security review before connecting real assets or enabling automated execution.

Report suspected vulnerabilities privately according to [`SECURITY.md`](SECURITY.md). These notes describe safe handling expectations; they do not imply that the entire codebase has been audited.

## Contributing

Read [`CONTRIBUTING.md`](CONTRIBUTING.md), [`SECURITY.md`](SECURITY.md), and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) before opening a pull request.

## License

No root license is included at this time. Unless the project owner adds a license, rights to reuse, modify, and redistribute COMPD's first-party code are not granted by default. Review component-level third-party notices before redistributing any bundled dependency.
