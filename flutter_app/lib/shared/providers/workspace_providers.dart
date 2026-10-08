import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/backend/backend_service.dart';
import '../../core/backend/groq_ai_service.dart';
import '../../core/backend/settings_service.dart';
import '../../core/backend/terminal_service.dart';
import '../../core/backend/workspace_service.dart';
import '../../core/providers/backend_provider.dart';
import '../models/file_tree_item.dart';
import '../models/todo_issue.dart';

final workspaceRootProvider = StateProvider<String>((ref) => '');

/// Set by main() after a persisted workspace was restored.
final workspaceRestoredProvider = StateProvider<bool>((ref) => false);

final selectedWorkspacePathProvider = StateProvider<String?>((ref) => null);

Future<String?> resolveStartupWorkspace() async {
  final stored = await settingsService.getLastWorkspace();
  if (stored == null || stored.trim().isEmpty) return null;
  try {
    if (Directory(stored).existsSync()) return stored;
  } catch (_) {}
  await settingsService.setLastWorkspace(null);
  return null;
}

Future<void> activateWorkspace(WidgetRef ref, String path) async {
  final root = WorkspaceService.normalizePath(path);
  ref.read(workspaceRootProvider.notifier).state = root;
  ref.read(selectedWorkspacePathProvider.notifier).state = null;

  final expanded = <String>{root};
  if (!kIsWeb) {
    try {
      final dir = Directory(root);
      if (dir.existsSync()) {
        for (final entity in dir.listSync(followLinks: false)) {
          if (entity is Directory &&
              !pathBasename(entity.path).startsWith('.')) {
            expanded.add(entity.path);
          }
        }
      }
    } catch (_) {}
  }
  ref.read(expandedPathsProvider.notifier).state = expanded;
  ref.invalidate(fileTreeProvider);

  try {
    await settingsService.setLastWorkspace(root);
    if (!ref.context.mounted) return;
    final recents = await settingsService.getRecentWorkspaces();
    if (!ref.context.mounted) return;
    final updated =
        [root, ...recents.where((r) => r != root)].take(8).toList();
    await settingsService.setRecentWorkspaces(updated);
    if (!ref.context.mounted) return;
    ref.read(recentWorkspacesProvider.notifier).state = updated;
  } catch (error) {
    debugPrint('Could not persist workspace selection: $error');
  }
}

final workspaceServiceProvider = Provider<WorkspaceService>((ref) {
  final root = ref.watch(workspaceRootProvider);
  return WorkspaceService(rootPath: root);
});

final terminalServiceProvider = Provider<TerminalService>((ref) {
  final root = ref.watch(workspaceRootProvider);
  final service = TerminalService(workingDirectory: root);
  ref.onDispose(() {
    unawaited(service.dispose());
  });
  return service;
});

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

final groqConnectionProvider =
    FutureProvider<({bool ok, String message})>((ref) async {
  final service = await ref.watch(groqAiServiceProvider.future);
  return service.checkConnection();
});

final groqLiveModelsProvider = FutureProvider<List<String>>((ref) async {
  final service = await ref.watch(groqAiServiceProvider.future);
  if (service.apiKey.isEmpty) return const [];
  try {
    return SettingsService.filterLiveModels(await service.fetchModelIds());
  } catch (e) {
    debugPrint('Could not fetch Groq models: $e');
    return const [];
  }
});

final isAiThinkingProvider = StateProvider<bool>((ref) => false);

BackendService? _backendOrNull(Ref ref) {
  try {
    return ref.read(backendServiceProvider);
  } catch (_) {
    return null;
  }
}

final fsChangeVersionProvider = StateProvider<int>((ref) => 0);

const fsRefreshDebounce = Duration(milliseconds: 150);

final fsWatcherProvider = Provider<void>((ref) {
  final backend = _backendOrNull(ref);
  if (backend == null) return;
  final root = ref.watch(workspaceRootProvider);
  if (root.isEmpty) return;

  backend.watchWorkspace(root).catchError((Object _) {});

  Timer? debounce;
  final sub = backend.fsChangeStream.listen((change) {
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

final fileTreeProvider = FutureProvider<List<FileTreeItem>>((ref) async {
  ref.watch(fsWatcherProvider);
  ref.watch(fsChangeVersionProvider);
  final service = ref.watch(workspaceServiceProvider);
  return service.loadTree(engine: _backendOrNull(ref));
});

final expandedPathsProvider = StateProvider<Set<String>>((ref) => <String>{});

final recentWorkspacesProvider = StateProvider<List<String>>((ref) => <String>[]);

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

  const fileCap = 120;
  const issueCap = 500;
  final scan = files.length <= fileCap ? files : files.take(fileCap);
  final issues = <TodoIssue>[];

  for (final item in scan) {
    if (issues.length >= issueCap) break;
    try {
      final content = await service.readFile(item.path);
      if (content.length > 500000) continue;
      for (final marker in extractTodos(content)) {
        issues.add(TodoIssue(
          file: item.path,
          line: marker.line,
          kind: marker.kind,
          text: marker.text,
        ));
      }
    } catch (_) {}
  }

  return issues;
});
