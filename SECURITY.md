# Security Policy

## Scope

Hiide is a local agent-native development workspace with file, process, provider, plugin, task-journal, and IPC surfaces. Security reports should include enough detail to reproduce the issue without exposing real secrets or private workspace contents.

## Reporting

For a private report, use GitHub's repository security reporting / private vulnerability reporting feature when it is enabled for this repository. Do not publish credentials, API keys, tokens, private source, or proof-of-concept payloads in a public issue.

## Development requirements

Security-sensitive changes must preserve these invariants:

- workspace paths remain confined to the configured workspace;
- external/network/process capabilities require explicit mediation;
- IPC input is bounded and malformed frames are rejected safely;
- secrets and provider credentials are never committed to the repository;
- tests cover both the failure path and the successful path for new security controls.


## Agent execution controls

The desktop agent is intentionally separated into two layers:

- Flutter owns the model conversation, task UX, approval dialog, transcript and artifact presentation.
- The Zig engine owns workspace path validation and the final IPC tool boundary.

Shell/process execution is approval-gated in the UI and requires an explicit
approval field at the native IPC boundary. Workspace file tools reject absolute
paths, traversal, and existing symlink components that would cross the workspace
root.

Task history is bounded and locally persisted. Transcripts and artifacts are
truncated before persistence so a runaway model response cannot grow the local
journal without limit.

The native framework also contains policy, audit, journal, cancellation and
budget components for higher-level orchestrated execution. These controls
should remain fail-closed when new agent tools or capabilities are introduced.