# Hiide Agent OS

Hiide is an AI-native workspace. The `.hiide/` directory contains project-local
agent profiles and procedural skills.

## Agents

```text
.hiide/agents/
├── build.md
├── plan.md
├── explore.md
├── reviewer.md
├── security.md
└── tester.md
```

Profiles are policy declarations for humans and AI. The runtime is authoritative:
tool permissions are enforced in `AgentController`, so changing a Markdown
description cannot grant a tool that the runtime profile does not allow.

## Skills

```text
.hiide/skills/
├── code-change.md
├── testing.md
├── review.md
├── security.md
└── research.md
```

Skills are loaded on demand when their keywords match the current objective.
They are reference instructions, not executable permissions.

## Execution model

```text
User goal
  ↓
Build / Plan primary agent
  ↓
Native Zig workspace tools
  ↓
Task journal + artifacts + memory
  ↓
Parallel read-only specialists
  ├── Explore
  ├── Reviewer
  └── Security
  ↓
Final report
```

Only mutation-capable agents can write files. Specialist agents operate with
read-only toolsets and are safe to run concurrently against the same workspace.
