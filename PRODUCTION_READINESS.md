# Production Readiness

This document is the release gate for Hiide. It is intentionally evidence-based: a checkbox is complete only when the linked CI run, test report, or release artifact proves it. “Production-ready” is not inferred from a successful compile alone.

## Current release status

**Status: NOT READY FOR GENERAL RELEASE.**

The most recent observed CI run before this update (2026-10-09, commit `0cd332bdd3fc76b03275125474358aec5b50b02d`) was not green:
- Flutter analysis passed, but the Flutter suite had 29 failing tests spanning widget rendering, stale test expectations, settings/model fixtures, agent file operations, and memory behavior. These failures need individual triage; do not skip tests or loosen assertions to obtain a green build.
- The Flutter↔Zig integration suite crashed the native engine during `agent.tool.execute` with `free(): double free detected in tcache 2`; the subsequent watch test then failed to connect because the engine had exited. The workspace-search ownership path was corrected, but that correction alone did not resolve the crash. A newer diagnostic commit is tracing process-tool cleanup, and the root cause remains unconfirmed.
- The Zig unit-test job was still running when the latest status was inspected, so its result is not yet verified.

The IPC dispatcher now rejects an explicitly supplied zero or negative `timeout_ms` instead of silently treating it as “use the default timeout”; a regression test covers the zero case. CI must validate this change. No build, test, integration, or release gate is considered passed without a successful result on the exact commit.

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
