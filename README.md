# COMPD — The Compounder

**Built to Compound.**

COMPD is an experimental on-chain strategy and observation project organized as a single public monorepo. It brings together the interface, agent/observation code, and Solidity protocol source.

> **Status: research and development. Not financial advice. Not audited. Not a production deployment.**
> The included source, tests, ABIs, fixtures, and recorded addresses do not prove that COMPD is deployed, active, secure, profitable, or authorized to trade. Do not send funds or use these contracts with real assets without an independent security review.

## Repository layout

| Path | Purpose |
|---|---|
| `apps/interface/` | Web interface, dashboard projections, local development server, and UI tests |
| `packages/agent/` | Agent observation, planning, and offline fixture/regression code |
| `packages/protocol/` | Solidity contracts, ABIs, Foundry tests, and protocol documentation |
| `docs/` | Monorepo architecture and public-safety notes |

The three components remain in separate directories to preserve their project-specific paths and tooling.

## What is included

- Web UI and local preview tools.
- Agent observation/planning source and offline tests.
- Solidity source, interfaces, ABI exports, and Foundry tests.
- Public documentation and non-secret example fixtures.

Private server deployment instructions, service unit files, operator configuration bundles, and selected operational executor helpers from the private source exports were intentionally excluded from this public bundle. This repository is not a server deployment package.

## Current safety boundaries

- Agent trading is **not represented as live** by this repository.
- UI dashboards and fixtures are not authoritative financial data.
- Smart-contract source and tests are not an audit or deployment proof.
- Historical/prototype contracts are retained for research; do not assume every contract is current or production-ready.
- Never commit private keys, seed phrases, passwords, API tokens, `.env` files, production RPC credentials, or private runtime state.
- Treat any address in the source as historical evidence unless independently verified against the target chain.

## Quick start

Requirements: Node.js 20+ and npm. Foundry is needed for Solidity builds/tests. Python 3.12+ is needed for the agent's Python tests.

### Interface

```bash
cd apps/interface
npm ci
npm run check
npm test
npm run build
npm run dev
```

Open the local URL printed by the development server (normally `http://127.0.0.1:4173`).

### Agent

Run from `packages/agent/`:

```bash
python -m unittest discover -s tools/agent-scheduler -p test_dashboard_api.py
python -m unittest discover -s tools/agent-scheduler -p test_xstocks_agent.py
```

Some optional tests and modules require Node.js dependencies as documented in that package.

### Protocol

Run from `packages/protocol/`:

```bash
npm install
npm run build
npm test
```

These commands require Foundry (`forge`) and the package dependencies. A passing local build/test does not establish deployment readiness or security.

## Smart contracts

Yes, this public repository includes Solidity contracts, ABI files, and tests under `packages/protocol/`. Contracts may control assets if deployed and configured. Review the code and deployment assumptions carefully; do not deploy to mainnet or fund contracts based solely on this repository.

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before opening a pull request.

## License

No license has been declared in this repository yet. Unless and until a license is added by the project owner, all rights are reserved and reuse/redistribution may be restricted.
