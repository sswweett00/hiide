# hiide

AI-native IDE built around a Zig core engine and a Flutter frontend. The Zig
engine handles all performance-critical work (gap buffer editor, Myers diff,
workspace grep, file watching, agent tool execution); the Flutter IDE renders
the UI and communicates with the engine over a local JSON-RPC socket.

> **Note:** The README also documents the Tauri desktop shell (`apps/`) and
> Hiditor Rust editor (`frontend/`) as planned components. Those directories
> are not present in this checkout; the active UI is the Flutter app.

## Requirements

- **Zig ≥ 0.14.0** (the build uses `b.addLibrary` which was introduced in 0.14)
- **Flutter ≥ 3.44.0** / Dart ≥ 3.12.0
- Linux (native file watcher uses inotify; other platforms use a polling fallback)

## Layout

- `ENTERPRISE_IDE_SPEC.md`: authoritative architecture and delivery specification
- `docs/egui-ide-design-spec.md`: egui frontend UI specification with Hiditor custom editor architecture
- `build.zig`: Zig build graph for the engine library and all executables
- `src/`: Zig engine modules
- `flutter_app/`: Flutter IDE frontend (the active UI), wired to the Zig engine
- `examples/`: standalone Zig demos (agent, Groq coder)
- `scripts/`: dev launcher and build helper

## Flutter ⇄ Zig Wiring

The Flutter IDE talks to the native engine over **newline-delimited JSON-RPC** on
`127.0.0.1:4879` (`hiide-ipc-server`). All performance-critical work happens in
Zig — the Flutter UI only renders:

| Area | Zig engine (`src/core/ipc/server.zig`) | Flutter client |
|------|----------------------------------------|----------------|
| Editor buffer (gap buffer, undo/redo) | `editor.load/get_text/insert/delete/undo/redo/line_count/size/search/highlight/destroy` | `HiideBackendService` + `EditorSession` |
| Editor keystroke sync | `editor.apply_text` (minimal edit computed natively in UTF-8 bytes) | `EditorSession.syncChange` |
| Editor gutter diff | `editor.diff_lines` (native Myers line diff vs on-disk reference → modified/added/deleted regions) | `EditorSession.diffAgainstDisk` → gutter markers |
| Workspace grep | `workspace.search` (recursive, case-insensitive, skips junk dirs) | `SearchScreen` |
| Workspace tree | `workspace.tree` (single-pass enumeration, dirs-first sorted, relative paths + sizes) | `fileTreeProvider` → Explorer / Quick Open |
| File watching | `watch.subscribe` / `watch.unsubscribe` — inotify-triggered (Linux) / periodic-rescan fallback; pushes `fs.change` events (created / modified / deleted) | `fsChangeStream` → auto-refresh tree + reload open tabs |
| Agent tools | `agent.tool.execute` → framework `Tool` registry (`file.read/write/apply_diff/list`, `process.run`, `workspace.search`) | `AgentController` via `BackendService.executeAgentTool` |
| Handshake | `hello` (service + version), `ping` | `HiideBackendService.connect()` |

How it fits together:

- `lib/core/backend/backend_service.dart` defines the `BackendService` contract;
  `hiide_backend_service.dart` is the real TCP client, `mock_backend_service.dart`
  is the offline fallback (`main.dart` tries the engine first, then falls back).
- `lib/core/backend/editor_session.dart` bridges each open tab to the engine's
  gap buffer: every keystroke is turned into minimal `editor.delete`/`editor.insert`
  ops (code-unit → UTF-8 byte offsets handled by `text_diff.dart`), and saving
  writes the exact bytes the engine holds.
- `fsWatcherProvider` subscribes to the engine's native file watcher
  (`watch.subscribe`); on every `fs.change` event it refreshes the workspace
  tree and reloads open, unmodified tabs whose file changed on disk (engine
  buffer reconciled so a later save writes the fresh content).
- `SearchScreen` greps through the Zig engine; the old Dart scan remains as the
  offline fallback.

### Run the full stack

```sh
scripts/dev.sh          # build engine + start IPC server + flutter run
```

Or manually:

```sh
zig build
./zig-out/bin/hiide-ipc-server &   # listens on 127.0.0.1:4879
cd flutter_app && flutter run -d linux
```

### Tests

```sh
zig build test                                                  # engine unit tests
cd flutter_app && flutter test                                  # widget + render + unit
cd flutter_app && flutter test test/hiide_backend_integration_test.dart   # real e2e: Dart ⇄ Zig
```

## AI-Native Agent (chat + editor)

The Flutter chat sidebar runs a **real agentic loop** over Groq's native
function calling — no prompt-hacking, no ` ```tool_call``` ` marker parsing.
The loop (LLM calls + message history) lives in Dart, but **every tool call is
executed inside the Zig engine** through the agent framework's `Tool` registry:

- The model calls tools (`read_file`, `write_file`, `apply_diff`,
  `list_directory`, `run_command`, `search_workspace`) and the engine executes
  them via `agent.tool.execute`, feeding each result back as a `role: 'tool'`
  message until the model stops or the user hits **Stop** (iteration budget
  guards runaway loops).
- Engine-side tools (`src/core/agent/framework/`): `file.read`, `file.write`,
  `file.apply_diff`, `file.list`, `process.run`, `workspace.search` — all
  running under the framework's workspace sandbox (paths escaping the root are
  rejected) with a watchdog-killed `process.run` timeout.
- `run_command` returns the actual stdout/stderr to the model (and echoes it
  to the Terminal panel), so the agent can build → run tests → fix → re-run.
- `search_workspace` greps through the Zig engine, with an offline local-scan
  fallback.
- Live tool cards show each call as it runs (spinner → result); files the
  agent edits refresh open editor tabs automatically.
- The editor toolbar has **Ask AI** actions — *Explain selection*,
  *Improve selection*, *Find problems in file* — which inject the current
  selection into the agent loop.
- Offline (engine not running) the mock backend executes the same tools
  locally, so the agent still works.

## Native (Zig) critical paths

Everything performance-critical runs in the engine, never in Dart:

- **Editor buffer** — gap buffer, undo/redo, search, and highlight in
  `src/core/editor/`; the keystroke path is a single `editor.apply_text` call
  whose minimal edit (common prefix/suffix) is computed natively in bytes.
- **Gutter change markers** — `src/core/editor/diff.zig` runs a native Myers
  line diff (bounded trace + coarse fallback for huge rewrites) comparing the
  buffer against the on-disk reference; `editor.diff_lines` returns sparse
  regions and the editor paints amber/green/red bars per line. Recomputed
  debounced on typing, cleared on save, refreshed on external reloads; a
  Dart mirror (`lib/core/backend/line_diff.dart`) covers offline mode.
- **Minimap** — a whole-file overview strip next to the line numbers: diff
  regions tinted with the same colors, the caret line and the visible
  viewport highlighted; tap or drag to jump the editor to that line
  (`CustomPaint`, repaints only on scroll/caret/diff changes).
- **Editor scroll sync** — every text line is exactly 28px (strut-forced, so
  line numbers stay aligned with the code) and the text field, line-number
  gutter and minimap scroll in lockstep via linked controllers.
- **AI chrome** — the status bar and chat header show the **live Groq
  connection** (probed against the API, not assumed): `AI: Ready`/`AI:
  Offline`/`AI: Checking…` + engine dot; the chat sidebar shows a retryable
  offline banner with the exact reason and opens with a welcome panel of
  suggested prompts (explain / fix / test / optimize the active file).
- **AI-native design language** — a single aurora identity runs through the
  whole app: an `ai` palette + gradient (`violet → blue → cyan`) in
  `DesignTokens`, and reusable `AiBackdrop` (aurora glow), `AiOrb` (gradient
  icon tile), `AiGlowCard` (gradient-ringed card), `AiGradientButton`,
  `AiPageHeader` (orb + title + actions), `AiSectionHeader` and
  `AiEmptyState` widgets in `shared/widgets/ai_widgets.dart`. Applied across
  every page: splash and welcome (aurora + glow CTA), workspace picker
  (glow-card current folder), dashboard (aurora wash, gradient stat cards,
  AI tips card), settings (highlighted AI-provider section), the editor's
  welcome state (orb + aurora + gradient folder-picker CTA), the AI chat
  header, the `AiPageHeader` on every IDE screen, and the remaining flat
  surfaces too: terminal header orb, quick-open dialog wrapped in the glow
  ring (with an `AiEmptyState` for empty results), the diff viewer's “No
  Changes” state, and the extension / plugin / debug / notification /
  shortcut-category cards all use `AiGlowCard`.
- **Groq reliability** — the shipped model list only contains ids the API
  currently serves and that support function calling (retired ids like
  `mixtral-8x7b-32768` 404'd on every call); a stored retired model is
  sanitized to the default; and the agent loop retries Groq's
  `tool_use_failed` rejection (malformed tool-call JSON is flaky model-side
  generation) with a corrective hint, without burning iteration budget.
- **Live model list** — when an API key is saved in Settings, the AI Model
  dropdown stops using the curated fallback list and fills with the models
  the Groq `/models` endpoint actually serves for that key (fetching
  happens only while the settings page is open). Non-tool-calling and
  retired ids are filtered out, the status line shows the live count or a
  fetch error, and a stored model that vanished from the API is
  auto-corrected to the first live model and persisted.
- **Startup folder selection** — on first launch the editor opens a folder
  browser to pick the workspace; the choice is persisted (`last_workspace`)
  and restored on later runs, with a vanished folder falling back to the
  picker. The browser shows hidden files on demand, errors inline (an
  unreadable path disables the confirm button), jumps to Home, and can
  delegate to the native OS picker (`zenity`/`kdialog`/`FolderBrowserDialog`
  with kill-on-timeout, probing availability first and surfacing a clear
  message when no tool exists instead of failing silently). Selecting a
  folder opens it realistically: the workspace root switches, the Explorer
  refreshes, the folder's README opens as the first tab, and the editor's
  empty state shows the folder name, path and item count. The
  `/workspace-picker` screen lists recent workspaces as quick-open entries.
  On **web**, where browsers cannot enumerate the disk, the picker opens a
  real native directory picker (`<input webkitdirectory>` — works in every
  major browser, no Chromium-only API): the chosen folder becomes an
  in-memory workspace whose files are actually readable/editable in the
  editor for the session (saves are kept in memory), with a README
  auto-open, instead of the old “desktop only” snackbar. The web picker is
  hardened end-to-end: the picked folder is registered as the active web
  workspace (so the IDE shows its real tree, not a placeholder), a pick
  that yields zero files (empty folder) still opens as an empty workspace,
  and the flow lands straight in the editor — recent workspaces open the
  same way. “Configure Settings” on the welcome screen opens a standalone
  welcome-styled settings page (`/welcome-settings`) instead of the full
  IDE chrome.
- **Workspace enumeration** — `workspace.tree` walks the whole workspace in
  one pass (junk dirs skipped, dirs-first sorted, file sizes included);
  Explorer and Quick Open rebuild their UI from that flat list.
- **Workspace grep** — `workspace.search`, shared by `SearchScreen` and the
  agent's `workspace.search` tool.
- **File watching** — `src/core/ipc/fs_watch.zig` runs a hybrid watcher:
  inotify on Linux (recursive watch maintenance + a periodic rescan safety
  net) or a 1s rescan elsewhere. Every trigger re-enumerates the root with the
  same `workspace.tree` walker and diffs the snapshot (path/kind/size/mtime),
  so the UI gets one coalesced `fs.change` line per burst instead of raw
  inotify noise.
- **Agent tools** — every `AgentController` tool call executes through the
  framework `Tool` registry (`agent.tool.execute`).

Core files:

- `flutter_app/lib/core/backend/agent_controller.dart` — the agent loop
  (drives `BackendService.executeAgentTool`)
- `src/core/ipc/agent_runtime.zig` — IPC bridge into the framework tool registry
- `src/core/ipc/fs_watch.zig` — native file watcher (inotify + snapshot diff, push to subscribers)
- `src/core/agent/framework/file_tools.zig`, `process_tools.zig`,
  `workspace_tools.zig` — the engine-side agent tools + tree walker
- `src/core/editor/` — native gap buffer with the C ABI the IPC server calls
- `flutter_app/lib/features/chat/ai_chat_sidebar.dart` — chat UI + tool cards
- `flutter_app/test/agent_controller_test.dart` — loop tests with a fake client

## Hiditor Editor System (planned)

> **Status:** Architecture documented; `frontend/hiditor/` directory not yet present.

**Hiditor** is a planned custom, high-performance code editor built from raw `epaint::Painter` primitives.

### Architecture
- **Buffer:** Piece-chain text store (`frontend/hiditor/src/buffer.rs`)
- **Rendering:** Raw `Painter` glyph batching by `(FontId, Color32)` — no `LayoutJob` in hot path
- **Syntax:** Incremental tree-sitter highlight with version-keyed cache
- **Input:** Raw `egui::Event` intercept (KeyDown/ReceivedCharacter/Scroll) — no `TextEdit`
- **Caret/Selection/Folding/Minimap:** All scratch-built

### Zero-Lag Targets (Non-Negotiable)
- Keydown → painted caret: **< 2 ms**
- Scroll repaint: **< 4 ms**
- 10k LOC open → first paint: **< 16 ms**
- Syntax reparse (incremental): **< 8 ms**
- Minimap repaint: **< 1 ms**
- 100 MB source memory ceiling: **< 200 MB**

### Run Hiditor (standalone) — once frontend/ is present
```sh
cd frontend/hiditor
cargo run
```

### Use from Tauri (optional) — once apps/ is present
In `apps/desktop/src-tauri/Cargo.toml`:
```toml
hiditor = { path = "../../frontend/hiditor", optional = true }
```
Enable with feature `hiditor-ui`.

## Current Vertical Slice

This scaffold includes:

- Enterprise agent framework (`src/core/agent/framework/`) — 115 tests, fully wired orchestrator + planner + executor + harness
- Zig core engine with C ABI exports
- Tauri desktop shell scaffold
- Hiditor custom editor architecture (Rust + egui)
- egui UI design spec with custom editor architecture

## Local Commands

```sh
zig build
zig build test
zig build agent-demo   # runs the framework end-to-end demo
```

Frontend and desktop commands require Node and Rust toolchains (both available). Desktop IDE launch:

```sh
cd apps/desktop
npm run tauri dev
```
