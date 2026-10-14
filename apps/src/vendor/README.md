# Vendored libraries

Local library copies; these libraries require no CDN request. Application observation/evidence API requests are separate.

| File | Source | License |
| --- | --- | --- |
| `three-subset.min.js` | three@0.186.1, tree-shaken to the classes in `three-subset.entry.mjs` | MIT, see `three.LICENSE` |
| `gsap.min.js` | gsap@3.15.0 `dist/gsap.min.js` | GSAP Standard "no charge" license, https://gsap.com/standard-license |
| `ScrollTrigger.min.js` | gsap@3.15.0 `dist/ScrollTrigger.min.js` | same |

Rebuild the Three.js subset:

    npm i esbuild three@0.186.1
    npx esbuild three-subset.entry.mjs --bundle --minify --format=esm --legal-comments=inline --outfile=three-subset.min.js

## Redistribution and provenance boundaries

Preserve `three.LICENSE` and the Three.js bundle notices. Preserve GSAP and ScrollTrigger's original proprietary headers, author attribution and official license URL. Their Standard License permits commercial website/application use but restricts competing visual-animation-builder uses and alteration/removal of proprietary notices. It is not MIT and is not overridden by any future COMPD root license.

Versions above are recorded in the existing vendor documentation/headers; this cleanup does not independently authenticate release-package bytes. See [../../THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md) for canonical licensing sources and remaining public-release decisions. Rebuild commands are historical developer instructions, not a request to update dependencies during this cleanup.
