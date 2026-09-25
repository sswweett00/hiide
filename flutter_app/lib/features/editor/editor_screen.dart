import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/backend/backend_service.dart';
import '../../core/backend/editor_session.dart';
import '../../core/backend/groq_ai_service.dart';
import '../../core/backend/web_picker.dart';
import '../../core/backend/workspace_service.dart';
import '../../core/design_system/tokens.dart';
import '../../core/providers/backend_provider.dart';
import '../../features/chat/ai_chat_sidebar.dart';
import '../../features/editor/markdown_preview.dart';
import '../../shared/models/editor_tab.dart';
import '../../shared/providers/editor_providers.dart';
import '../../features/settings/settings_screen.dart';
import '../../shared/widgets/ai_widgets.dart';
import '../../shared/widgets/folder_browser_dialog.dart';
import '../../shared/widgets/ide_shell.dart';

final aiSuggestionsProvider = StateProvider<List<String>>((ref) => []);

class EditorScreen extends ConsumerStatefulWidget {
  const EditorScreen({super.key});

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen> {
  /// Height of one editor row — shared by the line-number gutter, the
  /// minimap's scale math and scroll-to-line navigation.
  static const double _editorLineHeight = 28.0;

  /// Scroll controller for the line-number gutter (and the minimap). The
  /// text field scrolls through [_textScrollController]; the two are kept in
  /// lockstep by listeners so line numbers always follow the text.
  final ScrollController _scrollController = ScrollController();

  final ScrollController _textScrollController = ScrollController();

  /// Per-tab sessions bridging the UI text controller to the Zig engine buffer.
  final Map<String, EditorSession> _sessions = {};

  /// 1-based caret line of the active tab, tracked for the minimap marker.
  int _cursorLine = 1;

  /// Per-tab line change regions (buffer vs disk) for the gutter markers;
  /// populated by the native `editor.diff_lines` call (Dart fallback offline).
  final Map<String, List<EditorDiffRegion>> _diffRegions = {};

  /// Tabs whose diff is currently being computed (guards duplicate scheduling).
  final Set<String> _diffLoading = {};

  Timer? _diffDebounce;

  /// Debounced auto-save (see [autoSaveEnabledProvider]).
  Timer? _autoSaveTimer;

  /// Whether the markdown preview pane is open for the current .md tab.
  bool _markdownPreview = false;
  String? _previewTabId;

  // ── Find & replace state ──
  final TextEditingController _findCtrl = TextEditingController();
  final TextEditingController _replaceCtrl = TextEditingController();
  final FocusNode _findFocus = FocusNode();

  /// Scrolls the highlight overlay in lockstep with the editor text field.
  final ScrollController _overlayScrollController = ScrollController();

  /// (start, end) ranges of every match of [_findCtrl.text] in the active
  /// tab, honoring the case-sensitivity and regex toggles.
  List<(int, int)> _findRanges = [];

  /// Index into [_findRanges] currently selected.
  int _findIndex = 0;

  /// Match-case toggle (Aa).
  bool _findCaseSensitive = false;

  /// Regex toggle (`.*`).
  bool _findRegex = false;

  /// Set when the regex pattern does not compile; shown in the bar.
  String? _findRegexError;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // Link the text field and the gutter: either one scrolling mirrors the
    // other (equality guard prevents feedback loops).
    _textScrollController.addListener(_syncTextToGutter);
    _scrollController.addListener(_syncGutterToText);
    // First-run folder selection: when no workspace was restored at startup
    // (see `resolveStartupWorkspace` in main), open the browser once so the
    // user picks where to work.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeAutoOpenFolderPicker();
    });
  }

  /// Opens the folder browser on first launch. After a workspace was
  /// restored at startup this is a no-op; on web the picker is unavailable,
  /// so nothing happens there either.
  void _maybeAutoOpenFolderPicker() {
    if (kIsWeb) return; // folder browsing requires dart:io
    if (ref.read(workspaceRestoredProvider)) return;
    _showCustomFolderBrowser(context);
  }

  /// Interactive folder browser to pick the workspace root. On web the
  /// browser's native directory picker is used instead of the desktop dialog
  /// (browsers cannot list arbitrary disk directories).
  Future<void> _showCustomFolderBrowser(BuildContext context) async {
    if (kIsWeb) {
      final ws = await pickWebDirectory();
      if (ws == null) return; // user cancelled
      await activateWorkspace(ref, ws.rootPath);
      return;
    }

    final currentPath = ref.read(workspaceRootProvider);
    final selectedPath = await showDialog<String>(
      context: context,
      builder: (ctx) => FolderBrowserDialog(initialPath: currentPath),
    );

    if (selectedPath != null && selectedPath.isNotEmpty && mounted) {
      await activateWorkspace(ref, selectedPath);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Çalışma alanı açıldı: $selectedPath'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _diffDebounce?.cancel();
    _findCtrl.dispose();
    _replaceCtrl.dispose();
    _findFocus.dispose();
    _overlayScrollController.dispose();
    _textScrollController.removeListener(_syncTextToGutter);
    _scrollController.removeListener(_syncGutterToText);
    _scrollController.removeListener(_onScroll);
    _textScrollController.dispose();
    _scrollController.dispose();
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
    super.dispose();
  }

  EditorSession _sessionFor(EditorTab tab) {
    return _sessions.putIfAbsent(tab.id, () {
      final session = EditorSession(
        tabId: tab.id,
        backend: ref.read(backendServiceProvider),
        content: tab.content,
      );
      session.controller.addListener(() => _onCursorChanged(session));
      session.init();
      return session;
    });
  }

  /// Keeps [_cursorLine] in sync with the caret (only for the active tab, so
  /// background tabs can't clobber the marker).
  void _onCursorChanged(EditorSession session) {
    if (!mounted) return;
    final activeId = ref.read(activeTabIdProvider);
    if (session.tabId != activeId) return;
    final offset = session.controller.selection.baseOffset;
    if (offset < 0) return;
    final text = session.controller.text;
    final clamped = offset > text.length ? text.length : offset;
    final line = text.substring(0, clamped).split('\n').length;
    if (line != _cursorLine) {
      _cursorLine = line;
      setState(() {});
    }
  }

  /// Jumps the editor (and the minimap viewport) so line `line` (0-based) is
  /// at the top of the gutter, clamping to the scroll extent.
  void _scrollToLine(double line) {
    if (!_scrollController.hasClients) return;
    final target = (line * _editorLineHeight)
        .clamp(0.0, _scrollController.position.maxScrollExtent)
        .toDouble();
    _scrollController.jumpTo(target);
  }

  /// Text field scrolled → mirror into the gutter + minimap.
  void _syncTextToGutter() {
    if (!_textScrollController.hasClients || !_scrollController.hasClients) {
      return;
    }
    final textOffset = _textScrollController.offset;
    if ((textOffset - _scrollController.offset).abs() > 0.5) {
      _scrollController.jumpTo(
          textOffset.clamp(0.0, _scrollController.position.maxScrollExtent));
    }
    // The find-bar highlight overlay scrolls in lockstep too.
    if (_overlayScrollController.hasClients) {
      _overlayScrollController.jumpTo(textOffset);
    }
  }

  /// Gutter/minimap jumped → mirror into the text field.
  void _syncGutterToText() {
    if (!_textScrollController.hasClients || !_scrollController.hasClients) {
      return;
    }
    final gutterOffset = _scrollController.offset;
    if ((gutterOffset - _textScrollController.offset).abs() > 0.5) {
      _textScrollController.jumpTo(gutterOffset.clamp(
          0.0, _textScrollController.position.maxScrollExtent));
    }
  }

  /// Releases sessions whose tab was closed.
  void _pruneSessions(Set<String> liveTabIds) {
    final stale =
        _sessions.keys.where((id) => !liveTabIds.contains(id)).toList();
    for (final id in stale) {
      final session = _sessions.remove(id);
      if (session != null) session.dispose();
      _diffRegions.remove(id);
      _diffLoading.remove(id);
    }
  }

  /// Marker kind for buffer line `line`, or null when unchanged.
  /// `deleted` regions have no buffer line of their own — a red marker is
  /// drawn at the deletion boundary (clamped to the last line at EOF).
  String? _markerForLine(
      int line, List<EditorDiffRegion> regions, int lineCount) {
    for (final r in regions) {
      if (r.kind == 'deleted') {
        final boundary = r.line < lineCount ? r.line : lineCount - 1;
        if (line == boundary) return 'deleted';
        continue;
      }
      if (line >= r.line && line < r.line + r.count) return r.kind;
    }
    return null;
  }

  /// Debounced recompute after typing (keystrokes arrive faster than the diff).
  void _scheduleDiffRefresh(EditorTab tab) {
    _diffDebounce?.cancel();
    _diffDebounce = Timer(const Duration(milliseconds: 250), () {
      _refreshDiff(tab);
    });
  }

  /// Ensures the diff for `tab` is computed (once per session) without a
  /// timer, for the initial load / external-reload path.
  void _ensureDiffScheduled(EditorTab tab) {
    if (_diffRegions.containsKey(tab.id) || _diffLoading.contains(tab.id)) {
      return;
    }
    _diffLoading.add(tab.id);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshDiff(tab));
  }

  /// Computes buffer-vs-disk change regions natively (or via the Dart
  /// fallback) and repaints the gutter markers.
  Future<void> _refreshDiff(EditorTab tab) async {
    final session = _sessions[tab.id];
    if (session == null) {
      _diffLoading.remove(tab.id);
      return;
    }
    final regions = await session.diffAgainstDisk();
    _diffLoading.remove(tab.id);
    if (!mounted || !_sessions.containsKey(tab.id)) return;
    _diffRegions[tab.id] = regions;
    setState(() {});
  }

  void _onScroll() {
    final activeTab = _activeTabNow();
    final content = activeTab?.content ?? '';
    final lines = content.split('\n');
    final offset = _scrollController.offset;
    final line = (offset / _editorLineHeight).floor() + 1;
    final clampedLine = line.clamp(1, lines.isEmpty ? 1 : lines.length);
    if (ref.read(cursorLineProvider) != clampedLine) {
      ref.read(cursorLineProvider.notifier).state = clampedLine;
    }
  }

  /// Reactive variant for `build` (keeps the widget rebuilding on tab changes).
  EditorTab? _getActiveTab() {
    final activeId = ref.watch(activeTabIdProvider);
    final tabs = ref.watch(openTabsProvider);
    if (activeId == null || tabs.isEmpty) return null;
    return tabs.firstWhere(
      (t) => t.id == activeId,
      orElse: () => tabs.first,
    );
  }

  /// Read-only variant safe to call from listeners and async callbacks.
  EditorTab? _activeTabNow() {
    final activeId = ref.read(activeTabIdProvider);
    final tabs = ref.read(openTabsProvider);
    if (activeId == null || tabs.isEmpty) return null;
    return tabs.firstWhere(
      (t) => t.id == activeId,
      orElse: () => tabs.first,
    );
  }

  void _updateActiveTabContent(EditorTab tab, String newContent) {
    final tabs = ref.read(openTabsProvider);
    final index = tabs.indexWhere((t) => t.id == tab.id);
    if (index >= 0) {
      final updated = tabs[index].copyWith(
        content: newContent,
        isModified: true,
      );
      final newTabs = List<EditorTab>.from(tabs)..[index] = updated;
      ref.read(openTabsProvider.notifier).state = newTabs;
    }
  }

  /// Updates provider state and mirrors the change into the Zig engine buffer.
  void _sync(EditorTab tab, String newContent) {
    _updateActiveTabContent(tab, newContent);
    _sessionFor(tab).syncChange(newContent);
    _scheduleDiffRefresh(tab);
    _scheduleAutoSave(tab);
    // Keep the find-bar match list fresh while the user edits.
    if (ref.read(findBarOpenProvider)) {
      _computeFindMatches();
      setState(() {});
    }
  }

  // ─── Auto-save ────────────────────────────────────────────────────────────

  /// Debounced silent save: while the user types, the timer keeps resetting;
  /// 1.5s of stillness writes the file (no snackbar). Disabled by the
  /// Auto Save setting or when the tab has no disk path.
  void _scheduleAutoSave(EditorTab tab) {
    if (!ref.read(autoSaveEnabledProvider)) return;
    if (tab.path == null || tab.path!.isEmpty) return;
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(milliseconds: 1500), () {
      _autoSaveNow(tab);
    });
  }

  Future<void> _autoSaveNow(EditorTab tab) async {
    try {
      final session = _sessionFor(tab);
      final engineText = await session.engineText();
      await ref.read(workspaceServiceProvider).writeFile(tab.path!, engineText);
      session.markSaved(engineText);
      _diffDebounce?.cancel();
      _diffRegions[tab.id] = const [];
      final tabs = ref.read(openTabsProvider);
      final index = tabs.indexWhere((t) => t.id == tab.id);
      if (index >= 0) {
        final updated = tabs[index].copyWith(isModified: false);
        ref.read(openTabsProvider.notifier).state = List<EditorTab>.from(tabs)
          ..[index] = updated;
      }
    } catch (_) {
      // Silent auto-save failures never surface errors — the user can still
      // save manually (Ctrl+S shows failures).
    }
  }

  // ─── AI inline completion (Ctrl+Space) ────────────────────────────────────

  /// Asks Groq to complete the code before the caret on the current line and
  /// offers the result in a chip below the header (accept with Tab).
  Future<void> _requestAiCompletion() async {
    final tab = _activeTabNow();
    if (tab == null) return;
    final session = _sessionFor(tab);
    final text = session.controller.text;
    final offset = session.controller.selection.baseOffset;
    if (offset < 0 || offset > text.length) return;
    final lineStart = text.lastIndexOf('\n', offset - 1) + 1;
    final linePrefix = text.substring(lineStart, offset);
    if (linePrefix.trim().isEmpty) return;
    // Leading whitespace of the current line, so the model knows the nesting.
    final indentLen = linePrefix.length - linePrefix.trimLeft().length;
    final indentation = linePrefix.substring(0, indentLen);

    late final GroqAiService service;
    try {
      service = await ref.read(groqAiServiceProvider.future);
    } catch (_) {
      return;
    }
    if (!mounted || service.apiKey.isEmpty) return;

    ref.read(aiCompletionLoadingProvider.notifier).state = true;
    ref.read(aiCompletionProvider.notifier).state = null;
    final prompt = buildCompletionPrompt(
      language: languageForPath(tab.path ?? tab.title),
      linePrefix: linePrefix,
      indentation: indentation,
    );
    try {
      final result = await service.completeCode(prompt);
      if (!mounted) return;
      if (result != null && result.isNotEmpty) {
        ref.read(aiCompletionProvider.notifier).state = result;
      }
    } catch (_) {
      // Offline / API error — just offer no completion.
    } finally {
      if (mounted) {
        ref.read(aiCompletionLoadingProvider.notifier).state = false;
      }
    }
  }

  /// Inserts the offered completion at the caret, mirroring the change into
  /// the engine buffer exactly like a keystroke.
  void _acceptCompletion() {
    final completion = ref.read(aiCompletionProvider);
    final tab = _activeTabNow();
    if (completion == null || completion.isEmpty || tab == null) return;
    final session = _sessionFor(tab);
    final controller = session.controller;
    var offset = controller.selection.baseOffset;
    if (offset < 0) offset = controller.text.length;
    final newText = controller.text.replaceRange(offset, offset, completion);
    final newOffset = offset + completion.length;
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newOffset),
    );
    _updateActiveTabContent(tab, newText);
    session.syncChange(newText);
    _scheduleDiffRefresh(tab);
    _scheduleAutoSave(tab);
    ref.read(aiCompletionProvider.notifier).state = null;
    ref.read(aiCompletionLoadingProvider.notifier).state = false;
  }

  // ─── Find & replace (Ctrl+F / Ctrl+H) ─────────────────────────────────────

  /// Recomputes match ranges for the current query in the live buffer,
  /// honoring the case-sensitivity and regex toggles.
  void _computeFindMatches() {
    _findRegexError = null;
    final tab = _activeTabNow();
    if (tab == null) {
      _findRanges = [];
      _findIndex = 0;
      return;
    }
    final query = _findCtrl.text;
    final text = _sessionFor(tab).controller.text;
    if (query.isEmpty) {
      _findRanges = [];
      _findIndex = 0;
      return;
    }
    _findRanges = _findRangesFor(text, query);
    if (_findIndex >= _findRanges.length) _findIndex = 0;
  }

  /// Computes the (start, end) ranges of [query] in [text]. Plain mode is a
  /// simple index scan (case-insensitive by default); regex mode compiles the
  /// query as a pattern. On an invalid pattern [_findRegexError] is set and
  /// no ranges are returned.
  List<(int, int)> _findRangesFor(String text, String query) {
    final (ranges, error) = findTextRanges(
      text,
      query,
      caseSensitive: _findCaseSensitive,
      regex: _findRegex,
    );
    _findRegexError = error;
    return ranges;
  }

  /// Selects + scrolls to the [index]th match of the current query.
  void _jumpToFind(int index) {
    final tab = _activeTabNow();
    if (tab == null || _findRanges.isEmpty) return;
    final clamped = index.clamp(0, _findRanges.length - 1);
    _findIndex = clamped;
    final session = _sessionFor(tab);
    final text = session.controller.text;
    final (start, end) = _findRanges[clamped];
    session.controller.selection =
        TextSelection(baseOffset: start, extentOffset: end);
    final line = text.substring(0, start).split('\n').length;
    _scrollToLine((line - 1).toDouble());
    setState(() {});
  }

  /// Replaces the currently selected match with the replace text.
  void _replaceCurrent() {
    final tab = _activeTabNow();
    if (tab == null || _findRanges.isEmpty) return;
    final session = _sessionFor(tab);
    final controller = session.controller;
    final (start, end) = _findRanges[_findIndex];
    controller.selection = TextSelection(baseOffset: start, extentOffset: end);
    final replacement = _replaceCtrl.text;
    final newText = controller.text.replaceRange(start, end, replacement);
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + replacement.length),
    );
    _applyProgrammaticEdit(tab, session, newText);
    _computeFindMatches();
    if (_findRanges.isNotEmpty) {
      _jumpToFind(_findIndex.clamp(0, _findRanges.length - 1));
    }
  }

  /// Replaces every occurrence of the query in the active tab. Ranges are
  /// applied back-to-front so offsets stay valid; the replacement is literal
  /// (no `$1` backreference expansion).
  void _replaceAll() {
    final tab = _activeTabNow();
    if (tab == null) return;
    final query = _findCtrl.text;
    if (query.isEmpty) return;
    final session = _sessionFor(tab);
    final ranges = _findRangesFor(session.controller.text, query);
    if (ranges.isEmpty) return;
    var newText = session.controller.text;
    for (final (start, end) in ranges.reversed) {
      newText = newText.replaceRange(start, end, _replaceCtrl.text);
    }
    if (newText == session.controller.text) return;
    session.controller.value = TextEditingValue(
        text: newText, selection: session.controller.selection);
    _applyProgrammaticEdit(tab, session, newText);
    _computeFindMatches();
  }

  /// Mirrors a programmatic edit (find-replace) into the provider tab, the
  /// engine buffer, the gutter diff and the auto-save timer — the same path
  /// a keystroke takes, minus the TextField onChanged event (which does not
  /// fire for programmatic controller writes).
  void _applyProgrammaticEdit(
      EditorTab tab, EditorSession session, String newText) {
    _updateActiveTabContent(tab, newText);
    session.syncChange(newText);
    _scheduleDiffRefresh(tab);
    _scheduleAutoSave(tab);
  }

  /// Key handling for the editor text field: Tab accepts the AI completion,
  /// Escape dismisses it, Ctrl+Space requests one. Also supports Tab key
  /// for inserting spaces when no completion is active.
  KeyEventResult _handleEditorKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final key = event.logicalKey;

    final completion = ref.read(aiCompletionProvider);
    if (key == LogicalKeyboardKey.tab && completion != null) {
      _acceptCompletion();
      return KeyEventResult.handled;
    }
    // Tab key: insert spaces (or tab character) when no AI completion
    if (key == LogicalKeyboardKey.tab && completion == null) {
      final tab = _activeTabNow();
      if (tab != null) {
        final session = _sessionFor(tab);
        final controller = session.controller;
        final offset = controller.selection.baseOffset;
        final tabSize = ref.read(editorTabSizeProvider);
        final spaces = ' ' * tabSize;
        final newText = controller.text.replaceRange(offset, offset, spaces);
        controller.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: offset + spaces.length),
        );
        _sync(tab, newText);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && completion != null) {
      ref.read(aiCompletionProvider.notifier).state = null;
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.space) {
      _requestAiCompletion();
      return KeyEventResult.handled;
    }
    // Ctrl+Z — Undo (handled by TextField natively, but we mark as handled
    // so the IdeShell doesn't intercept it)
    if (ctrl && !HardwareKeyboard.instance.isShiftPressed &&
        key == LogicalKeyboardKey.keyZ) {
      return KeyEventResult.ignored; // Let TextField handle undo
    }
    // Ctrl+Shift+Z — Redo
    if (ctrl && HardwareKeyboard.instance.isShiftPressed &&
        key == LogicalKeyboardKey.keyZ) {
      return KeyEventResult.ignored; // Let TextField handle redo
    }
    // Ctrl+Y — Redo (alternative)
    if (ctrl && !HardwareKeyboard.instance.isShiftPressed &&
        key == LogicalKeyboardKey.keyY) {
      return KeyEventResult.ignored; // Let TextField handle redo
    }
    return KeyEventResult.ignored;
  }

  /// Returns the currently selected text in the active tab, or '' if the
  /// selection is collapsed or the session is not live.
  String _selectionText() {
    final activeTab = _activeTabNow();
    if (activeTab == null) return '';
    final controller = _sessions[activeTab.id]?.controller;
    if (controller == null) return '';
    final sel = controller.selection;
    if (!sel.isValid || sel.isCollapsed) return '';
    final start = sel.start < sel.end ? sel.start : sel.end;
    final end = sel.start < sel.end ? sel.end : sel.start;
    return controller.text.substring(start, end);
  }

  /// Sends an AI prompt (with the current selection as context) to the chat
  /// sidebar, which runs the agent loop.
  void _askAi(String instruction) {
    final selection = _selectionText();
    final prompt = selection.isNotEmpty
        ? '$instruction\n\n```\n${selection.length > 4000 ? selection.substring(0, 4000) : selection}\n```'
        : instruction;
    ref.read(aiPromptProvider.notifier).state = prompt;
  }

  Future<void> _saveActiveTab() async {
    final activeTab = _activeTabNow();
    if (activeTab == null || activeTab.path == null) return;
    final workspaceService = ref.read(workspaceServiceProvider);
    try {
      // The Zig engine buffer is authoritative: flush pending ops, then save
      // the exact bytes the engine holds.
      final session = _sessionFor(activeTab);
      final engineText = await session.engineText();
      await workspaceService.writeFile(activeTab.path!, engineText);
      // The saved bytes are the new on-disk baseline: the gutter diff clears.
      session.markSaved(engineText);
      _diffDebounce?.cancel();
      _diffRegions[activeTab.id] = const [];
      final tabs = ref.read(openTabsProvider);
      final index = tabs.indexWhere((t) => t.id == activeTab.id);
      if (index >= 0) {
        final updated = tabs[index].copyWith(isModified: false);
        ref.read(openTabsProvider.notifier).state = List<EditorTab>.from(tabs)
          ..[index] = updated;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Saved ${activeTab.title}'),
              duration: const Duration(seconds: 1)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Error saving file: $e'),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Text metrics for the highlight overlay — identical to the editor
  /// TextField, with transparent glyphs so the real text stays on top.
  TextStyle _findOverlayStyle(ColorScheme cs) {
    final fontSize = ref.read(editorFontSizeProvider);
    return TextStyle(
      fontFamily: 'JetBrains Mono',
      fontSize: fontSize,
      height: _editorLineHeight / fontSize,
      color: Colors.transparent,
    );
  }

  /// Highlight span for the overlay: matches are painted fresh against the
  /// live buffer each build (navigation ranges may lag mid-edit, painting
  /// never does).
  TextSpan _findHighlightSpan(String text, ColorScheme cs) {
    final query = _findCtrl.text;
    final ranges =
        query.isEmpty ? const <(int, int)>[] : _findRangesFor(text, query);
    return highlightTextSpans(
      text,
      ranges,
      baseStyle: _findOverlayStyle(cs),
      matchColor: cs.primary.withValues(alpha: 0.22),
      activeColor: const Color(0x59FFA657),
      activeIndex: ranges.isEmpty ? -1 : _findIndex.clamp(0, ranges.length - 1),
    );
  }

  /// The find & replace bar shown under the editor header (Ctrl+F / Ctrl+H).
  /// Finding runs over the live buffer; Enter/buttons jump between matches,
  /// the replace row swaps the current match or all matches, and the Aa / `.*`
  /// toggles switch case-sensitivity and regex mode.
  Widget _buildFindBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final replaceMode = ref.watch(findReplaceModeProvider);
    final total = _findRanges.length;
    final current = _findRanges.isEmpty ? 0 : _findIndex + 1;

    // Focus the find field when the bar first appears.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_findFocus.hasFocus) _findFocus.requestFocus();
    });

    void refreshMatches() {
      _computeFindMatches();
      setState(() {});
      if (_findRanges.isNotEmpty) _jumpToFind(0);
    }

    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: DesignTokens.space3, vertical: DesignTokens.space1),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
        border: Border(
            bottom: BorderSide(
                color: cs.outlineVariant, width: DesignTokens.borderWidthThin)),
      ),
      child: Row(
        children: [
          Icon(Icons.search,
              size: DesignTokens.iconSM, color: cs.onSurfaceVariant),
          const SizedBox(width: DesignTokens.space2),
          SizedBox(
            width: 180,
            child: TextField(
              controller: _findCtrl,
              focusNode: _findFocus,
              style: TextStyle(
                  color: cs.onSurface,
                  fontSize: DesignTokens.fontSizeSM,
                  fontFamily: 'JetBrains Mono'),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Bul…',
                hintStyle: TextStyle(color: cs.onSurfaceVariant),
                border: InputBorder.none,
              ),
              onChanged: (_) => refreshMatches(),
              onSubmitted: (_) => _jumpToFind(_findIndex + 1),
            ),
          ),
          const SizedBox(width: DesignTokens.space1),
          // ── Match-case toggle ──
          _FindToggle(
            label: 'Aa',
            active: _findCaseSensitive,
            tooltip: _findCaseSensitive
                ? 'Büyük/küçük harf duyarlı (kapat)'
                : 'Büyük/küçük harf duyarlı',
            onTap: () {
              setState(() => _findCaseSensitive = !_findCaseSensitive);
              refreshMatches();
            },
          ),
          // ── Regex toggle ──
          _FindToggle(
            label: '.*',
            active: _findRegex,
            tooltip: _findRegex ? 'Regex modu (kapat)' : 'Regex modu',
            onTap: () {
              setState(() => _findRegex = !_findRegex);
              refreshMatches();
            },
          ),
          const SizedBox(width: DesignTokens.space2),
          Text('$current / $total',
              style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: DesignTokens.fontSizeXS)),
          if (_findRegexError != null) ...[
            const SizedBox(width: DesignTokens.space2),
            Flexible(
              child: Text(
                _findRegexError!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: cs.error, fontSize: DesignTokens.fontSizeXS),
              ),
            ),
          ],
          IconButton(
            icon:
                const Icon(Icons.keyboard_arrow_up, size: DesignTokens.iconSM),
            visualDensity: VisualDensity.compact,
            onPressed:
                _findRanges.isEmpty ? null : () => _jumpToFind(_findIndex - 1),
            tooltip: 'Önceki',
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down,
                size: DesignTokens.iconSM),
            visualDensity: VisualDensity.compact,
            onPressed:
                _findRanges.isEmpty ? null : () => _jumpToFind(_findIndex + 1),
            tooltip: 'Sonraki (Enter)',
          ),
          if (replaceMode) ...[
            const SizedBox(width: DesignTokens.space2),
            Icon(Icons.swap_horiz,
                size: DesignTokens.iconSM, color: cs.onSurfaceVariant),
            const SizedBox(width: DesignTokens.space2),
            SizedBox(
              width: 140,
              child: TextField(
                controller: _replaceCtrl,
                style: TextStyle(
                    color: cs.onSurface,
                    fontSize: DesignTokens.fontSizeSM,
                    fontFamily: 'JetBrains Mono'),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Değiştir:',
                  hintStyle: TextStyle(color: cs.onSurfaceVariant),
                  border: InputBorder.none,
                ),
              ),
            ),
            TextButton(
              onPressed: _findRanges.isEmpty ? null : _replaceCurrent,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding:
                    const EdgeInsets.symmetric(horizontal: DesignTokens.space2),
              ),
              child: const Text('Değiştir',
                  style: TextStyle(fontSize: DesignTokens.fontSizeXS)),
            ),
            TextButton(
              onPressed: () {
                _replaceAll();
                setState(() {});
              },
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding:
                    const EdgeInsets.symmetric(horizontal: DesignTokens.space2),
              ),
              child: const Text('Tümü',
                  style: TextStyle(fontSize: DesignTokens.fontSizeXS)),
            ),
          ],
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.close, size: DesignTokens.iconSM),
            visualDensity: VisualDensity.compact,
            onPressed: () =>
                ref.read(findBarOpenProvider.notifier).state = false,
            tooltip: 'Kapat (Esc)',
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return IdeShell(child: _buildEditorContent(context));
  }

  Widget _buildEditorContent(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final palette = _SyntaxPalette.of(context);
    final activeTab = _getActiveTab();
    final currentWorkspace = ref.watch(workspaceRootProvider);

    if (activeTab == null) {
      // Welcome state: the folder name, its path and a live item count make
      // the opened workspace feel real even before any file is opened.
      final treeAsync = ref.watch(fileTreeProvider);
      final folderName = pathBasename(currentWorkspace);
      final itemCount = treeAsync.valueOrNull?.length;

      return Container(
        color: cs.surface,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Faint aurora wash behind the welcome state.
            Positioned.fill(
              child: IgnorePointer(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned(
                      top: -120,
                      right: -100,
                      child: Container(
                        width: 300,
                        height: 300,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color:
                                  DesignTokens.aiViolet.withValues(alpha: 0.08),
                              blurRadius: 160,
                              spreadRadius: 50,
                            ),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: -140,
                      left: -80,
                      child: Container(
                        width: 280,
                        height: 280,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color:
                                  DesignTokens.aiCyan.withValues(alpha: 0.07),
                              blurRadius: 150,
                              spreadRadius: 45,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Padding(
                  padding: const EdgeInsets.all(DesignTokens.space4),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const AiOrb(
                        icon: Icons.folder_special,
                        size: 72,
                        iconSize: 36,
                      ),
                      const SizedBox(height: DesignTokens.space4),
                      Text(
                        folderName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: cs.onSurface,
                            fontSize: DesignTokens.fontSizeXL,
                            fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: DesignTokens.space1),
                      Text(
                        'Çalışma alanı: $currentWorkspace',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: DesignTokens.fontSizeSM),
                      ),
                      if (itemCount != null) ...[
                        const SizedBox(height: DesignTokens.space1),
                        Text(
                          '$itemCount öğe mevcut — Dosyaları açmak için sol taraftaki Gezgin (Explorer) simgesine tıklayın',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: cs.onSurfaceVariant,
                              fontSize: DesignTokens.fontSizeXS),
                        ),
                      ],
                      const SizedBox(height: DesignTokens.space6),
                      AiGradientButton(
                        onPressed: () => _showCustomFolderBrowser(context),
                        label: 'Farklı Klasör Seç',
                        icon: Icons.folder_open,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Reconcile this tab with the engine-backed session and release sessions
    // for tabs that were closed.
    final session = _sessionFor(activeTab);
    if (session.updateFromExternal(activeTab.content)) {
      // External reload: the disk baseline changed, recompute the diff.
      _diffRegions.remove(activeTab.id);
    }
    _ensureDiffScheduled(activeTab);
    final allTabs = ref.watch(openTabsProvider);
    _pruneSessions(allTabs.map((t) => t.id).toSet());

    final lines = activeTab.content.split('\n');
    final regions = _diffRegions[activeTab.id] ?? const <EditorDiffRegion>[];
    final isMarkdown = activeTab.title.toLowerCase().endsWith('.md');

    // The markdown preview is per-tab: switching files closes it.
    if (_previewTabId != activeTab.id) {
      _previewTabId = activeTab.id;
      _markdownPreview = false;
    }

    // Find-bar highlight overlay: visible while the bar is open with a query.
    final showFindHighlights =
        ref.watch(findBarOpenProvider) && _findCtrl.text.isNotEmpty;
    if (showFindHighlights) {
      // Newly built overlay starts at offset 0 — snap it to the editor's
      // current scroll so highlights land on the visible lines.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_overlayScrollController.hasClients &&
            _textScrollController.hasClients) {
          _overlayScrollController.jumpTo(_textScrollController.offset);
        }
      });
    }

    return Container(
      color: cs.surface,
      child: Column(
        children: [
          // Editor Action Header Bar
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: DesignTokens.space4, vertical: DesignTokens.space2),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.2),
              border: Border(
                  bottom: BorderSide(
                      color: cs.outlineVariant,
                      width: DesignTokens.borderWidthThin)),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Below this width the header collapses to icon-only actions
                // so it never overflows.
                final narrow = constraints.maxWidth < 520;
                return Row(
                  children: [
                    Icon(activeTab.icon ?? Icons.insert_drive_file,
                        size: DesignTokens.iconSM, color: cs.primary),
                    const SizedBox(width: DesignTokens.space2),
                    Flexible(
                      child: Text(
                        activeTab.title + (activeTab.isModified ? ' *' : ''),
                        style: TextStyle(
                          color: cs.onSurface,
                          fontWeight: activeTab.isModified
                              ? FontWeight.bold
                              : FontWeight.normal,
                          fontSize: DesignTokens.fontSizeMD,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Spacer(),
                    // ── Markdown preview toggle (.md files) ──
                    if (isMarkdown) ...[
                      IconButton(
                        icon: Icon(
                          _markdownPreview
                              ? Icons.code
                              : Icons.preview_outlined,
                          size: DesignTokens.iconSM,
                        ),
                        tooltip: _markdownPreview
                            ? 'Kod görünümü'
                            : 'Markdown önizleme',
                        onPressed: () => setState(
                            () => _markdownPreview = !_markdownPreview),
                        visualDensity: VisualDensity.compact,
                      ),
                      const SizedBox(width: DesignTokens.space1),
                    ],
                    // ── Ask AI actions (selection-aware) ──
                    PopupMenuButton<String>(
                      tooltip: 'Ask AI',
                      icon: Icon(Icons.auto_awesome,
                          size: DesignTokens.iconSM, color: cs.primary),
                      onSelected: _askAi,
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value:
                              'Explain the selected code, then explain how it fits together.',
                          child: ListTile(
                            leading: Icon(Icons.chat_bubble_outline, size: 18),
                            title: Text('Explain selection'),
                            dense: true,
                          ),
                        ),
                        PopupMenuItem(
                          value:
                              'Improve the selected code in the active file. Apply the improved version with apply_diff, keeping the rest of the file unchanged, then verify with a build or test command.',
                          child: ListTile(
                            leading: Icon(Icons.auto_fix_high, size: 18),
                            title: Text('Improve selection'),
                            dense: true,
                          ),
                        ),
                        PopupMenuItem(
                          value:
                              'Carefully review the active file for bugs, performance issues and improvements. Report what you find, then fix real bugs with apply_diff and verify with a build or test command.',
                          child: ListTile(
                            leading: Icon(Icons.bug_report_outlined, size: 18),
                            title: Text('Find problems in file'),
                            dense: true,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: DesignTokens.space1),
                    if (narrow)
                      IconButton(
                        icon: const Icon(Icons.folder_open,
                            size: DesignTokens.iconSM),
                        tooltip: 'Klasör Seç',
                        onPressed: () => _showCustomFolderBrowser(context),
                        visualDensity: VisualDensity.compact,
                      )
                    else
                      OutlinedButton.icon(
                        onPressed: () => _showCustomFolderBrowser(context),
                        icon: const Icon(Icons.folder_open,
                            size: DesignTokens.iconXS),
                        label: const Text('Klasör Seç'),
                        style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact),
                      ),
                    if (activeTab.isModified) ...[
                      const SizedBox(width: DesignTokens.space2),
                      if (narrow)
                        IconButton.filled(
                          icon:
                              const Icon(Icons.save, size: DesignTokens.iconSM),
                          tooltip: 'Save (Ctrl+S)',
                          onPressed: _saveActiveTab,
                          visualDensity: VisualDensity.compact,
                        )
                      else
                        ElevatedButton.icon(
                          onPressed: _saveActiveTab,
                          icon:
                              const Icon(Icons.save, size: DesignTokens.iconXS),
                          label: const Text('Save'),
                          style: ElevatedButton.styleFrom(
                              visualDensity: VisualDensity.compact),
                        ),
                    ],
                  ],
                );
              },
            ),
          ),

          // ── AI inline completion (Ctrl+Space; kabul: Tab, vazgeç: Esc) ──
          if (ref.watch(aiCompletionLoadingProvider) ||
              ref.watch(aiCompletionProvider) != null)
            _AiCompletionChip(
              text: ref.watch(aiCompletionProvider),
              loading: ref.watch(aiCompletionLoadingProvider),
              onAccept: _acceptCompletion,
              onDismiss: () {
                ref.read(aiCompletionProvider.notifier).state = null;
                ref.read(aiCompletionLoadingProvider.notifier).state = false;
              },
            ),

          // ── Find & replace (Ctrl+F / Ctrl+H) ──
          if (ref.watch(findBarOpenProvider)) _buildFindBar(context),

          // Interactive Code Editing Body
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      // Line Numbers + change markers (buffer vs disk)
                      Container(
                        width: 70,
                        color: palette.gutterBackground,
                        child: ListView.builder(
                          controller: _scrollController,
                          itemCount: lines.length,
                          itemBuilder: (context, index) {
                            return _LineNumber(
                              lineNumber: index + 1,
                              palette: palette,
                              marker:
                                  _markerForLine(index, regions, lines.length),
                            );
                          },
                        ),
                      ),
                      // File minimap — whole-file overview next to the line
                      // numbers: diff regions tinted, caret + visible viewport
                      // marked; tap/drag to jump. Hidden when the Minimap
                      // setting is turned off.
                      if (ref.watch(settingsProvider.select((s) => s['minimap'] as bool)))
                        SizedBox(
                          width: 22,
                          child: _Minimap(
                            key: const Key('editor_minimap'),
                            controller: _scrollController,
                            lineCount: lines.length,
                            regions: regions,
                            cursorLine: _cursorLine,
                            lineHeight: _editorLineHeight,
                            background: palette.gutterBackground,
                            onJump: _scrollToLine,
                          ),
                        ),
                      // Editable Text Area — content is mirrored into the Zig engine
                      // buffer on every change (see EditorSession.syncChange).
                      Expanded(
                        child: Padding(
                          padding:
                              const EdgeInsets.only(left: DesignTokens.space2),
                          child: Focus(
                            onKeyEvent: _handleEditorKeyEvent,
                            child: Stack(
                              children: [
                                // Find-bar highlight overlay: a transparent
                                // Text.rich scrolled in lockstep paints the
                                // match backgrounds behind the field.
                                if (showFindHighlights)
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: ClipRect(
                                        child: SingleChildScrollView(
                                          controller: _overlayScrollController,
                                          physics:
                                              const NeverScrollableScrollPhysics(),
                                          child: Text.rich(
                                            _findHighlightSpan(
                                                session.controller.text, cs),
                                            maxLines: null,
                                            softWrap: true,
                                            style: _findOverlayStyle(cs),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                Positioned.fill(
                                  child: TextField(
                                    key: const Key('editor-code-text-field'),
                                    controller: session.controller,
                                    scrollController: _textScrollController,
                                    onChanged: (value) =>
                                        _sync(activeTab, value),
                                    maxLines: null,
                                    expands: true,
                                    keyboardType: TextInputType.multiline,
                                    // Every text line is exactly 28px (same as a
                                    // gutter row), so line numbers stay aligned
                                    // with the code and text/gutter scroll extents
                                    // match — and the overlay lines align too.
                                    strutStyle: StrutStyle(
                                      fontFamily: 'JetBrains Mono',
                                      fontSize: ref.watch(editorFontSizeProvider),
                                      height: _editorLineHeight /
                                          ref.watch(editorFontSizeProvider),
                                      forceStrutHeight: true,
                                    ),
                                    style: TextStyle(
                                      fontFamily: 'JetBrains Mono',
                                      fontSize: ref.watch(editorFontSizeProvider),
                                      height: _editorLineHeight /
                                          ref.watch(editorFontSizeProvider),
                                      color: cs.onSurface,
                                    ),

                                    decoration: const InputDecoration(
                                      border: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_markdownPreview && isMarkdown) ...[
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: MarkdownPreview(content: activeTab.content),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Computes the (start, end) ranges of [query] in [text] honoring the find
/// bar's case-sensitivity and regex toggles. Returns `(ranges, error)` where
/// `error` is non-null only for an invalid regex pattern (ranges empty then).
/// Pure function so the matching rules are unit-testable.
(List<(int, int)>, String?) findTextRanges(
  String text,
  String query, {
  required bool caseSensitive,
  required bool regex,
}) {
  if (query.isEmpty) return (const [], null);
  if (regex) {
    final RegExp re;
    try {
      re = RegExp(query, caseSensitive: caseSensitive);
    } catch (e) {
      return (
        const [],
        'Geçersiz desen: ${e.toString().split('\n').first}',
      );
    }
    return ([for (final m in re.allMatches(text)) (m.start, m.end)], null);
  }
  final ranges = <(int, int)>[];
  if (caseSensitive) {
    var start = 0;
    while (true) {
      final idx = text.indexOf(query, start);
      if (idx < 0) break;
      ranges.add((idx, idx + query.length));
      start = idx + query.length;
    }
  } else {
    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    var start = 0;
    while (true) {
      final idx = lowerText.indexOf(lowerQuery, start);
      if (idx < 0) break;
      ranges.add((idx, idx + query.length));
      start = idx + query.length;
    }
  }
  return (ranges, null);
}

/// Builds the text span painted by the find-bar highlight overlay: every
/// match range gets a background color, the active match a distinct shade.
/// The span's own glyphs use [baseStyle] (transparent in the overlay — the
/// real TextField draws them on top). Ranges are clamped to the current text
/// so stale offsets after edits can never crash the painter. Pure function so
/// the highlight layout is unit-testable.
TextSpan highlightTextSpans(
  String text,
  List<(int, int)> ranges, {
  required TextStyle baseStyle,
  required Color matchColor,
  required Color activeColor,
  int activeIndex = -1,
}) {
  final spans = <InlineSpan>[];
  var cursor = 0;
  for (var i = 0; i < ranges.length; i++) {
    final (start, end) = ranges[i];
    final s = start.clamp(0, text.length);
    final e = end.clamp(s, text.length);
    if (s > cursor) spans.add(TextSpan(text: text.substring(cursor, s)));
    if (e > s) {
      spans.add(TextSpan(
        text: text.substring(s, e),
        style: TextStyle(
          backgroundColor: i == activeIndex ? activeColor : matchColor,
        ),
      ));
    }
    cursor = e;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor)));
  }
  return TextSpan(style: baseStyle, children: spans);
}

/// Compact toggle used in the find bar (Aa = match case, `.*` = regex).
class _FindToggle extends StatelessWidget {
  final String label;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;

  const _FindToggle({
    required this.label,
    required this.active,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DesignTokens.radiusSM),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            color: active
                ? cs.primary.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(DesignTokens.radiusSM),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: DesignTokens.fontSizeXS,
              fontFamily: 'JetBrains Mono',
              fontWeight: active ? FontWeight.bold : FontWeight.normal,
              color: active ? cs.primary : cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows the AI inline completion (Ctrl+Space) below the editor header: the
/// offered text, a Tab hint to accept and Esc to dismiss.
class _AiCompletionChip extends StatelessWidget {
  final String? text;
  final bool loading;
  final VoidCallback onAccept;
  final VoidCallback onDismiss;

  const _AiCompletionChip({
    required this.text,
    required this.loading,
    required this.onAccept,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
          horizontal: DesignTokens.space3, vertical: DesignTokens.space1),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            DesignTokens.aiViolet.withValues(alpha: 0.12),
            DesignTokens.aiCyan.withValues(alpha: 0.06),
          ],
        ),
        border: Border(
          bottom: BorderSide(
              color: DesignTokens.aiViolet.withValues(alpha: 0.35),
              width: DesignTokens.borderWidthThin),
        ),
      ),
      child: Row(
        children: [
          const AiOrb(icon: Icons.auto_awesome, size: 18, iconSize: 12),
          const SizedBox(width: DesignTokens.space2),
          Expanded(
            child: loading && text == null
                ? Text('AI tamamlama isteniyor…',
                    style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: DesignTokens.fontSizeXS))
                : Text(
                    text ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.primary,
                      fontSize: DesignTokens.fontSizeSM,
                      fontFamily: 'JetBrains Mono',
                    ),
                  ),
          ),
          if (text != null) ...[
            TextButton(
              onPressed: onAccept,
              style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                      horizontal: DesignTokens.space2)),
              child: const Text('Tab ile kabul et',
                  style: TextStyle(fontSize: DesignTokens.fontSizeXS)),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: DesignTokens.iconSM),
              visualDensity: VisualDensity.compact,
              onPressed: onDismiss,
              tooltip: 'Vazgeç (Esc)',
            ),
          ],
        ],
      ),
    );
  }
}

class _LineNumber extends StatelessWidget {
  final int lineNumber;
  final _SyntaxPalette palette;

  /// One of `modified`, `added`, `deleted`, or null for unchanged lines.
  final String? marker;

  const _LineNumber({
    required this.lineNumber,
    required this.palette,
    this.marker,
  });

  static const Color _modified = Color(0xFFD29922);
  static const Color _added = Color(0xFF3FB950);
  static const Color _deleted = Color(0xFFF85149);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 28,
      child: Row(
        children: [
          SizedBox(
            width: 16,
            child: Center(child: _markerBar()),
          ),
          Expanded(
            child: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: DesignTokens.space2),
              child: Text(
                '$lineNumber',
                style: TextStyle(
                  color: palette.gutterText,
                  fontSize: DesignTokens.fontSizeSM,
                  fontFamily: 'JetBrains Mono',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _markerBar() {
    final color = switch (marker) {
      'modified' => _modified,
      'added' => _added,
      'deleted' => _deleted,
      _ => Colors.transparent,
    };
    return Container(
      width: marker == 'deleted' ? 2 : 3,
      height: 28,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

/// Whole-file overview strip: every buffer line drawn scaled into a thin
/// column, diff regions tinted (same colors as the gutter markers), the caret
/// line and the currently visible viewport highlighted. Tap or drag to jump
/// the editor to that line. Repaints only on scroll / caret / diff changes.
class _Minimap extends StatefulWidget {
  const _Minimap({
    super.key,
    required this.controller,
    required this.lineCount,
    required this.regions,
    required this.cursorLine,
    required this.lineHeight,
    required this.background,
    required this.onJump,
  });

  final ScrollController controller;
  final int lineCount;
  final List<EditorDiffRegion> regions;

  /// 1-based caret line.
  final int cursorLine;

  final double lineHeight;
  final Color background;
  final void Function(double line) onJump;

  @override
  State<_Minimap> createState() => _MinimapState();
}

class _MinimapState extends State<_Minimap> {
  double _offset = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
    _offset = widget.controller.hasClients ? widget.controller.offset : 0.0;
  }

  @override
  void didUpdateWidget(covariant _Minimap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onScroll);
      widget.controller.addListener(_onScroll);
      _offset = widget.controller.hasClients ? widget.controller.offset : 0.0;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    if (!mounted) return;
    final offset =
        widget.controller.hasClients ? widget.controller.offset : 0.0;
    if (offset != _offset) setState(() => _offset = offset);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final total = widget.lineCount * widget.lineHeight;
        final scale = total <= height ? 1.0 : height / total;
        final rowHeight = widget.lineHeight * scale;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => widget.onJump(d.localPosition.dy / rowHeight),
          onVerticalDragUpdate: (d) =>
              widget.onJump(d.localPosition.dy / rowHeight),
          child: SizedBox.expand(
            child: CustomPaint(
              painter: _MinimapPainter(
                lineCount: widget.lineCount,
                regions: widget.regions,
                cursorLine: widget.cursorLine,
                offset: _offset,
                viewportHeight: height,
                rowHeight: rowHeight,
                scale: scale,
                background: widget.background,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MinimapPainter extends CustomPainter {
  _MinimapPainter({
    required this.lineCount,
    required this.regions,
    required this.cursorLine,
    required this.offset,
    required this.viewportHeight,
    required this.rowHeight,
    required this.scale,
    required this.background,
  });

  final int lineCount;
  final List<EditorDiffRegion> regions;
  final int cursorLine; // 1-based
  final double offset; // editor scroll offset (px)
  final double viewportHeight; // editor viewport height (px)
  final double rowHeight; // px per line in the minimap
  final double scale; // minimap px per editor px
  final Color background;

  static const Color _modified = Color(0xFFD29922);
  static const Color _added = Color(0xFF3FB950);
  static const Color _deleted = Color(0xFFF85149);
  static const Color _line = Color(0x14FFFFFF); // faint unchanged line
  static const Color _viewportFill = Color(0x0DFFFFFF);
  static const Color _viewportBorder = Color(0x40FFFFFF);
  static const Color _cursor = Color(0xE6FFFFFF);

  /// Diff kind for buffer line `line` (mirrors the gutter's marker logic).
  String? _kindForLine(int line) {
    for (final r in regions) {
      if (r.kind == 'deleted') {
        final boundary = r.line < lineCount ? r.line : lineCount - 1;
        if (line == boundary) return 'deleted';
        continue;
      }
      if (line >= r.line && line < r.line + r.count) return r.kind;
    }
    return null;
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    if (lineCount == 0) return;

    // One tiny bar per line — unchanged lines faint, diff lines tinted.
    for (var i = 0; i < lineCount; i++) {
      final color = switch (_kindForLine(i)) {
        'modified' => _modified,
        'added' => _added,
        'deleted' => _deleted,
        _ => _line,
      };
      final y = i * rowHeight;
      final h = (rowHeight - 0.5).clamp(1.0, double.infinity).toDouble();
      canvas.drawRect(
          Rect.fromLTWH(1, y, size.width - 2, h), Paint()..color = color);
    }

    // Caret marker.
    if (cursorLine >= 1 && cursorLine <= lineCount) {
      final y = (cursorLine - 1) * rowHeight;
      canvas.drawRect(
          Rect.fromLTWH(0, y, size.width, 2), Paint()..color = _cursor);
    }

    // Visible viewport indicator.
    final vpTop = (offset * scale).clamp(0.0, size.height);
    final vpHeight = (viewportHeight * scale).clamp(0.0, size.height - vpTop);
    if (vpHeight > 0) {
      canvas.drawRect(
        Rect.fromLTWH(0, vpTop, size.width, vpHeight),
        Paint()..color = _viewportFill,
      );
      canvas.drawRect(
        Rect.fromLTWH(0, vpTop, size.width, 1),
        Paint()..color = _viewportBorder,
      );
      canvas.drawRect(
        Rect.fromLTWH(0, vpTop + vpHeight - 1, size.width, 1),
        Paint()..color = _viewportBorder,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MinimapPainter oldDelegate) {
    return oldDelegate.lineCount != lineCount ||
        oldDelegate.cursorLine != cursorLine ||
        oldDelegate.offset != offset ||
        oldDelegate.viewportHeight != viewportHeight ||
        oldDelegate.rowHeight != rowHeight ||
        oldDelegate.scale != scale ||
        oldDelegate.background != background ||
        !identical(oldDelegate.regions, regions);
  }
}

class _SyntaxPalette {
  final Color keyword;
  final Color type;
  final Color string;
  final Color comment;
  final Color number;
  final Color punctuation;
  final Color gutterBackground;
  final Color gutterText;

  const _SyntaxPalette({
    required this.keyword,
    required this.type,
    required this.string,
    required this.comment,
    required this.number,
    required this.punctuation,
    required this.gutterBackground,
    required this.gutterText,
  });

  static _SyntaxPalette of(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (isDark) {
      return const _SyntaxPalette(
        keyword: Color(0xFFFF7B72),
        type: Color(0xFF79C0FF),
        string: Color(0xFFA5D6FF),
        comment: Color(0xFF8B949E),
        number: Color(0xFF79C0FF),
        punctuation: Color(0xFFE6EDF3),
        gutterBackground: Color(0xFF0D1117),
        gutterText: Color(0xFF6E7681),
      );
    }

    return const _SyntaxPalette(
      keyword: Color(0xFFCF222E),
      type: Color(0xFF0550AE),
      string: Color(0xFF0A3069),
      comment: Color(0xFF6E7781),
      number: Color(0xFF0550AE),
      punctuation: Color(0xFF1F2328),
      gutterBackground: Color(0xFFF6F8FA),
      gutterText: Color(0xFF6E7781),
    );
  }
}
