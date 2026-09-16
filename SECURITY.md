# Security Policy

## Scope

Hiide is a local IDE/agent runtime with file, process, provider, plugin, and IPC surfaces. Security reports should include enough detail to reproduce the issue without exposing real secrets or private workspace contents.

## Reporting

For a private report, use GitHub's repository security reporting / private vulnerability reporting feature when it is enabled for this repository. Do not publish credentials, API keys, tokens, private source, or proof-of-concept payloads in a public issue.

## Development requirements

Security-sensitive changes must preserve these invariants:

- workspace paths remain confined to the configured workspace;
- external/network/process capabilities require explicit mediation;
- IPC input is bounded and malformed frames are rejected safely;
- secrets and provider credentials are never committed to the repository;
- tests cover both the failure path and the successful path for new security controls.
