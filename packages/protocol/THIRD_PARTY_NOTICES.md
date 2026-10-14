# Third-party notices

COMPD first-party root licensing is awaiting explicit owner approval. No root LICENSE has been granted by this cleanup. Third-party files retain their own terms; this notice does not relicense them.

## Verified pinned source

The immutable upstream snapshot is [flap-sh/FlapVaultExample at 5949cc7eb99bcb5ac5f679cc710ae456e627f12a](https://github.com/flap-sh/FlapVaultExample/tree/5949cc7eb99bcb5ac5f679cc710ae456e627f12a). All 31 included forge-std source files, the vendored OpenZeppelin interface and all eight `src/flap/` files matched that snapshot byte-for-byte during the licensing audit. This establishes source provenance, not deployment or security qualification.

| Included component | Terms and attribution | Preserved license |
|---|---|---|
| `lib/forge-std/src/` | MIT OR Apache-2.0; Copyright Contributors to Forge Standard Library | [LICENSE-MIT](lib/forge-std/LICENSE-MIT) and [LICENSE-APACHE](lib/forge-std/LICENSE-APACHE) |
| `vendor/openzeppelin-contracts-upgradeable/access/IAccessControlUpgradeable.sol` | MIT; Copyright (c) 2016-2023 zOS Global Limited and contributors, as recorded in the accompanying pinned license | [LICENSE](vendor/openzeppelin-contracts-upgradeable/LICENSE) |
| Eight files in `src/flap/` | MIT SPDX headers retained; authoritative copyright/attribution clarification remains unresolved | No Flap license or copyright notice invented |

License files were copied without edits from:

- [forge-std MIT](https://github.com/flap-sh/FlapVaultExample/blob/5949cc7eb99bcb5ac5f679cc710ae456e627f12a/lib/forge-std/LICENSE-MIT), Git blob `28f98304ac6db414af24a4e9cb31407dd524329f`.
- [forge-std Apache-2.0](https://github.com/flap-sh/FlapVaultExample/blob/5949cc7eb99bcb5ac5f679cc710ae456e627f12a/lib/forge-std/LICENSE-APACHE), Git blob `cf01a499fbc56499b51f087c7cad0cec85fabaaa`.
- [OpenZeppelin](https://github.com/flap-sh/FlapVaultExample/blob/5949cc7eb99bcb5ac5f679cc710ae456e627f12a/lib/openzeppelin-contracts-upgradeable/LICENSE), Git blob `817249a0cd2ec1bb1c3d15ed0166f97903e94557`.

For MIT redistribution, preserve the applicable copyright and permission notices. Apache-2.0 redistribution requires its license, retained applicable notices, notices of modifications and any applicable upstream NOTICE attribution. The SPDX expression offers alternatives; preserving both texts retains upstream's dual-license presentation.

## Flap clarification required

The pinned snapshot contains no project-level LICENSE, NOTICE or COPYING for the eight included Flap files. Its dependency license files do not supply a Flap copyright holder. Obtain authoritative clarification before public release; do not infer a holder or year from the organization name. Existing SPDX headers and source bytes remain unchanged.

## Installed dependencies

`package.json` separately declares OpenZeppelin Contracts 5.6.1 and ethers 6.17.0. Their source is not vendored here through `node_modules`. Retain the license files/notices shipped with the actual installed packages when redistributing their source or incorporating it into distributable artifacts. The pinned vendored OpenZeppelin interface and its license must not be confused with the npm dependency version.

## Publication status

Public release remains blocked on Flap attribution clarification, owner approval of COMPD first-party licensing and resolution or explicit acceptance of historical personal-author metadata exposure. Neither this notice nor the restored licenses authorize deployment or trading.
