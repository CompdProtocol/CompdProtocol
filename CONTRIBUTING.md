# Contributing to COMPD

Thank you for your interest in contributing to COMPD.

COMPD brings together protocol infrastructure, an autonomous agent framework, and a public-facing interface. We welcome thoughtful contributions that improve reliability, transparency, security, and developer experience.

## Getting Started

1. Review the repository README and relevant component documentation.
2. Fork the repository and create a dedicated branch for your changes.
3. Keep modifications focused on the relevant component.
4. Run applicable tests and validation checks.
5. Open a Pull Request with a clear description of your changes.

## Repository Structure

| Component | Directory | Scope |
|---|---|---|
| Interface | `apps/interface/` | Frontend, user experience, and application integration |
| Agent | `packages/agent/` | Agent logic, execution safeguards, and supporting modules |
| Protocol | `packages/protocol/` | Smart contracts, protocol accounting, and testing |
| Documentation | `docs/` | Architecture, technical references, and developer guidance |

## Development Guidelines

- Keep changes focused, readable, and maintainable.
- Follow existing project conventions and architecture.
- Add or update tests when modifying behavior.
- Avoid introducing unnecessary dependencies.
- Document new features, configuration requirements, and limitations.
- Clearly distinguish experimental functionality from production-ready components.

## Protocol Contributions

Changes involving smart contracts require additional care.

- Include relevant Foundry tests and regression coverage.
- Explain changes to authorization, accounting, storage, and external calls.
- Identify any impact on treasury operations, rewards, or settlement.
- Do not assume local or fork tests establish production security.
- Never modify production deployment assumptions without explicit review.

## Agent Contributions

Agent-related changes must preserve established safety boundaries.

- Maintain the documented execution and risk controls.
- Do not bypass market-data freshness, validation, or trading safeguards.
- Do not present simulations or test fixtures as live trading results.
- Do not enable real trading or production execution through an unreviewed contribution.
- Document changes to agent behavior, execution paths, and failure handling.

## Pull Request Guidelines

Each Pull Request should include:

- A concise summary of the proposed change.
- The affected components.
- Relevant testing and validation results.
- Any known limitations or remaining risks.
- Documentation updates when applicable.

Large architectural changes should be discussed before implementation.

## Security and Privacy

Never commit private keys, API credentials, production environment files, sensitive operational configuration, or private user data.

Security vulnerabilities should be reported through the process described in [SECURITY.md](SECURITY.md), not through public issues containing exploit details.

## Responsible Development

COMPD prioritizes verifiable behavior over unsupported claims.

Contributors should clearly identify what has been implemented, what has been tested, and what remains experimental or unverified.

Thank you for helping build COMPD.
