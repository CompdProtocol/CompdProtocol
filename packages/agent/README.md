> **Historical source snapshot.** COMPD's current direction is Solana Mainnet, Meteora DBC and COMPD / SOL. This package retains its original implementation meaning. See the [current project overview](https://github.com/CompdProtocol/CompdProtocol) and [architecture and implementation scope](../../docs/ARCHITECTURE.md) before using these instructions.

# COMPD Agent

The autonomous xStocks strategy framework for **COMPD — The Compounder**, built around PancakeSwap on BNB Chain.

**AMZNx is the first supported strategy target**, with a dedicated trading architecture covering market observation, strategy evaluation, risk management, and execution planning.

COMPD is designed to expand its agent coverage to additional tokenized equities, including **NVDAx, TSLAx, AAPLx, and SPYx**, as their respective integrations and risk requirements are qualified.

The public repository provides a sanitized implementation snapshot. Production credentials and private operational infrastructure are excluded.

## Strategy scope

The intended venue is **PancakeSwap on BNB Chain**, with **AMZNx as the initial qualification target**. Source recognizes only `NVDAx`, `TSLAx`, `AMZNx`, `AAPLx` and `SPYx`; recognition does not establish an admitted route. Protocol adapter source supports fixed TSLAx/AMZNx V3 venues with a WBNB/USDT bridge, subject to guard qualification and admission.

**WBNB is funding and swap infrastructure, not the strategy asset.** The strategy universe is xStocks. Venue code and local tests do not prove approval or trading.

## Architecture

| Layer | Responsibility in source |
|---|---|
| Scheduler/lifecycle | Reads the pinned graph, tracks run history and plans bounded lifecycle actions on eight-hour UTC slots. |
| xStocks policy | Evaluates permitted symbols, market/session freshness, quotes, liquidity and risk gates. Production entry routes remain disabled. |
| Observation | Records bounded evaluations and projects read-only status/dashboard data; missing inputs remain explicit. |
| Operations | Coordinates managed observation workers, health and local state ownership. Shipped worker templates remain disabled. |
| Holder/native-fee dependencies | Preserve planner, ABI and accounting dependencies; inclusion does not activate payouts or fee execution. |

See [xstocks_agent.py](tools/agent-scheduler/xstocks_agent.py), [agent_lifecycle.py](tools/agent-scheduler/agent_lifecycle.py) and [public_status.py](tools/agent-scheduler/public_status.py).

## Risk rules

- Protocol ceilings: 10% of strategy capital per run, 30% aggregate allocation and three active runs. The 3% designed-loss budget is not a guaranteed realized-loss bound; a breach halts new Kernel allocation.
- Experimental defaults: 5% allocation, 1% momentum threshold, 6% take-profit signal and a 3% adverse-move exit signal. These are fixture signals, not live orders or guaranteed stops.
- Default quote constraints: 60-second maximum price age, 60-second deadline and 0.5% slippage. Validation caps configured slippage at 1%.
- New risk requires eligible lifecycle state, complete history, coherent block identity, qualified inputs and accounted capital. Closure, stale data and unresolved qualification remain blockers.

Defaults are defined in [xstocks_agent.py](tools/agent-scheduler/xstocks_agent.py); protocol ceilings are enforced by the Kernel source. No execution price, return or profitability is guaranteed.

## Blockers

Live operation still requires production route admission, independent price/guard qualification, verified deployed graph identities, settlement/finality criteria and real integration evidence. Preserved records do not prove a launched COMPD graph. Tests do not remove these blockers. No execution-enablement instructions are provided here.

## Local development

Core observation modules use Python **3.12+** and its standard library. Holder planning/ABI dependencies require **Node.js 20+**; an optional read adapter uses pinned `ethers` from [package.json](package.json). Chain decoding requires the Cast version in [DEPENDENCIES.md](DEPENDENCIES.md), without implying host qualification.

Focused offline regressions, from the repository root:

```sh
python -m unittest discover -s tools/agent-scheduler -p test_dashboard_api.py
python -m unittest discover -s tools/agent-scheduler -p test_xstocks_agent.py
```

Keep `tools/` and `offchain/` relative paths intact. Credentials, sensitive operational configuration and persistent state stay outside version control. Execution and credential setup are deliberately omitted.

`SOURCE-BASELINE.json` (original export record; not bundled in this snapshot) and `MANIFEST.json` describe the initial export. The strict package verifier applies to that original release; later README changes intentionally differ from its historical inventory. Documentation updates do not qualify a new deployment package.
