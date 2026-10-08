---
name: Safe Code Change
description: Surgical implementation workflow for AI-authored changes.
keywords: code, implement, feature, refactor, fix, bug, edit
---
# Safe Code Change

Inspect the workspace before changing it. Prefer the smallest targeted change.
Read adjacent interfaces and callers before changing public contracts.
After each meaningful mutation, verify the resulting state.
Keep unrelated files untouched.
Use the native agent file tools for every mutation.
Finish with focused tests and a concise evidence-based report.
