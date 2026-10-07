# Production Readiness

This document is the release gate for Hiide. It is intentionally evidence-based: a checkbox is complete only when the linked CI run, test report, or release artifact proves it. “Production-ready” is not inferred from a successful compile alone.

## Current release status

**Status: NOT READY FOR GENERAL RELEASE.**

The repository has automated Zig, Flutter, and Flutter↔Zig checks, but the most recent observed CI run (2026-10-07) failed:
- Zig unit tests and native builds stopped at a syntax error in `src/core/editor/editor.zig`. The newline escaping has since been corrected; the next CI run must confirm this fix.
- Flutter analysis passed, but the Flutter test suite reported multiple failures across widget rendering, retry mechanics, provider/model expectations, agent tools, and workspace behavior. These failures must be triaged and fixed, not hidden by weakening or skipping tests.
- The native integration suite could not build because it shares the Zig compile failure. It must pass after the compiler issue is resolved.

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
