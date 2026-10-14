# COMPD Frontend Handoff

## What is included

This package contains the current public COMPD frontend source: Home, Treasury, Agent, Flow, Protocol, Docs, and Paper Workspace. It includes current shared navigation/footer markup, mobile navigation, active CSS and JavaScript, the COMPD logo/favicon/touch icon assets, route configuration, a zero-dependency build, a loopback-only local server, optional observation/evidence API projections, a separate admin interface, and an opt-in in-memory Paper Workspace preview.

Backend implementations, contracts, production deployment/configuration, credentials and persistent runtime state are not included. Frontend tests, local fixtures, provenance metadata and vendored browser libraries are included. Optional backend integration does not establish a deployed service, verified holder check, live market feed, order execution or transaction submission.

## Project structure

- src/ — current page and frontend source files.
- tools/dev-server.mjs — local static server and local mock API.
- tools/build.mjs — copies the allowlisted frontend into dist.
- test/handoff.test.mjs — clean local route and mock API smoke tests.
- site.config.mjs — source file allowlist, route map, and market labels.
- package.json and package-lock.json — reproducible Node package metadata; no declared npm dependencies. Vendored third-party browser libraries are included separately.
- HANDOFF.md — integration and modification guidance.
- EXTERNAL-UI-RETURN.md — source-return instructions.

## Install, run, build, and test

Requirements: Node.js 20 or newer and npm.

Run these commands from the extracted root:

npm ci
npm run dev

Open http://127.0.0.1:4173/ . The server listens on loopback. Optional PORT selects a different local port.

Build:

npm run build

Preview the built frontend:

npm run preview

Run the handoff checks:

npm test

The ZIP contains source only; dist and node_modules are generated locally and are not part of the archive.

## Styles, components, and assets

Global public-site styles are in src/compd-system.css. Paper Workspace-specific styles are in src/paper-workspace.css. Flow-specific responsive layout and animation styles are in src/flow-page.css.

Shared header, responsive menu, and footer markup are currently authored in each page HTML file. Shared menu behavior is in src/compd-shell.js. There is no component framework; locally vendored Three.js, GSAP and ScrollTrigger support the browser presentation.

Each page lives at the source root:

- src/index.html — Home.
- src/treasury.html — Treasury and buyback policy.
- src/agent.html — Agent overview.
- src/flow.html — interactive capital-flow architecture.
- src/protocol.html — Protocol overview.
- src/docs.html — public Docs.
- src/app.html — Paper Workspace.

Current brand images are src/compd-stack-mark.png, src/compd-favicon-32.png, and src/compd-touch-icon-180.png. No local font files or external font downloads are required. The CSS names DM Sans, DM Mono, and Playfair Display where available, with system/browser fallbacks.

## Flow implementation

Flow is a tabbed set of diagrams in src/flow.html, built by src/flow-page.js (SVG ribbons, no extra libraries) and styled in src/flow-page.css. Revenue, Strategy and Buyback tabs are keyboard-accessible. Each diagram is a row of cards joined by sankey bands; the cards rise in, the bands fade in, then dots travel at one even pace. Band thickness follows each allocation and each dot is 1% of the flow shown, never a token or amount. Hovering or selecting a node lights its path and updates the detail text. Reduced motion shows the diagrams without moving dots; without JS the step text still reads. The diagrams contain no live values and make no provider or production-execution claim. The burn destination is explicitly conceptual because its production destination/mechanism is not confirmed in the public frontend.

Displayed allocation values reflect the current approved public specification: Protocol/Flap revenue 35/15/50 and positive realized strategy profit 65/15/10/10 (strategy/buyback/holders/protocol). Treat policy values and explanatory copy as approved product content; get integration review before changing their meaning.

## Paper Workspace and data layer

src/app.html contains the existing Paper Workspace browser UI and its same-origin API client. It requests:

- GET /api/health
- GET /api/assets
- GET /api/eligibility?address=...
- POST /api/paper/runs
- GET /api/paper/runs/:id
- POST /api/paper/runs/:id/pause
- POST /api/paper/runs/:id/resume
- POST /api/paper/runs/:id/stop

The local server provides unavailable-data responses by default. Paper-run endpoints are disabled unless explicitly started with the local `--paper-demo` option; that preview uses in-memory waiting-for-data state. The eligibility response accepts a syntactically valid demo address and does not inspect a wallet or token. It is not a real holder check. Market responses intentionally have no quote, deployment, or provider timestamp, so the UI correctly reports unavailable pricing and holds runs in a data-wait state. Paper-run controls only change local in-memory mock state; they cannot place an order or send a blockchain transaction. The mock stores no wallet address and logs no request payloads.

The mock preserves response shapes needed by the current UI, not production service behavior. The original private backend strategy implementation is not included. Consult API-CONTRACT.md before replacing the mock with an integration.

## Safe frontend work

The page HTML, responsive layout, CSS, icons, keyboard interactions, and non-economic presentation are frontend-owned areas suitable for UI/UX iteration. Keep the mock local and clearly labeled. Keep pages and shared navigation links in sync.

Do not change the API paths or response fields used by Paper Workspace without backend integration review. Do not describe mock output as a live quote, verified holder result, strategy outcome, treasury balance, buyback, or burn. Do not change approved economics, protocol policy, production status, addresses, or execution semantics as part of visual work. No production address, private credential, signer material, or RPC secret belongs in this package.

The source refers to DM Sans, DM Mono, and Playfair Display only through CSS font stacks. If those fonts are unavailable on the developer machine, browser fallback fonts are expected; no font service is contacted by this package.

## Landing page (index.html) — added dependencies

The landing page is a hero plus five full-screen chapters (Agent, Treasury, Flow, Protocol, Docs) and a closing link to the Paper Workspace. A fixed Three.js particle scene sits behind it. The scene is a conceptual illustration: no values, no balances, no live data.

- src/landing.css, src/landing.js — landing styles and scroll/stage logic. src/compd-atmosphere.css, src/compd-scene.js — shared atmosphere and particle scene, reused by other pages.
- src/vendor/ — local copies of three (MIT, tree-shaken subset), gsap and ScrollTrigger (GSAP Standard "no charge" license). No CDN and no runtime network request. See src/vendor/README.md for versions and the rebuild command.
- Review before shipping: the GSAP license terms for the production site, and the added dependency surface (about 520 KB Three.js subset, loaded after first paint).
- Text and links are visible without JS. With prefers-reduced-motion or without WebGL the scene does not start and a static SVG shows instead. Particle count and pixel ratio drop automatically on slow devices.
- Only the landing header CTA reads "See how it works" (flow.html). Other pages keep "Open paper workspace".

## Monitoring, admin integration and licensing

`GET /api/protocol/status` provides read-only observation projection. The separate admin/evidence interface requests wallet message signatures and uses authenticated POST routes to submit/re-verify existing transaction hashes. It does not sign or submit blockchain transactions, activate Agent trading or release treasury funds. See [INTEGRATION.md](INTEGRATION.md) and [API-CONTRACT.md](API-CONTRACT.md) for the boundaries; no deployed observer or evidence service is supplied here.

COMPD first-party root licensing awaits explicit owner approval. Preserve the existing Three.js MIT license and the proprietary GSAP/ScrollTrigger notices and restrictions documented in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). No executable logic, build configuration, economics or production state changed in this documentation cleanup.
