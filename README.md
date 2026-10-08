# Hiide

Hiide is an **AI-native software development workspace**. It is intentionally **not a human code editor**.

Users give Hiide a goal. The agent reads the workspace, plans changes, executes approved tools, verifies the result and records the task history. Humans review plans, tool output, diffs and verification evidence; source files are not manually edited inside Hiide.

## Product model

- **AI-only source mutation** — file changes are performed by the agent through the native tool boundary.
- **Read-only workspace context** — Explorer and Search expose files as context targets; they never open an editable source surface.
- **Agent workspace** — tasks, plans, approvals, tool activity, artifacts and verification live in one AI-native surface.
- **Local execution** — the Zig engine runs on the user machine and owns workspace access, sandboxing, file tools, process execution and file watching.
- **BYOK** — users provide their own AI provider credentials; Hiide does not require a hosted Hiide application backend.
- **Local models** — Ollama, LM Studio and vLLM can run entirely on the user machine.
- **Change review** — diff and merge views remain review surfaces for changes produced by the agent, not editing surfaces.

## Architecture

| Layer | Responsibility |
|---|---|
| Agent workspace | Goal-first AI workflow, task history and evidence |
| Agent loop | Tool-calling orchestration, retries, cancellation and verification |
| Task journal | Persistent task state, transcript, artifacts and timeline |
| Approval | Explicit approval for dangerous process execution |
| Zig engine | Workspace tree/search, file watching, tool registry, sandboxing and native process execution |
| Flutter frontend | Product UI, model conversation, task visualization and settings |
| IPC | Local NDJSON JSON-RPC bridge on `127.0.0.1:4879` |

### Local runtime

The desktop application starts by connecting to `127.0.0.1:4879`. When nothing is listening, it locates and starts the packaged `hiide-ipc-server` executable.

There is no remote Hiide backend in the production architecture:

```text
Hiide Desktop
  ├── Flutter UI
  ├── Local Zig engine
  └── User-selected AI provider
        ├── Cloud API (BYOK)
        └── Local model runtime
```

The user project files stay on the local machine unless an AI provider receives the relevant context required for a request.

## Agent tools

The native engine exposes the agent with real filesystem and process operations:

- `file.read`
- `file.write`
- `file.apply_diff`
- `file.delete`
- `file.mkdir`
- `file.list`
- `workspace.search`
- `process.run`

The Flutter agent loop can read, change and verify the workspace only through this tool boundary. Path traversal is rejected by the native sandbox, and dangerous process execution is approval-gated.

## AI providers / BYOK

The provider-neutral runtime supports the built-in OpenAI-compatible catalog plus a native Anthropic implementation. Current built-in endpoints include:

Groq, OpenAI, OpenRouter, DeepSeek, Mistral, Together AI, Fireworks AI, Perplexity, xAI/Grok, Google Gemini, Cerebras, Cohere, NVIDIA NIM, SambaNova, DeepInfra, Hugging Face, Qwen/Alibaba Cloud, SiliconFlow, Novita AI, Baseten, FriendliAI, AI21 Labs, OpenCode Zen, Azure OpenAI/Foundry and LiteLLM.

Local/self-hosted endpoints include:

- Ollama
- LM Studio
- vLLM

Users can also register custom OpenAI-compatible endpoints.

Provider API keys and provider-specific models are stored separately in desktop settings. Provider fallback never reuses another provider model ID.

## Linux distribution

Hiide can be shipped as a **single self-contained Linux application**. The package contains both the Flutter desktop application and the native Zig engine, so users do not install or download a separate Hiide backend.

Build the packages locally:

```sh
bash scripts/package-linux.sh
```

The script produces:

```text
dist/
├── hiide_<version>_<arch>.deb
└── Hiide-<version>-<arch>.AppImage
```

The `.deb` includes desktop integration and installs a `hiide` launcher. The AppImage includes the same Flutter bundle and `hiide-ipc-server`.

Pushing a tag such as `v1.0.0` runs `.github/workflows/linux-packages.yml`, verifies that both packages contain the native engine, uploads artifacts and publishes the packages as GitHub Release assets.

## Development requirements

- Zig 0.16.0
- Flutter 3.44.0 / Dart >= 3.12.0
- Linux for the native desktop engine path

Development:

```sh
scripts/dev.sh
```

Manual:

```sh
zig build
./zig-out/bin/hiide-ipc-server
cd flutter_app
flutter run -d linux
```

Tests:

```sh
zig build test
cd flutter_app && flutter test
cd flutter_app && flutter test test/hiide_backend_integration_test.dart
```

## Security boundary

The Flutter UI is not the final authority for filesystem operations. The native Zig engine is the enforcement boundary for:

- workspace-root sandboxing
- path traversal rejection
- tool dispatch
- process execution
- process timeouts
- dangerous-action approval tokens

This keeps the AI-native rule enforceable below the UI layer.

## Project layout

- `src/` — native Zig engine
- `flutter_app/` — active Flutter desktop application
- `packaging/linux/` — desktop metadata and AppImage launcher
- `scripts/package-linux.sh` — self-contained Linux package builder
- `.github/workflows/linux-packages.yml` — automated Linux release packaging
- `ENTERPRISE_IDE_SPEC.md` — architecture and delivery specification

The key design constraint is deliberate: **Hiide is an AI workspace, not a source-code editor.**
