---
name: Verification and Testing
description: Project-aware verification workflow.
keywords: test, testing, verify, build, compile, lint, analyze, ci
---
# Verification and Testing

Identify the smallest relevant verification commands first.
Run focused checks before the broad suite when practical.
Read failures completely, fix the root cause, then rerun the failed check.
Do not report PASS unless the command actually completed successfully.
Record the exact commands and their outcome.
