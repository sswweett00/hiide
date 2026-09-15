# egui IDE UI Design Specification

**Project:** hiide — AI-Native IDE  
**Frontend Stack:** Rust + egui 0.28+ (immediate mode) + Tauri v2 desktop shell  
**Target Aesthetic:** Sleek, minimalist, highly professional, sophisticated modern  
**Special Requirement:** Dedicated right sidebar for AI chat, seamlessly integrated  
**Editor Mandate:** 100% custom code editor built from raw egui/epaint primitives. No `egui::TextEdit`, no third-party editor crates.

---

## 1. Design Philosophy

1. **Content-first density:** Maximize code/editor real estate. UI chrome is invisible until needed.
2. **Subtle hierarchy:** Use 1–2 px hairline borders, soft shadows, and muted backgrounds instead of heavy dividers.
3. **Immediate mode elegance:** Embrace egui's frame-based layout. Avoid heavy nested state machines; prefer stateless widgets with egui's `Memory` for persistence.
4. **AI as a first-class citizen:** The chat sidebar is not an afterthought panel; it is a persistent context-aware collaborator.
5. **Performance-first:** All animations < 100 ms, GPU-friendly (avoid per-pixel shadows on scrolling lists), minimal overdraw.
6. **Zero-dependency editor:** The code editor is built entirely on `epaint::Painter` and `epaint::text`. No `TextEdit`, no `code-editor` crate, no webview overlay.

---

## 1.1 Zero-Lag Guarantee (Non-Negotiable)

The editor must feel **instantaneous**. No frame drop, no input latency, no “waiting for highlight”.

| Metric | Target | Measurement |
|---|---|---|
| Keydown → painted caret move | < 2 ms | `InputEvent::Key` timestamp to `Painter::add_glyphs` flush |
| Scroll (mouse wheel, 120 px delta) | < 4 ms | First valid frame after scroll event |
| 10,000-line file open → first paint | < 16 ms | File read to first `painter.add_glyphs` call |
| Syntax highlight reparse (incremental, 1 file) | < 8 ms | tree-sitter edit + span recompute + paint |
| Minimap repaint | < 1 ms | Scroll-driven, no glyph rasterization |
| Memory ceiling for 100 MB source | < 200 MB | Resident set after warmup |

**Rules that enforce zero lag:**
1. **No allocation in the hot paint path.** All `Vec`, `String`, `LayoutJob` are reused across frames or preallocated.
2. **No full-text reparse on every keystroke.** Use tree-sitter incremental edit. Only reparse from the first changed line to the end of the smallest enclosing node.
3. **No `LayoutJob` per line per frame.** Cache `TextSpan` lists per `buffer.version`. Convert to glyph batches once per version change.
4. **No `ScrollArea` for the editor text region.** Own scroll state in `f32` line units. Compute viewport in O(1).
5. **No per-frame heap allocation for caret/selection.** Store as `Option<Caret>` and `Option<Selection>` on `Editor`.
6. **Minimap is rect-only.** Never rasterize glyphs in the minimap. Derive color from the first token span of each sampled line.
7. **Clip to viewport + 1 line overscan.** Never iterate the full buffer on paint.
8. **Lock-free reads.** The paint path only borrows `&Editor`. Writes (edits) happen on a single-threaded event loop (egui guarantees single-threaded UI access).

### Implementation Roadmap

**Phase 1 — Buffer + Paint (Week 1–2)**
- Piece-chain text store (`editor/buffer.rs`) with O(1) insert/delete.
- Custom paint widget (`editor/render.rs`) using `Painter::add_glyphs`.
- Viewport culling + line-height scroll state.
- Caret + selection rendering.
- Gutter + line numbers.
- **Milestone:** 10k-line file scrolls and types at 60 fps with < 2 ms input latency.

**Phase 2 — Syntax + Minimap (Week 3)**
- tree-sitter integration (`editor/syntax.rs`) with incremental edit API.
- `TextSpan` cache keyed on `buffer.version`.
- Minimap as colored rects (`editor/minimap.rs`).
- **Milestone:** Rust/Zig file highlights incrementally on edit in < 8 ms.

**Phase 3 — Folding + Navigation (Week 4)**
- Bracket-based and indentation-based folding (`editor/folding.rs`).
- `BTreeSet<Range<usize>>` folded ranges.
- Gutter markers + collapsed placeholder rendering.
- Multi-caret support (optional, but zero-lag).
- **Milestone:** 50 MB source file folds/unfolds instantly.

**Phase 4 — LSP Integration (Week 5–6)**
- Diagnostics squiggles + hover lens (`editor/lens.rs`).
- Go-to-definition jump.
- Inline rename.
- **Milestone:** LSP feedback appears within 1 frame of diagnostic push.

**Phase 5 — Polish + Benchmark (Week 7)**
- Caret blink, smooth scroll, animation curves.
- Benchmark harness (`cargo bench` with 1k LOC / 10k LOC / 100k LOC).
- Memory profiling (`heaptrack`, `valgrind massif`).
- **Milestone:** All zero-lag targets met; 60 fps sustained on 100 MB source.

---

## 2. Color System (Dark Theme Default)

Use egui's `Color32` throughout.

### Base Palette
| Role | Hex | egui::Color32 |
|---|---|---|
| Background | `#0d1117` | `Color32::from_rgb(13, 17, 23)` |
| Surface / Panel | `#161b22` | `Color32::from_rgb(22, 27, 34)` |
| Elevated Surface | `#1c2129` | `Color32::from_rgb(28, 33, 41)` |
| Border (subtle) | `#21262d` | `Color32::from_rgb(33, 38, 45)` |
| Border (active) | `#30363d` | `Color32::from_rgb(48, 54, 61)` |
| Text Primary | `#e6edf3` | `Color32::from_rgb(230, 237, 243)` |
| Text Secondary | `#8b949e` | `Color32::from_rgb(139, 148, 158)` |
| Text Tertiary | `#484f58` | `Color32::from_rgb(72, 79, 88)` |
| Accent Blue | `#58a6ff` | `Color32::from_rgb(88, 166, 255)` |
| Accent Purple (AI) | `#bc8cff` | `Color32::from_rgb(188, 140, 255)` |
| Success | `#3fb950` | `Color32::from_rgb(63, 185, 80)` |
| Warning | `#d29922` | `Color32::from_rgb(210, 153, 34)` |
| Error | `#f85149` | `Color32::from_rgb(248, 81, 73)` |
| AI Bubble (user) | `#1f6feb` | `Color32::from_rgb(31, 111, 235)` |
| AI Bubble (assistant) | `#21262d` | `Color32::from_rgb(33, 38, 45)` |

### Semantic Colors
- **Active tab:** `Color32::from_rgb(13, 17, 23)` (blends with background)
- **Inactive tab:** `Color32::from_rgb(22, 27, 34)` with bottom border `#0d1117`
- **Hover tab:** `Color32::from_rgb(28, 33, 41)`
- **Gutter bg:** `Color32::from_rgb(22, 27, 34)`
- **Minimap bg:** `Color32::from_rgb(22, 27, 34)`
- **Scrollbar thumb:** `Color32::from_rgb(48, 54, 61)` → hover `Color32::from_rgb(139, 148, 158)`
- **Selection:** `Color32::from_rgba_unmultiplied(88, 166, 255, 120)`
- **Cursor:** `Color32::from_rgb(230, 237, 243)` with 2 px width

---

## 3. Typography

egui ships with `egui::FontDefinitions`. Define a custom font atlas:

- **Primary (code/monospace):** `"JetBrains Mono"` or `"Fira Code"` — fallback to `"SF Mono"`, `"Consolas"`, `"Monaco"`. Enable ligatures via font features (`calt`, `liga`).
- **UI (sans-serif):** `"Inter"` or system sans (`"Segoe UI"`, `"Roboto"`, `"SF Pro Text"`).
- **Sizes (egui `Galley`):**
  - Editor code: 14 px (scale with `ctx.style().zoom`)
  - UI labels: 13 px
  - Sidebar items: 13 px
  - Tab titles: 13 px
  - Status bar: 12 px
  - Chat messages: 13 px
- **Weights:** Regular (400) for body, Medium (500) for headers/bold tokens, Semibold (600) for active states.

### egui Style Tweaks
```rust
let mut style = (*ctx.style()).clone();
style.visuals = egui::Visuals::dark();
style.visuals.panel_fill = Color32::from_rgb(13, 17, 23);
style.visuals.widgets.inactive.bg_fill = Color32::from_rgb(22, 27, 34);
style.visuals.widgets.hovered.bg_fill = Color32::from_rgb(28, 33, 41);
style.visuals.widgets.active.bg_fill = Color32::from_rgb(33, 38, 45);
style.visuals.selection.bg_fill = Color32::from_rgba_unmultiplied(88, 166, 255, 120);
style.spacing.item_spacing = vec2(6.0, 4.0);
style.spacing.menu_margin = Margin::same(4.0);
style.spacing.scroll_bar_width = 8.0;
style.spacing.scroll_handle_min_length = 40.0;
ctx.set_style(style);
```

---

## 4. Layout Architecture (egui Immediate Mode)

egui's `SidePanel`, `TopBottomPanel`, and `CentralPanel` compose the main frame. Persist panel widths in `egui::Memory` so they survive frame-to-frame.

### 4.1 Top-Level Frame

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  TITLE BAR / MENU BAR  (TopPanel, 28 px)                                   │
│  [hiide] [File][Edit][Selection][View][Go][Terminal][Help]    [Search:] [⌘K]│
├──────────┬────────────────────────────────────────────────┬──────────────────┤
│          │  TAB BAR (TopPanel, 32 px)                      │                  │
│          │  [main.rs] [mod.rs] [Cargo.toml] ...           │                  │
│ LEFT     │────────────────────────────────────────────────│   RIGHT SIDEBAR  │
│ SIDEBAR  │                                                │   (AI CHAT)      │
│ (200 px) │  EDITOR GROUP (CentralPanel)                    │   (320 px)       │
│          │  ┌──────────────────────────┐  ┌──────────┐   │                  │
│ Files    │  │                          │  │ Minimap  │   │  💬 AI Chat      │
│ Search   │  │  Main Editor Area        │  │ (60 px)  │   │                  │
│ Outline  │  │  (Custom egui renderer)  │  │          │   │  [History]       │
│          │  │  No TextEdit. Pure paint.│  │          │   │  [Input field]   │
│          │  └──────────────────────────┘  └──────────┘   │                  │
│          │────────────────────────────────────────────────│                  │
│          │  BOTTOM PANEL (220 px, toggle)                 │                  │
│          │  [Terminal] [Problems] [Output] [Debug Console]│                  │
├──────────┴────────────────────────────────────────────────┴──────────────────┤
│  STATUS BAR (BottomPanel, 22 px)                                            │
│  main  UTF-8  Rust  │  LSP: Ready  │  AI: Connected  │  main *             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Panel Width Persistence

```rust
struct IdeApp {
    left_width: f32,
    right_width: f32,
    bottom_height: f32,
    // ...
}

impl IdeApp {
    fn ui(&mut self, ctx: &egui::Context, frame: &mut eframe::Frame) {
        let left = egui::SidePanel::left("left_sidebar")
            .resizable(true)
            .show_width(ctx, self.left_width);
        // ... same for right, bottom
        self.left_width = left.current_width;
    }
}
```

---

## 5. Component Structures

### 5.1 Top Menu Bar

```rust
egui::TopBottomPanel::top("menu_bar").show(ctx, |ui| {
    ui.horizontal(|ui| {
        ui.menu_button("hiide", |ui| { /* ... */ });
        ui.menu_button("File", |ui| { /* ... */ });
        ui.menu_button("Edit", |ui| { /* ... */ });
        ui.menu_button("Selection", |ui| { /* ... */ });
        ui.menu_button("View", |ui| { /* ... */ });
        ui.menu_button("Go", |ui| { /* ... */ });
        ui.menu_button("Terminal", |ui| { /* ... */ });
        ui.menu_button("Help", |ui| { /* ... */ });
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            ui.label("AI Status: Connected").on_hover_text("Zig engine ↔ LSP");
            ui.separator();
            ui.text_edit_singleline(&mut search_query)
                .hint_text("Search files, symbols, AI commands... (⌘K)");
            ui.button("⌘K");
        });
    });
});
```

**Visual:** Dark surface `#161b22`, bottom hairline `#21262d`. Menu items: `#e6edf3`, hover `#1c2129`, selected `#1f6feb` with rounded 4 px.

### 5.2 Tab Bar

```rust
egui::TopBottomPanel::top("tab_bar").show(ctx, |ui| {
    ui.horizontal(|ui| {
        for tab in &self.open_tabs {
            let is_active = tab.id == self.active_tab;
            let fill = if is_active {
                Color32::from_rgb(13, 17, 23)
            } else {
                Color32::from_rgb(22, 27, 34)
            };
            let response = ui.add(
                egui::Button::new(tab.title.clone())
                    .fill(fill)
                    .stroke(if is_active {
                        egui::Stroke::new(1.0, Color32::from_rgb(88, 166, 255))
                    } else {
                        egui::Stroke::NONE
                    })
                    .corner_radius(egui::CornerRadius::same(0))
            );
            if response.clicked() { self.active_tab = tab.id; }
            if is_active || response.hovered() {
                ui.spacing_mut().item_spacing.x = 0.0;
                ui.small_button("×").on_hover_text("Close");
            }
        }
    });
});
```

**Visual:** Tabs are 32 px tall. Active tab has a 1 px accent bottom border. Modified indicator: small dot `Color32::from_rgb(210, 153, 34)`.

### 5.3 Left Sidebar (File Explorer / Search / Outline)

```rust
egui::SidePanel::left("left_sidebar")
    .resizable(true)
    .show_width(ctx, self.left_width, |ui| {
        ui.set_min_width(180.0);
        ui.set_max_width(400.0);
        ui.vertical(|ui| {
            ui.horizontal(|ui| {
                ui.selectable_label(self.left_tab == LeftTab::Files, "Files");
                ui.selectable_label(self.left_tab == LeftTab::Search, "Search");
                ui.selectable_label(self.left_tab == LeftTab::Outline, "Outline");
            });
            ui.separator();
            match self.left_tab {
                LeftTab::Files => self.file_tree.ui(ui),
                LeftTab::Search => self.search_ui(ui),
                LeftTab::Outline => self.outline_ui(ui),
            }
        });
    });
```

**Visual:** Width defaults to 240 px. Background `#161b22`. Item height 22 px. Font 13 px.

### 5.4 Central Editor Area — Custom Renderer (No TextEdit)

The editor is a raw `CentralPanel` containing a **custom paint widget** that renders directly via `ui.painter()`. It does not use `egui::TextEdit`, `egui::CodeBlock`, or any third-party editor crate.

```rust
egui::CentralPanel::central().show(ctx, |ui| {
    let editor_id = ui.id().with("editor");
    let response = ui.allocate_response(
        egui::vec2(ui.available_width(), ui.available_height()),
        egui::Sense::click_and_drag().focusable_non_interactive()
    );
    self.custom_editor.paint(response, ui, ctx);
});
```

**Custom Editor Architecture (enterprise-grade, scratch-built):**

- **Text Buffer:** Piece-chain (not rope) for O(1) insert/delete and cache-friendly sequential reads. Each piece stores a small `Vec<u8>` or inline string. Line breaks are normalized to `\n`.
- **Rendering:** Paint directly with `ui.painter()` — no intermediate `Galley` per line. Batch glyphs by style (font, color, size) into a single `Painter::add_glyphs` call. Only paint lines inside the visible viewport + 1 line overscan.
- **Scroll / Viewport:** Own scroll offset in `f32` (line-height units). Convert to pixel offset for painting. Clamp to valid range. Do not use `ScrollArea` for the editor text region; use it only for auxiliary panels.
- **Caret / Selection:** Custom hit-test against painted glyph bounds. Caret is a 2 px wide rect. Selection is semi-transparent fill. Caret blink driven by `ctx.input(|i| i.time)` with 1 s period.
- **Gutter:** Fixed 50 px column painted first. Line numbers right-aligned, breakpoints as 10 px filled circles.
- **Minimap:** 60 px-wide strip on the right edge of the editor. Render every Nth line as a 1–2 px tall colored rect (not glyphs) for performance. Click/drag on minimap jumps viewport.
- **Folding:** Custom `+` / `-` markers in gutter. Collapsed regions render as `⋯` placeholder. Maintain folded ranges in `BTreeSet<Range<usize>>`.
- **Input / Key Handling:** Intercept `egui::InputState::events` for `KeyDown`, `KeyUp`, `ReceivedCharacter`. Do NOT use `TextEdit`. Build your own IME composition state if needed.
- **Clipboard:** Handle `Ctrl+C/V/X` via `egui::Output::copied_text` and OS clipboard through Tauri.

**Visual:** Editor background `#0d1117`. Gutter `#161b22` separated by 1 px hairline `#21262d`.

### 5.5 Right Sidebar — AI Chat

See full chat spec in sections below. Native egui panel, not a webview.

---

## 6. Custom Editor Engine — Detailed Architecture

### 6.1 Text Buffer (`editor/buffer.rs`)

```rust
pub struct Buffer {
    pieces: Vec<Piece>,
    line_offsets: Vec<usize>, // cached prefix sums of line lengths
    version: u64,             // bump on every edit for cache invalidation
}

struct Piece {
    text: Vec<u8>,      // or small inline array for tiny pieces
    len: usize,
}
```

- Insert/delete in O(1) amortized by splitting/merging adjacent pieces.
- `line_offsets` rebuilt incrementally on edit (only update affected range).
- Expose `char_at(pos)`, `slice(range)`, `line_range(line)`, `line_count()`.
- Memory: for 10 MB source, ~100–200 pieces is typical.

### 6.2 Syntax Highlighting (`editor/syntax.rs`)

Use `tree-sitter` via `tree-sitter-rust` / `tree-sitter-zig` / etc.:

```rust
pub struct SyntaxHighlighter {
    parser: tree_sitter::Parser,
    languages: HashMap<Language, Arc<ts::Language>>,
    cache: HashMap<u64, Vec<(usize, usize, Color32)>>, // version → spans
}
```

- Incremental parse: only reparse from first changed line to end of affected function (track via tree-sitter's `edit` API).
- Cache spans keyed by `buffer.version`. On edit, bump version and invalidate only ranges intersecting the edit.
- Token spans → `Color32` mapping via `TokenColor` table (theme-aware).
- Fallback: if no grammar is available, emit a single `TextColor::Primary` span.

### 6.3 Rendering Pipeline (`editor/render.rs`)

```rust
pub fn paint(editor: &Editor, response: &egui::Response, ui: &mut egui::Ui, ctx: &egui::Context) {
    let painter = ui.painter();
    let clip = response.rect;
    let viewport = editor.viewport(); // visible line range [start, end)

    // 1. Gutter
    painter.rect_filled(gutter_rect, 0.0, GUTTER_BG);
    for line in viewport.clone() {
        let y = gutter_y(line);
        painter.text(...line_number_text...);
    }

    // 2. Active line highlight (behind text)
    if let Some(active) = editor.active_line {
        if viewport.contains(&active) {
            painter.rect_filled(line_rect(active), 0.0, ACTIVE_LINE_BG);
        }
    }

    // 3. Text (batched by style)
    let mut batch: Vec<GlyphBatch> = Vec::new();
    for line in viewport {
        for span in editor.spans_for_line(line) {
            batch.push(GlyphBatch { ... });
        }
    }
    // Flatten and add_glyphs once per distinct font/color
    for batch in batches_sorted_by_style {
        painter.add_glyphs(batch.font_id, batch.glyphs, batch.color);
    }

    // 4. Caret + selection
    if editor.has_focus {
        painter.rect_filled(caret_rect, 0.0, CARET_COLOR);
        for sel in editor.selections {
            painter.rect_filled(sel_rect, 0.0, SELECTION_BG);
        }
    }

    // 5. Minimap (scaled rects, not glyphs)
    paint_minimap(painter, editor, minimap_rect);
}
```

**Performance rules:**
- Never allocate `String` in the hot paint path. Use `&str` slices from buffer.
- Batch glyphs by `(FontId, Color32)` to minimize `Painter` state changes.
- Reuse `Vec` for glyph positions across frames (clear, don't reallocate).
- Viewport culling: calculate visible line range from scroll offset + response.rect.height().

### 6.4 Input Handling (`editor/input.rs`)

```rust
pub fn handle_input(editor: &mut Editor, ui: &mut egui::Ui, ctx: &egui::Context) {
    let input = ctx.input(|i| i.events.clone());
    for event in input {
        match event {
            egui::Event::Key { key, modifiers, pressed: true, .. } => {
                if modifiers.ctrl || modifiers.command {
                    match key {
                        Key::C => editor.copy(),
                        Key::V => editor.paste(ui.ctx().output().copied_text),
                        Key::X => editor.cut(),
                        Key::Z => editor.undo(),
                        Key::A => editor.select_all(),
                        _ => {}
                    }
                } else {
                    match key {
                        Key::ArrowLeft => editor.move_caret(CaretMove::Left),
                        Key::ArrowRight => editor.move_caret(CaretMove::Right),
                        Key::ArrowUp => editor.move_caret(CaretMove::Up),
                        Key::ArrowDown => editor.move_caret(CaretMove::Down),
                        Key::Home => editor.move_caret(CaretMove::LineStart),
                        Key::End => editor.move_caret(CaretMove::LineEnd),
                        Key::Backspace => editor.delete_backward(),
                        Key::Delete => editor.delete_forward(),
                        Key::Enter => editor.insert_newline(),
                        Key::Tab => editor.insert_tab(),
                        _ => {}
                    }
                }
            }
            egui::Event::ReceivedCharacter(c) => {
                if !c.is_control() {
                    editor.insert_char(c);
                }
            }
            egui::Event::MouseMoved { pos, .. } => {
                editor.update_cursor_from_mouse(pos, response.rect);
            }
            egui::Event::MouseButton { button: egui::PointerButton::Primary, pressed: true, pos, .. } => {
                editor.handle_click(pos, response.rect, modifiers);
            }
            egui::Event::Scroll { delta, .. } => {
                editor.scroll_by(delta.y, line_height);
            }
            _ => {}
        }
    }
}
```

### 6.5 Minimap (`editor/minimap.rs`)

- Paint as a series of 1–2 px tall `rect_filled` calls inside a fixed-width strip.
- Color derived from syntax token at that line's first character.
- Height scaled: `minimap_rect.height() / editor.line_count()`.
- Click on minimap → set viewport so that line becomes ~50% visible.
- Scroll drag: map minimap Y delta to editor scroll delta.

### 6.6 Folding (`editor/folding.rs`)

- Parse indentation-based or brace-based fold ranges on first load and on edit.
- Store `folded_ranges: BTreeSet<Range<usize>>`.
- In render, skip painting lines inside a folded range; instead paint a single `⋯` at the fold start.
- Gutter click on fold marker toggles the range.

---

## 7. Module Structure (Expanded for Custom Editor)

```
frontend/
├── src-tauri/
│   └── src/
│       ├── main.rs                 # eframe app entry, theme init
│       ├── app.rs                  # IdeApp state, egui::App impl
│       ├── layout/
│       │   ├── mod.rs
│       │   ├── menu_bar.rs
│       │   ├── tab_bar.rs
│       │   ├── left_sidebar.rs
│       │   ├── right_sidebar.rs    # AI chat only
│       │   └── bottom_panel.rs
│       ├── editor/
│       │   ├── mod.rs              # Editor widget (public paint API)
│       │   ├── buffer.rs           # Piece-chain text store
│       │   ├── render.rs           # Custom painter, glyph batching
│       │   ├── input.rs            # Raw egui event → editor commands
│       │   ├── syntax.rs           # tree-sitter highlight + cache
│       │   ├── cursor.rs           # Caret, selection, click/drag
│       │   ├── minimap.rs          # Scaled rect renderer
│       │   ├── folding.rs          # Fold markers, collapsed ranges
│       │   ├── gutter.rs           # Line numbers, breakpoints
│       │   └── theme.rs            # Token → Color32 mapping
│       ├── chat/
│       │   ├── message.rs
│       │   ├── bubble.rs
│       │   ├── history.rs
│       │   └── input.rs
│       ├── files/
│       │   ├── tree.rs
│       │   └── icon.rs
│       ├── lsp/
│       │   └── client.rs
│       ├── ipc/
│       │   └── tauri.rs
│       ├── theme.rs                # Global egui style
│       └── state/
│           ├── ide.rs
│           └── persistence.rs
```

**Hard rule:** No `editor/` submodule may import `egui::TextEdit`, `egui::CodeBlock`, `egui_extras::Table`, or any crate named `*editor*` / `*textedit*`. All text rendering goes through `epaint::Painter`.

---

## 8. Performance Budgets (Custom Renderer)

| Component | Target FPS | Max Frame Time | Notes |
|---|---|---|---|
| Editor paint (10k loc) | 60 | 4 ms | Viewport culling + glyph batch |
| Editor input latency | — | 2 ms | Keydown → paint |
| Chat history (1k msgs) | 60 | 4 ms | Same as before |
| File tree (10k nodes) | 60 | 6 ms | Same as before |
| Full frame (typical) | 60 | 10 ms | Includes layout + AI chat |

### Optimizations
- **Glyph atlas:** Use `egui::FontAtlas` directly; do not create per-frame `FontImage`.
- **Batching:** Group glyphs by `(FontId, Color32, clip_rect)` and emit in one `add_glyphs` call.
- **Viewport culling:** Compute visible line range from scroll offset + height before iterating lines.
- **Cache invalidation:** Keyed on `buffer.version` and `theme.hash`. Recompute `LayoutJob` only when either changes.
- **Minimap:** Do NOT render glyphs; render colored 1 px rects. This is the biggest win.
- **LSP diagnostics:** Paint squiggles as `Shape::line` with 2–3 segments, not per-glyph.

---

## 9. AI Chat (Right Sidebar)

Same as previous spec. Native egui `SidePanel::right("ai_chat")`.

```rust
egui::SidePanel::right("ai_chat")
    .resizable(true)
    .show_width(ctx, self.right_width, |ui| {
        ui.set_min_width(280.0);
        ui.set_max_width(480.0);
        ui.vertical(|ui| {
            ui.horizontal(|ui| {
                ui.heading("AI Assistant");
                ui.label("● Connected");
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    ui.button("⚙");
                });
            });
            ui.separator();

            egui::ScrollArea::vertical()
                .max_height(ui.available_height() - 120.0)
                .stick_to_bottom(true)
                .show(ui, |ui| {
                    for msg in &self.chat_history {
                        self.chat_message_widget(ui, msg);
                    }
                });

            ui.horizontal(|ui| {
                ui.label("Context:");
                ui.small("main.rs");
                ui.small("lsp: rust-analyzer");
            });

            ui.separator();
            ui.horizontal(|ui| {
                let response = ui.text_edit_multiline(&mut self.chat_input)
                    .desired_width(f32::INFINITY)
                    .desired_rows(2);
                if ui.button("➤").clicked() || (response.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter))) {
                    self.submit_chat();
                }
            });
        });
    });
```

---

## 10. Bottom Panel & Status Bar

Same as previous spec.

---

## 11. Implementation Patterns

### 11.1 State Persistence

egui clears all widgets every frame. Persist UI state in `egui::Memory`:

```rust
impl eframe::App for IdeApp {
    fn save(&mut self, storage: &mut dyn eframe::Storage) {
        eframe::set_value(storage, eframe::APP_KEY, self);
    }
}
```

Serialize with `serde` + `ron` or `postcard`. Avoid storing transient hover states.

### 11.2 Widget Composition

Prefer small, stateless widgets:

```rust
struct ChatBubble<'a> {
    msg: &'a ChatMessage,
    style: ChatStyle,
}

impl ChatBubble<'_> {
    fn ui(self, ui: &mut egui::Ui) -> egui::Response {
        let fill = match self.style.role {
            ChatRole::User => Color32::from_rgb(31, 111, 235),
            ChatRole::Assistant => Color32::from_rgb(33, 38, 45),
        };
        Frame::none()
            .fill(fill)
            .corner_radius(12.0)
            .inner_margin(8.0)
            .show(ui, |ui| {
                ui.label(&self.msg.content);
            });
    }
}
```

### 11.3 Custom Text Layout (Editor Only)

Do NOT use `LayoutJob` for the main editor on every frame. Instead:

1. Compute syntax spans once per edit → store `Vec<TextSpan>`.
2. On paint, iterate visible lines and call `painter.add_glyphs` per distinct style batch.
3. For line wrapping, precompute wrap columns and cache wrapped line start positions.

```rust
pub struct TextSpan {
    pub range: Range<usize>,
    pub color: Color32,
    pub bold: bool,
    pub italic: bool,
}
```

### 11.4 Animation

Use `ctx.animate_value_with_time` sparingly:
- Sidebar resize: 150 ms ease-out.
- Chat streaming cursor blink: 500 ms.
- Editor caret blink: 1 s period.

---

## 12. Responsive Behavior

| Window Width | Left Sidebar | Editor(s) | Right Sidebar | Bottom Panel |
|---|---|---|---|---|
| < 900 px | Icons only (48 px) | Single editor | Collapse to 280 px | Minimize |
| 900–1400 px | 220 px | Single editor + minimap | 300 px | 180 px |
| > 1400 px | 260 px | Editor + minimap | 360 px | 240 px |

---

## 13. AI Chat Context Integration

The chat sidebar is context-aware. It reads from:
- **Active editor file:** Sent as a `context_chunk` on each user message.
- **LSP diagnostics:** Displayed as "Fix suggestions" inline.
- **Selection range:** Sent if user has a selection.
- **Zig engine state:** via Tauri IPC (`invoke("get_agent_status")`) showing agent progress.

**Message types:**
```rust
enum ChatMessage {
    User { content: String, context: Option<EditorContext> },
    Assistant { content: String, code_blocks: Vec<CodeBlock>, streaming: bool },
    System { content: String },
    Error { content: String },
}
```

**Streaming protocol (Zig ↔ Rust ↔ egui):**
1. User submits → Tauri command `chat_submit`.
2. Zig engine runs planner/agents → streams partial results via `emit("chat_stream", token)`.
3. Rust frontend appends `msg.partial_token` each frame until stream ends.

---

## 14. Zig Backend ↔ egui Frontend Bridge (Tauri)

```rust
// ipc/tauri.rs
#[tauri::command]
async fn chat_submit(app: AppHandle, content: String, context: EditorContext) -> Result<(), String> {
    app.emit("chat_stream", StreamToken { partial: "Thinking".into(), done: false })
        .map_err(|e| e.to_string())?;
    let result = hiide_engine::agent_framework_submit(content, context).await;
    // Stream partial tokens via emit...
}
```

- Zig engine (`src/core/agent/framework/orchestrator.zig`) runs planning and execution.
- Stream partial agent output tokens back to egui via Tauri events.
- Chat sidebar renders tokens incrementally (no blocking).

---

## 15. Accessibility & Polish

- **Keyboard navigation:** Tab through panels; `Ctrl+1/2/3` switch sidebar tabs; `Ctrl+B` toggle left sidebar; `Ctrl+J` toggle right chat.
- **High contrast mode:** Detect via system settings or user toggle; override accent colors to `#ffffff` / `#000000`.
- **Screen reader support:** egui's built-in `Accessibility` (available in 0.28+) — ensure all buttons have labels, all images have alt text (or are decorative).
- **RTL support:** egui handles RTL via `ui.layout_mut().direction = egui::Direction::RightToLeft` for Arabic/Hebrew text.

---

## 16. Conclusion

This spec delivers a professional, cutting-edge IDE aesthetic using egui's immediate mode paradigm without fighting the framework. The code editor is a fully custom, high-performance renderer built on `epaint::Painter` and a piece-chain text buffer — no `TextEdit`, no webview, no third-party editor crates. The right AI chat sidebar is a native egui panel, tightly integrated with editor context, the LSP layer, and the Zig agent engine.

**Key takeaways:**
- 100% custom editor: piece-chain buffer + raw `Painter` glyph batches + tree-sitter incremental highlight.
- Use `SidePanel::right("ai_chat")` for the AI sidebar.
- Persist panel widths in `App` state (serde).
- Stream AI tokens via Tauri `emit` / event listeners.
- Keep animations subtle and under 100 ms.
