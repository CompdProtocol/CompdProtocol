# Third-party notices

COMPD first-party root licensing is awaiting explicit owner approval. No root LICENSE has been created. The following vendored components retain their own terms; none is relicensed by COMPD.

## Three.js

`src/vendor/three-subset.min.js` is a tree-shaken Three.js bundle. The existing vendor record identifies three@0.186.1; this cleanup does not claim independent release-byte verification or rebuild it. The entry point is `src/vendor/three-subset.entry.mjs`.

The retained [three.LICENSE](src/vendor/three.LICENSE) contains the MIT license and Copyright © 2010-2026 three.js authors, consistent with the [canonical upstream license](https://github.com/mrdoob/three.js/blob/dev/LICENSE). Preserve the copyright and permission notice when redistributing copies or substantial portions. The license, bundle and entry point are unchanged.

## GSAP and ScrollTrigger

The bundled headers identify GSAP 3.15.0 and ScrollTrigger 3.15.0, Copyright 2026, GreenSock. All rights reserved, with Jack Doyle attribution and the official license URL. Those proprietary notices remain intact. Version identification comes from existing headers/vendor documentation; it is not a new verification of release-package authenticity.

Both are governed by the [GSAP Standard No Charge License](https://gsap.com/community/standard-license/), not MIT or Apache-2.0. The official terms permit use, reproduction, display and implementation for permitted website, web-application and digital-interface uses, including commercial projects. They restrict uses in competing visual-animation-building tools, reverse engineering to create competitive products, and removal or alteration of proprietary notices or branding. No-charge use is not an unrestricted open-source redistribution grant.

Keep the original headers and license link. Review redistribution and intended use against the applicable release terms before publication; do not assume COMPD's eventual root license covers these files. The referenced official terms identify an effective date of April 30, 2025 and last modification May 30, 2025. No third-party license text has been reconstructed or attributed to a guessed owner.

## COMPD material and public-release gates

Owner approval must establish the first-party license and rights to supplied code, documentation and visual assets. Third-party terms remain separate, and a copyright license does not imply permission to use brand trademarks. Historical personal-author metadata exposure also requires resolution or explicit acceptance before public release.

Local vendoring removes the need for a CDN request for these libraries; the application can separately request its same-origin observation/evidence APIs. This repository supplies no approved production deployment or live trading service.
