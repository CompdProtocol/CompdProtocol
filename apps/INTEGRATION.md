# Frontend integration notes

Canonical owner requirements supersede the original developer handoff's70/20/10 split, additional markets, demo eligibility and Agent-only Buyback trigger description. HANDOFF.md describes the current included frontend; EXTERNAL-UI-RETURN.md is source-return guidance. Neither grants deployment or execution authorization.

Architecture: browser compd-api.js → same-origin GET /api/protocol/status → server-side allowlisted projection → existing loopback GET /status. The monitoring path requires no browser wallet or transaction signing. The separate admin/evidence integration below uses wallet message signatures. public_status.py is additive and leaves the existing worker/contracts/configuration unchanged. The frontend server serves only allowlisted assets; backend URLs, configs and credentials are never exposed. Both servers bind to loopback. Public hosting/reverse-proxy/TLS configuration is outside this local patch.

## Connect a verified observer locally

Run the existing observer with its reviewed private configuration/identity files, or run the additive public_status.py from tools/agent-scheduler:

    python public_status.py --config <reviewed-config.json> --identities <reviewed-identities.json> --state <existing-agent-state.sqlite> --serve 4174

BSC_RPC_URL and COMPD_CAST_BIN remain server-side environment variables. No valid live manifest or credentials are bundled; the existing blocked templates cannot substitute for verified identities. public_status.py has no launch verification, signing, activation or transaction endpoints. It reuses stored launch/burn observations from the existing observer, revalidates their evidence and pins current reads to a numbered block. The additional eth_getBalance method is read-only and does not broaden the original worker's RPC whitelist. Missing phase evidence is NOT VERIFIED, never assumed80%.

In another shell, from frontend:

    $env:COMPD_STATUS_URL='http://127.0.0.1:4174/status'
    npm run dev

The legacy launch_status.py /status response also works for Strategy Capital, realized profit/loss, Holder reserve, fee receipt sample, checkpoint and receipts. Other fields stay null until the extended observer supplies them. Fee receipt samples and total native forwarding (including donations) are explicitly distinguished; neither is fabricated lifetime Flap revenue.

Protocol CA stays RESERVED. Backend code-pin matches/receipts are observations, not independent deployment clearance. Post-bonding Pancake-reported interface state is not verified router liquidity or burn compatibility. Positions, prices and unrealized PnL remain unavailable because no approved venue/provider integration exists.

Paper state has a separate API namespace and cannot feed live Treasury/Agent/Flow data. Controls are disabled by default, opt-in preview never fabricates holder eligibility and has no strategy engine/price provider. Holder rewards remain passive; there is no claim, staking or treasury-control endpoint.

First checkpoint is a NON-PAYING observer record, not payout evidence.10/90 bootstrap,35/15/50 fees,65/15/10/10 profit, five permitted xStocks labels and the eight-hour source evaluation cadence (live Agent trading is not enabled) are preserved. Source animations and responsive styles are retained; only profit-diagram branch geometry changed to include Holder Rewards.

Remaining: configured verified observation backend, independently verified deployment/launch, approved trading/price/settlement integration, verified buyback routes/native burn, complete TWAB tracking and900-second onchain payout support, and real-browser desktop/mobile acceptance. This patch does not activate any utility or claim readiness.

## Separate admin/evidence integration

`src/admin.html` and `src/compd-manual.js` implement transaction-evidence review. The browser requests a wallet account and a `personal_sign` authentication message; it does not request a private key or sign/send a blockchain transaction. Message signing is not transaction signing and does not grant trading or treasury-spending approval.

`tools/manual-api.mjs` proxies a bounded allowlist of authentication, record submission and re-verification routes, including POST requests, to an optional credential-free loopback evidence service configured server-side through `COMPD_MANUAL_URL`. Session cookies are forwarded by the existing implementation. The backend must validate authentication and authorization; hiding admin UI alone is not access control. The repository does not supply or establish a deployed evidence backend.

This authenticated evidence path is distinct from read-only `/api/protocol/status` monitoring. Both integrations retain their existing logic. Public hosting, TLS and production security acceptance are outside this local frontend handoff. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for vendor licensing; COMPD first-party licensing awaits owner approval.
