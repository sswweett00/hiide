# Production Readiness

This document is the release gate for Hiide. It is intentionally evidence-based: a checkbox is complete only when the linked CI run, test report, or release artifact proves it. “Production-ready” is not inferred from a successful compile alone.

## Current release status

**Status: NOT READY FOR GENERAL RELEASE.**

The latest observed failing CI baseline (2026-10-09, run [37933687502](https://github.com/sswweett00/hiide/actions/runs/37933687502), commit `ad22378019d1089d726f63ccb5333844aca9a5aa`) was not green:
- Flutter analysis passed, but the Flutter suite reported 29 failing tests spanning widget layout, stale model/mode expectations, settings fixtures, agent mutation/verification flow, task persistence, and memory prioritization.
- The Flutter↔Zig integration suite crashed the native engine during `agent.tool.execute` with `free(): double free detected in tcache 2`; the subsequent watch test then failed to connect because the engine had exited. The earlier workspace-search ownership correction did not resolve this crash. Its root cause is still unconfirmed.
- The Zig unit-test job was still running when its status was inspected, so that result was not verified.

### Changes since the failing baseline — awaiting CI evidence

The following changes have landed on `main`, but they are **not considered verified until CI completes successfully on the exact commit**:
- Persist IPC authentication state across requests on a single TCP connection, and add a regression test for the authenticated hello-then-ping sequence.
- Do not trust an already-running loopback service unless the application inherited its session token; the supervisor starts its own token-protected engine otherwise.
- Parse process approval flags through a typed, fail-closed decoder.
- Prioritize keyword-matched conversation memory ahead of oversized project notes so bounded context retains relevant information.
- Require Zig tests, Flutter analysis/tests, and real Flutter↔Zig integration tests to pass before the Linux release workflow builds or publishes packages.
- Correct stale test fixtures and add post-mutation verification calls where the agent loop requires them.

The IPC dispatcher also rejects explicitly supplied zero or negative `timeout_ms` values instead of silently using a default. The latest observed CI run for the newer changes is still pending/in progress. No build, test, integration, security, or release gate is considered passed without a successful result on the exact release commit.

## Release-blocking gates

### Build and tests
- [ ] Zig unit tests pass on the pinned Zig version.
- [ ] Debug and ReleaseSafe native builds pass, including all shipped executables.
- [ ] Flutter analysis has no errors and the full Flutter test suite passes.
- [ ] Flutter↔Zig IPC integration tests pass on a clean runner.
- [ ] Test coverage includes malformed IPC frames, size limits, disconnects, cancellation, approval rejection, path traversal, symlink escapes, process timeout, and recovery from partial failures.
- [ ] CI is green on the exact release commit; no failed or skipped required job is unexplained.

### Security and privacy
- [ ] Review all filesystem operations against symlink races and workspace-root escapes.
- [ ] Confirm process execution is fail-closed at the native boundary and cannot be invoked by bypassing UI approval.
- [ ] Confirm IPC binds only to loopback, rejects oversized/malformed messages, and does not expose unauthenticated dangerous methods to other local users/processes.
- [ ] Run secret scanning and dependency vulnerability checks; rotate any credential ever committed.
- [ ] Keep local agent history, raw provider payloads, local configuration, caches, and generated state out of version control.
- [ ] Document data retention, provider data handling, telemetry defaults, and deletion/export behavior.

### Release engineering
- [ ] Provide reproducible build instructions and clean-machine smoke tests.
- [ ] Produce versioned release artifacts for every supported platform; document currently unsupported platforms.
- [ ] Define signing/notarization, checksums, provenance, and a release rollback procedure.
- [ ] Define crash reporting/logging behavior without leaking prompts, credentials, or workspace contents.
- [ ] Verify first-run setup, missing-engine behavior, port conflicts, offline behavior, provider misconfiguration, and graceful shutdown.
- [ ] Test upgrade compatibility for settings, task journal, and workspace metadata.
- [ ] Publish known limitations and support/security contact details.

## Release procedure

1. Fix the failing tests and add regression tests for each discovered defect.
2. Run the complete CI suite from a clean checkout.
3. Build release artifacts from the exact green commit.
4. Perform a clean-machine install and smoke test for every supported target.
5. Review the security checklist and scan results.
6. Tag and publish only the verified commit; retain checksums and build metadata.
7. Monitor the first release and keep a documented rollback path.

Do not mark this project production-ready until every release-blocking gate above has evidence.
