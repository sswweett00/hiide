import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class WorkspaceSession {
  final String workspace;
  final List<String> openPaths;
  final String? activePath;
  final Set<String> expandedPaths;

  const WorkspaceSession({
    required this.workspace,
    required this.openPaths,
    required this.activePath,
    required this.expandedPaths,
  });

  Map<String, dynamic> toJson() => {
        'workspace': workspace,
        'openPaths': openPaths,
        'activePath': activePath,
        'expandedPaths': expandedPaths.toList(),
      };

  static WorkspaceSession? fromJson(Object? value) {
    if (value is! Map) return null;
    final workspace = value['workspace'];
    final openPaths = value['openPaths'];
    final activePath = value['activePath'];
    final expandedPaths = value['expandedPaths'];
    if (workspace is! String || workspace.isEmpty || openPaths is! List) return null;
    return WorkspaceSession(
      workspace: workspace,
      openPaths: openPaths.whereType<String>().where((p) => p.isNotEmpty).toList(),
      activePath: activePath is String && activePath.isNotEmpty ? activePath : null,
      expandedPaths: expandedPaths is List
          ? expandedPaths.whereType<String>().toSet()
          : <String>{},
    );
  }
}

/// Persists the editor session independently from general settings. This keeps
/// startup restoration resilient when UI preferences become corrupted.
class WorkspaceSessionStore {
  static const _key = 'hiide.workspace-session.v1';

  Future<WorkspaceSession?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return null;
    try {
      return WorkspaceSession.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> save(WorkspaceSession session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(session.toJson()));
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
