# Security Policy

COMPD is experimental software and has not been represented as independently audited or production-ready.

## Do not use with real funds

Do not deploy these contracts or enable agent execution with real assets based only on this source. Reviewers should assume the code may contain vulnerabilities, incomplete integrations, stale assumptions, and historical prototypes.

## Reporting a vulnerability

Please do not publish exploitable details in a public issue. Contact the project maintainers privately through a verified contact channel listed on the project's GitHub profile. Do not include secrets, private keys, seed phrases, or personal data in a report.

## Public repository rules

Never commit:
- Private keys, seed phrases, keystores, passwords, or signing material.
- `.env` files, production RPC URLs containing credentials, API tokens, or auth cookies.
- Private server deployment files, production runtime state, logs, database files, backups, or customer data.

If a credential was committed at any point, deleting the file is not enough: revoke/rotate the credential and consider the full Git history exposed.

## Scope and limitations

Public source, CI checks, and unit tests are not a security audit. A green build is not evidence that a contract or agent is safe to operate.
