# Security

Please report vulnerabilities privately, never in a public issue or pull request.

Use GitHub's private reporting: the **Security** tab of this repository → **Report a vulnerability**. Include the
affected contract and function, the impact, and a proof of concept (a Foundry test is ideal).

We acknowledge reports within 72 hours and keep you informed until the issue is fixed.

## Scope

Everything in `src/`. Out of scope: issues only reachable by the factory admin (an OpenZeppelin `TimelockController`),
code in `lib/`, and findings in tests or scripts.
