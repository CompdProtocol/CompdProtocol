# COMPD — The Compounder

**Built to Compound.**

Solidity contracts, Foundry tests and reviewed ABI exports for BNB Chain (chain ID 56). The source includes earlier versions and prototypes; a `production` directory does not establish deployment or readiness.

## Status

**Agent trading is not live.** Preserved deployment evidence does not prove deployment of the COMPD token, Kernel, StrategyExecutor, settlement or Holder graph. Buyback execution, native burn and holder payouts are not established as active services. The initial 15-minute holder checkpoint is non-paying and remains unqualified for production.

## Key capabilities in source

- Separate accounting for principal, strategy capital and each reserve.
- Adapter admission, runtime identity and lifecycle/risk checks around strategy runs.
- Evidence-bound settlement and holder-reward review, finalization and retry paths.

These implementation capabilities are not claims of active production services.

## Architecture

The documented graph centers on [CompdVaultKernelV3](contracts/production/v3/phase7cr2ch/CompdVaultKernelV3.sol).

| Component | Role in source |
|---|---|
| Treasury | Kernel accounting separates strategy capital, treasury principal, buyback, holder-reward and protocol reserves. This is an accounting role, not a separately verified deployed contract. |
| Kernel | Holds native BNB, enforces lifecycle/allocation limits, checks component code hashes and accounts for physical fund returns. |
| StrategyExecutor | Opens and tracks runs through approved strategy adapters, subject to admission and runtime identity checks. |
| Settlement | Coordinates allocation, exit, collection and closure. Kernel accounting recognizes returned principal, realized profit and loss from physical balance changes. |
| Buyback | Policy and executor components consume a dedicated reserve subject to activation and route checks. Source and tests do not prove an active route or verified burn. |
| Holder rewards | Candidate, canonical-state, distributor and liability components bind reward windows, review, finalization and payment/retry accounting. |

Kernel economics distinguish bootstrap funding (10% strategy / 90% treasury principal), recurring native revenue (35% strategy / 15% buyback / 50% protocol), and realized profit (65% strategy / 15% buyback / 10% holders / 10% protocol). Integer rounding conserves totals. These are source rules, not claims of revenue or returns.

## Recorded BNB Chain addresses

The [sanitized address record](docs/deployment-addresses.json) preserves local verification evidence; it is not a fresh chain audit.

| Component | Address | Evidence status |
|---|---|---|
| Flap VaultPortal | `0x90497450f2a706f1951b5bdda52b4e5d16f34c06` | Recorded deployed external dependency |
| Flap Portal | `0xe2ce6ab80874fa9fa2aae65d277dd6b8e65c9de0` | Recorded deployed external dependency |
| COMPD token | `0x7b7af51136574c91a12988989c0a08e98ae97777` | Reserved address; deployment and launch unproven |

Reservation transaction: `0xa2cbaf22bad6b5b08a820f09a1c2e3c6c96fba6f4f57e8c5e86ebe068206dd43`, block `125352810`. A reservation is not a token launch. COMPD graph addresses and runtime pins remain unresolved in this evidence.

## Development

Use Foundry with Solidity **0.8.37** and [foundry.toml](foundry.toml). The baseline was validated with Foundry 1.8.4. Install the exact npm dependencies in [package.json](package.json); forge-std and upgradeable OpenZeppelin source are included.

```sh
npm install
npm run build
npm test
```

Local build/test success does not qualify deployment. Existing compiler warnings and historical qualification gaps remain.

## Repository structure

| Path | Contents |
|---|---|
| `contracts/production/v3/phase7cr2ch/` | Documented V3 graph and related components |
| `contracts/prototype/` and other contract generations | Research and historical implementations retained for reproducibility |
| `test-foundry/` | Local contract regression tests and fixtures |
| `src/flap/`, `lib/`, `vendor/` | Reference interfaces and third-party source |
| `abi/` | Reviewed ABI exports |
| `docs/` | Sanitized deployment-address evidence |
| `script/` | Preparation tooling; see the execution warning below |

## Security considerations

Do not treat local fixtures, source code, ABI exports or reserved addresses as proof of deployed runtime identity or operational readiness. Confirm the exact graph and its qualification before any integration. Never commit private keys, credential-bearing URLs, environment files or operator state. The included tests and historical evidence do not constitute a comprehensive security audit.

## Documentation

- [Architecture implementation](contracts/production/v3/phase7cr2ch/CompdVaultKernelV3.sol)
- [Recorded addresses and unresolved deployment identities](docs/deployment-addresses.json)
- [Read-only API contract](API-CONTRACT.md)
- [Third-party provenance and licensing](THIRD_PARTY_NOTICES.md)
- [Initial source baseline](SOURCE-BASELINE.json)
- [Build configuration](foundry.toml)


[compd-interface](https://github.com/CompdProtocol/compd-interface) contains the frontend. Agent implementation stays in a separate permanently private repository. This repository remains private pending a separately reviewed public release. [SOURCE-BASELINE.json](SOURCE-BASELINE.json) records the initial export; subsequent documentation commits do not change that historical baseline.

## Licensing and release scope

COMPD first-party root licensing awaits explicit owner approval; no root LICENSE is provided. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for restored dependency licenses and unresolved Flap attribution. Public release is not approved.

`contracts/prototype/` contains research prototypes. Earlier contract generations under `contracts/` are historical implementations, retained with their tests and imports; they are not interchangeable with the documented graph. The documented V3 graph is `contracts/production/v3/phase7cr2ch/`; the name `production` is not a deployment or security clearance.

`script/PrepareProduction.s.sol` is guarded preparation/simulation tooling, not a ready deployment plan. It contains `vm.startBroadcast` primitives and could submit transactions if invoked with broadcasting and suitable external authorization/configuration. The documented build/test commands do not run it. No qualified production plan, deployment instruction or activation approval is supplied. Source files and deployment evidence remain unchanged.
