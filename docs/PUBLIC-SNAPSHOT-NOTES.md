# Public snapshot notes

This monorepo combines the public-facing interface, selected agent observation/research code, and protocol source from three private exports.

## Intentionally excluded

To avoid publishing server/operator deployment material in the public repository, this snapshot excludes private VPS deployment instructions, service unit files, operational configuration bundles, transaction/deployment helper tooling, executor/keeper scripts and related runbooks. These omissions mean this is not a drop-in replacement for the private server repositories.

## Validation performed during packaging

- Scanned the assembled text files for common credential/token patterns and sensitive key/database file extensions; no matches were found by the packaging scan.
- Interface JavaScript checks, tests, and build were run. One integrity test initially reported that `src/vendor/README.md` differed from its stored hash; the README was reviewed as third-party license/provenance documentation and the baseline hash was updated to the current included file.
- Agent dashboard and xStocks observation tests were run.
- Foundry was not installed in the packaging environment, so Solidity build/tests were not run here.

This is a best-effort source review, not a guarantee that all content is safe or a security audit. Review the full diff and scan the repository again before publishing. If any secret has ever existed in the source history, revoke/rotate it and do not publish that history.
