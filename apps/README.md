> **Historical source snapshot.** COMPD's current direction is Solana Mainnet, Meteora DBC and COMPD / SOL. This package retains its original implementation meaning. See the [current project overview](https://github.com/CompdProtocol/CompdProtocol) and [architecture and implementation scope](../docs/ARCHITECTURE.md) before using these instructions.

# COMPD Interface

**Built to Compound.**

COMPD's frontend and observation dashboard: Treasury, Agent, Flow, Protocol, Docs and local Paper Workspace views, plus a separate admin interface. Pages and browser assets live in `src/`; a Node server provides local routes and API projections.

## Status

**Agent trading is not live.** Without a configured observer, financial fields display **Not Available**. Missing balances, positions and prices remain unavailable. UI controls do not establish deployment, verified holder eligibility or execution approval. The admin/evidence-service interface does not imply a deployed backend or authorize trading.

## Architecture and features

| Component | Role |
|---|---|
| Pages and browser assets | Protocol presentation, diagrams and observation panels |
| Node server | Local static routes and same-origin API projections |
| Monitoring projection | Validates optional observer data and clears unavailable/stale displays |
| Admin/evidence interface | Wallet-message authentication and review of existing transaction hashes; no transaction submission |
| Paper Workspace | Explicit local preview with unavailable-data defaults |

Financial amounts retain decimal-string precision. Presentation separates policy values from observed data; fixtures and missing observations are not promoted into live claims.

## Development

Use **Node.js 20+** and npm. The project has no declared npm dependencies; its lockfile and local browser assets are included.

```sh
npm ci
npm run dev
```

Open `http://127.0.0.1:4173`. `npm start` runs the same development server.

```sh
npm run check
npm test
npm run build
npm run preview
```

`check` validates configured JavaScript entry points. Tests use local fixtures and disposable loopback servers. `build` copies configured frontend files into `dist/`; `preview` serves that build. See [package.json](package.json) and [site.config.mjs](site.config.mjs).

## Read-only Agent monitoring

`GET /api/protocol/status` projects an optional observer's `/status` response into a same-origin dashboard API. Validated observations can supply block-pinned balances, recorded Agent evaluations/history and explicit blockers. Observation is not proof of trading or deployment.

Server-side `COMPD_STATUS_URL` accepts a credential-free loopback `/status` URL. It is not embedded in browser assets or selectable through request parameters. No observer deployment is supplied or claimed here. Backend failures and invalid snapshots produce an unavailable response and clear stale financial displays.

See [API-CONTRACT.md](API-CONTRACT.md) and [INTEGRATION.md](INTEGRATION.md). Monitoring endpoints provide no Agent activation or trading commands.

## Local Paper Workspace

Paper endpoints are disabled by default. Explicit local `--paper-demo` exposes an in-memory, waiting-for-data preview; it generates no prices, fills, orders, transactions or real holder eligibility. Its 1/3/7-day horizons do not change the Agent's eight-hour source cadence.

## Repository structure

| Path | Contents |
|---|---|
| `src/` | Page markup, styles, browser scripts and brand assets |
| `src/vendor/` | Locally vendored browser libraries and retained notices |
| `tools/` | Development/build tools and monitoring/evidence API projections |
| `test/` | Local frontend and integration regressions |
| `site.config.mjs` | Route and asset allowlists |

## Security considerations

The included server is loopback development tooling, not a production hosting recipe. Keep backend configuration and credentials server-side; retain its fixed-target and same-origin boundaries. Wallet message authentication is distinct from signing a transaction. An evidence backend must enforce authorization; hiding admin controls is not access control. Public hosting, TLS and production acceptance require separate review.

Do not publish credential-bearing URLs, runtime state or backend implementation with frontend assets. No UI state establishes trading authorization or verified deployment.

## Documentation

- [API contract](API-CONTRACT.md)
- [Monitoring and admin integration](INTEGRATION.md)
- [Frontend handoff and development boundaries](HANDOFF.md)
- [Vendored library provenance](src/vendor/README.md)
- [Third-party licensing](THIRD_PARTY_NOTICES.md)
- `SOURCE-BASELINE.json` (original export record; not bundled in this snapshot)

## Repository scope

Backend implementations, credentials and runtime state belong outside this repository. [compd-protocol](https://github.com/CompdProtocol/compd-protocol) contains contracts. This repository remains private pending a separately reviewed public release. `SOURCE-BASELINE.json` (original export record; not bundled in this snapshot) records the initial export.

## Licensing

COMPD first-party root licensing awaits explicit owner approval; no root LICENSE is provided. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) distinguishes MIT-licensed Three.js from GSAP/ScrollTrigger's Standard License. Original library notices remain unchanged. Public release requires the remaining licensing and historical-privacy decisions.
