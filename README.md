# COMPD — The Compounder

**Built to Compound.**

COMPD develops modular protocol accounting and execution components for BNB Chain (chain ID 56), together with a frontend for protocol presentation and observation.

## Architecture

The Kernel maintains Treasury accounting, reserve separation and lifecycle controls. StrategyExecutor and settlement components coordinate admitted strategy runs and physical fund returns. Buyback and holder-reward modules provide dedicated policy and accounting paths. The interface presents protocol information and optional observer data, with a separate transaction-evidence review interface.

These are responsibilities implemented in source, not claims of active production services.

## Repositories

| Repository | Scope |
|---|---|
| [compd-protocol](https://github.com/CompdProtocol/compd-protocol) | Solidity contracts, local tests, ABI exports and recorded deployment evidence |
| [compd-interface](https://github.com/CompdProtocol/compd-interface) | Frontend, architecture diagrams and observation/evidence API integration |

## Development status

Both repositories remain private while public-release licensing and privacy reviews are completed. Agent trading is not live. Source, tests and reserved addresses do not establish a deployed or production-qualified COMPD graph. Independent deployment evidence and integration qualification remain separate requirements.

First-party licensing awaits owner approval. Third-party components retain their own terms; no unrestricted reuse grant is implied.
