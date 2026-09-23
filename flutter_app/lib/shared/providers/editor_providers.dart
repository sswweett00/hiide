import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/backend/backend_service.dart';
import '../../core/backend/groq_ai_service.dart';
import '../../core/backend/workspace_service.dart';
import '../../core/backend/settings_service.dart';
import '../../core/providers/backend_provider.dart';
import '../../shared/models/editor_tab.dart';
import '../../shared/models/file_tree_item.dart';
import '../../shared/models/todo_issue.dart';

/// Re-exported so callers importing this file can keep using [UiMode] now
/// that the settings layer owns the enum (and its persistence).
export '../../core/backend/settings_service.dart' show UiMode;

final workspaceRootProvider =
    StateProvider<String>((ref) => '/home/kaan/projeler/hiide');

/// Set by `main()` after a persisted workspace was restored. When false (first
/// launch, or restore failed), the editor opens the folder browser once so
/// the user picks a workspace instead of silently using the default root.
final workspaceRestoredProvider = StateProvider<bool>((ref) => false);

/// Resolves the workspace to open at startup: the persisted one when it still
/// exists on disk, otherwise null (first run). A vanished entry is cleared so
/// it cannot re-trigger a restore of a dead path.
Future<String?> resolveStartupWorkspace() async {
  final stored = await settingsService.getLastWorkspace();
  if (stored == null || stored.trim().isEmpty) return null;
  try {
    if (Directory(stored).existsSync()) return stored;
  } catch (_) {}
  await settingsService.setLastWorkspace(null);
  return null;
}

/// Activates [path] as the workspace root: switches the root, resets the
/// expansion to the new root, closes open tabs, refreshes the tree and
/// persists the choice (last workspace + recents, most-recent-first, max 8).
/// When the folder has a README, it is opened as the first tab so the IDE
/// lands on the project instead of a blank editor. Shared by the editor's
/// folder browser and the workspace picker screen.
Future<void> activateWorkspace(WidgetRef ref, String path) async {
  final root = WorkspaceService.normalizePath(path);
  ref.read(workspaceRootProvider.notifier).state = root;

  final expanded = <String>{root};
  if (!kIsWeb) {
    try {
      final dir = Directory(root);
      if (dir.existsSync()) {
        for (final entity in dir.listSync(followLinks: false)) {
          if (entity is Directory && !pathBasename(entity.path).startsWith('.')) {
            expanded.add(entity.path);
          }
        }
      }
    } catch (_) {}
  }
  ref.read(expandedPathsProvider.notifier).state = expanded;
  ref.read(openTabsProvider.notifier).state = [];
  ref.read(activeTabIdProvider.notifier).state = null;
  ref.invalidate(fileTreeProvider);

  await settingsService.setLastWorkspace(root);
  final recents = await settingsService.getRecentWorkspaces();
  final updated = [root, ...recents.where((r) => r != root)].take(8).toList();
  await settingsService.setRecentWorkspaces(updated);
  ref.read(recentWorkspacesProvider.notifier).state = updated;

  await _openWelcomeReadme(ref, root);
}

/// Opens the workspace's README (any common casing) as the first tab so a
/// freshly opened folder feels opened. Failures (no README, unreadable file,
/// web) are silent — the editor falls back to its empty state. On web the
/// read is bounded by a timeout: a stalled `File.text()` must never block
/// the activation flow that follows (it used to leave the IDE on the picker
/// screen after a folder pick). Desktop needs no bound — real I/O completes.
Future<void> _openWelcomeReadme(WidgetRef ref, String root) async {
  final service = ref.read(workspaceServiceProvider);
  var found = kIsWeb
      ? await service
          .findWelcomeFile(root)
          .timeout(const Duration(seconds: 4), onTimeout: () => null)
      : await service.findWelcomeFile(root);

  if (found == null && !kIsWeb) {
    try {
      final dir = Directory(root);
      if (await dir.exists()) {
        final list = await dir.list(followLinks: false).toList();
        final files = list.whereType<File>().toList();
        final suitable = files.where((f) {
          final n = pathBasename(f.path);
          return !n.startsWith('.') &&
              !n.endsWith('.lock') &&
              !n.endsWith('.stamp') &&
              !n.endsWith('.bin');
        }).toList();
        if (suitable.isNotEmpty) {
          final first = suitable.first;
          final content = await first.readAsString();
          found = (path: first.path, content: content);
        }
      }
    } catch (_) {}
  }

  if (found == null) return;
  final tab = EditorTab(
    id: 'tab_${found.path}',
    title: pathBasename(found.path),
    path: found.path,
    content: found.content,
    icon: Icons.description,
  );
  ref.read(openTabsProvider.notifier).state = [tab];
  ref.read(activeTabIdProvider.notifier).state = tab.id;
}

final workspaceServiceProvider = Provider<WorkspaceService>((ref) {
  final root = ref.watch(workspaceRootProvider);
  return WorkspaceService(rootPath: root);
});

/// Groq AI service — reads key + model from SettingsService (with file
/// fallback). Never throws: when the platform prefs are unavailable (widget
/// tests, web without a channel) it degrades to an empty key so the UI shows
/// an "offline" state instead of crashing.
final groqAiServiceProvider = FutureProvider<GroqAiService>((ref) async {
  String apiKey = '';
  String model = SettingsService.defaultModel;
  try {
    apiKey = await settingsService.getApiKey();
    model = await settingsService.getModel();
  } catch (e) {
    debugPrint('Could not load AI settings: $e');
  }
  return GroqAiService(apiKey: apiKey, defaultModel: model);
});

/// Live Groq connectivity probe (key validity + network), surfaced in the
/// status bar and the chat header. Recomputed automatically whenever
/// [groqAiServiceProvider] is invalidated — e.g. after saving a new API key
/// or switching models in Settings.
final groqConnectionProvider =
    FutureProvider<({bool ok, String message})>((ref) async {
  final service = await ref.watch(groqAiServiceProvider.future);
  return service.checkConnection();
});

/// Model ids actually served by the Groq API for the configured key, filtered
/// to ids the agent can use. An EMPTY list means "fall back to the curated
/// [SettingsService.availableModels]" — no key configured, fetch failure, or
/// nothing returned. Watches [groqAiServiceProvider], so saving a new API key
/// in Settings automatically refetches and the model dropdown transitions
/// from the default list to the live one.
final groqLiveModelsProvider = FutureProvider<List<String>>((ref) async {
  final service = await ref.watch(groqAiServiceProvider.future);
  if (service.apiKey.isEmpty) return const [];
  try {
    final ids = await service.fetchModelIds();
    return SettingsService.filterLiveModels(ids);
  } catch (e) {
    debugPrint('Could not fetch Groq models: $e');
    return const [];
  }
});

final openTabsProvider = StateProvider<List<EditorTab>>((ref) => []);
final activeTabIdProvider = StateProvider<String?>((ref) => null);
final cursorLineProvider = StateProvider<int>((ref) => 1);
final cursorColumnProvider = StateProvider<int>((ref) => 1);

/// Shared AI agent activity state surfaced by the status bar.
final isAiThinkingProvider = StateProvider<bool>((ref) => false);

/// The active backend, or null when it is not overridden (tests / early boot)
/// so the tree falls back to the Dart walk.
BackendService? _backendOrNull(Ref ref) {
  try {
    return ref.read(backendServiceProvider);
  } catch (_) {
    return null;
  }
}

/// Bumped by the native file watcher on every `fs.change` event. The file
/// tree watches it, so Explorer / Quick Open refresh without any manual
/// reload. (StateProvider bumping avoids invalidating the whole tree on each
/// event inside a stream listener.)
final fsChangeVersionProvider = StateProvider<int>((ref) => 0);

/// Debounce window: a build writes many files in a burst; coalesce the tree
/// refresh instead of re-enumerating 50k entries per event.
const fsRefreshDebounce = Duration(milliseconds: 150);

/// Wires the Zig engine's file watcher: subscribes to the current workspace
/// root, bumps [fsChangeVersionProvider] (refreshing the tree) and reloads
/// unmodified open tabs whose file changed on disk. Engine-less mode is a
/// no-op (MockBackendService exposes an empty stream).
final fsWatcherProvider = Provider<void>((ref) {
  final backend = _backendOrNull(ref);
  if (backend == null) return;
  final root = ref.watch(workspaceRootProvider);

  backend.watchWorkspace(root).catchError((Object _) {});

  Timer? debounce;
  final sub = backend.fsChangeStream.listen((change) {
    _reloadChangedTab(ref, root, change);
    debounce?.cancel();
    debounce = Timer(fsRefreshDebounce, () {
      ref.read(fsChangeVersionProvider.notifier).state++;
    });
  });

  ref.onDispose(() {
    debounce?.cancel();
    sub.cancel();
    backend.unwatchWorkspace().catchError((Object _) {});
  });
});

/// Reloads an open, unmodified tab whose file changed on disk (the watcher
/// only reports workspace-relative paths). Modified tabs keep the user's
/// unsaved edits; directory and deleted events are ignored.
Future<void> _reloadChangedTab(Ref ref, String root, FsChange change) async {
  if (change.isDirectory || change.kind == 'deleted') return;
  final abs =
      change.path.startsWith(root) ? change.path : '$root/${change.path}';
  final tabs = ref.read(openTabsProvider);
  final index = tabs.indexWhere((t) => t.path == abs);
  if (index < 0) return;
  final tab = tabs[index];
  if (tab.isModified) return;
  try {
    final content = await ref.read(workspaceServiceProvider).readFile(abs);
    if (content == tab.content) return;
    final updated = tab.copyWith(content: content);
    final newTabs = List<EditorTab>.from(tabs)..[index] = updated;
    ref.read(openTabsProvider.notifier).state = newTabs;
  } catch (_) {
    // File vanished between the event and the read — keep the tab as is.
  }
}

final fileTreeProvider = FutureProvider<List<FileTreeItem>>((ref) async {
  // Keep the native watcher alive and refresh on its events.
  ref.watch(fsWatcherProvider);
  ref.watch(fsChangeVersionProvider);
  final service = ref.watch(workspaceServiceProvider);
  return await service.loadTree(engine: _backendOrNull(ref));
});

final expandedPathsProvider = StateProvider<Set<String>>((ref) => {
      '/home/kaan/projeler/hiide',
      '/home/kaan/projeler/hiide/flutter_app',
      '/home/kaan/projeler/hiide/src',
    });

// ─── Recent workspaces ────────────────────────────────────────────────────────

final recentWorkspacesProvider = StateProvider<List<String>>((ref) => [
      '/home/kaan/projeler/hiide',
    ]);

// ─── Editor font size (reactive) ─────────────────────────────────────────────

final editorFontSizeProvider = StateProvider<double>((ref) => 14.0);
final editorWordWrapProvider = StateProvider<bool>((ref) => false);
final editorTabSizeProvider = StateProvider<int>((ref) => 4);

// ─── Keyboard shortcut overlay state ─────────────────────────────────────────

final showQuickOpenOverlayProvider = StateProvider<bool>((ref) => false);
final showCommandPaletteOverlayProvider = StateProvider<bool>((ref) => false);

// ─── Zen (focus) mode ────────────────────────────────────────────────────────

/// Focus mode: hides every chrome panel (explorer, side/bottom panels, status
/// bar) so only the editor (+ chat) remains. Toggled from the title bar.
final zenModeProvider = StateProvider<bool>((ref) => false);

// ─── Auto-save ───────────────────────────────────────────────────────────────

/// Whether the editor saves modified files automatically (debounced) after
/// typing. Defaults to on; `main()` overrides it with the persisted value.
final autoSaveEnabledProvider = StateProvider<bool>((ref) => true);

// ─── Recent files ───────────────────────────────────────────────────────────

/// A file the user opened recently, listed most-recent-first in the title
/// bar's history popup.
class RecentFile {
  final String path;
  final String title;

  const RecentFile({required this.path, required this.title});
}

final recentFilesProvider = StateProvider<List<RecentFile>>((ref) => []);

/// Pure recent-list update (most recent first, deduped, max 10) — extracted
/// so the ordering rules are unit-testable without a provider container.
List<RecentFile> withRecentFile(List<RecentFile> current, EditorTab tab) {
  if (tab.path == null || tab.path!.isEmpty) return current;
  return [
    RecentFile(path: tab.path!, title: tab.title),
    ...current.where((r) => r.path != tab.path),
  ].take(10).toList();
}

/// Records a file open in the recent list (most recent first, max 10).
void trackRecentFile(WidgetRef ref, EditorTab tab) {
  ref.read(recentFilesProvider.notifier).state =
      withRecentFile(ref.read(recentFilesProvider), tab);
}

/// Opens [path] as an editor tab (reading it from disk), or focuses it when
/// already open. Shared by the recent-files popup and the TODO list.
Future<void> openFileInTabs(WidgetRef ref, String path, {String? title}) async {
  final tabs = ref.read(openTabsProvider);
  final existing = tabs.indexWhere((t) => t.path == path);
  if (existing >= 0) {
    ref.read(activeTabIdProvider.notifier).state = tabs[existing].id;
    return;
  }
  final service = ref.read(workspaceServiceProvider);
  final content = await service.readFile(path);
  final tab = EditorTab(
    id: DateTime.now().millisecondsSinceEpoch.toString(),
    title: title ?? pathBasename(path),
    path: path,
    content: content,
    icon: iconForFilePath(path),
  );
  ref.read(openTabsProvider.notifier).state = [...tabs, tab];
  ref.read(activeTabIdProvider.notifier).state = tab.id;
  trackRecentFile(ref, tab);
}

/// Small icon map for tabs opened from paths (recent files, TODO list).
IconData iconForFilePath(String path) {
  final name = path.toLowerCase();
  if (name.endsWith('.dart')) return Icons.flutter_dash;
  if (name.endsWith('.zig')) return Icons.bolt;
  if (name.endsWith('.rs')) return Icons.settings_applications;
  if (name.endsWith('.md')) return Icons.description;
  if (name.endsWith('.json') ||
      name.endsWith('.yaml') ||
      name.endsWith('.yml') ||
      name.endsWith('.toml')) {
    return Icons.settings;
  }
  if (name.endsWith('.sh') || name.endsWith('.bash')) return Icons.terminal;
  return Icons.insert_drive_file_outlined;
}

/// Human-readable language label for a file path (status bar).
String languageForPath(String path) {
  final name = path.toLowerCase();
  if (name.endsWith('.dart')) return 'Dart';
  if (name.endsWith('.zig')) return 'Zig';
  if (name.endsWith('.rs')) return 'Rust';
  if (name.endsWith('.md')) return 'Markdown';
  if (name.endsWith('.py')) return 'Python';
  if (name.endsWith('.ts') || name.endsWith('.tsx')) return 'TypeScript';
  if (name.endsWith('.js') || name.endsWith('.jsx')) return 'JavaScript';
  if (name.endsWith('.yaml') || name.endsWith('.yml')) return 'YAML';
  if (name.endsWith('.json')) return 'JSON';
  if (name.endsWith('.toml')) return 'TOML';
  if (name.endsWith('.html')) return 'HTML';
  if (name.endsWith('.css')) return 'CSS';
  if (name.endsWith('.sh') || name.endsWith('.bash')) return 'Shell';
  if (name.endsWith('.txt')) return 'Plain Text';
  return '—';
}

// ─── Find & replace overlay ─────────────────────────────────────────────────

/// Whether the in-editor find bar is visible (Ctrl+F / Ctrl+H).
final findBarOpenProvider = StateProvider<bool>((ref) => false);

/// When true the find bar also shows the replace row (Ctrl+H).
final findReplaceModeProvider = StateProvider<bool>((ref) => false);

// ─── AI inline completion (Ctrl+Space) ──────────────────────────────────────

/// The AI completion text currently offered below the editor header; null
/// when idle. Accept with Tab, dismiss with Esc.
final aiCompletionProvider = StateProvider<String?>((ref) => null);

/// True while a completion request is in flight (spinner in the chip).
final aiCompletionLoadingProvider = StateProvider<bool>((ref) => false);

// ─── Workspace TODO / FIXME scan ────────────────────────────────────────────

/// Scans the workspace for TODO/FIXME/HACK/BUG markers and lists them for the
/// Problems panel. Re-runs when the file watcher bumps the tree version, so
/// new markers appear without a manual refresh. Bounded (file + result caps)
/// so huge workspaces stay snappy.
final todoScanProvider = FutureProvider<List<TodoIssue>>((ref) async {
  ref.watch(fsChangeVersionProvider);
  final tree = await ref.watch(fileTreeProvider.future);
  final service = ref.watch(workspaceServiceProvider);

  final files = <FileTreeItem>[];
  void collect(List<FileTreeItem> items) {
    for (final item in items) {
      if (item.isFile) {
        files.add(item);
      } else {
        collect(item.children);
      }
    }
  }

  collect(tree);

  final issues = <TodoIssue>[];
  const fileCap = 120;
  const issueCap = 500;
  final scan = files.length <= fileCap ? files : files.take(fileCap);
  for (final item in scan) {
    if (issues.length >= issueCap) break;
    try {
      final content = await service.readFile(item.path);
      if (content.length > 500000) continue; // skip huge / binary-ish files
      for (final m in extractTodos(content)) {
        issues.add(TodoIssue(
          file: item.path,
          line: m.line,
          kind: m.kind,
          text: m.text,
        ));
      }
    } catch (_) {
      // Unreadable file — skip.
    }
  }
  return issues;
});

// ─── UI layout mode ──────────────────────────────────────────────────────────

/// Active UI style, flipped by the slider in the title bar. Defaults to the
/// classic IDE layout; `main()` overrides it with the persisted value so the
/// user's last choice survives a restart.
final uiModeProvider = StateProvider<UiMode>((ref) => UiMode.ide);
