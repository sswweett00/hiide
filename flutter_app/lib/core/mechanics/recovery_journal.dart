import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class RecoveryEntry {
  final String path;
  final String content;
  final DateTime updatedAt;

  const RecoveryEntry({
    required this.path,
    required this.content,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'path': path,
        'content': content,
        'updatedAt': updatedAt.toIso8601String(),
      };

  static RecoveryEntry? fromJson(Object? value) {
    if (value is! Map) return null;
    final path = value['path'];
    final content = value['content'];
    final stamp = value['updatedAt'];
    if (path is! String || path.isEmpty || content is! String || stamp is! String) {
      return null;
    }
    final parsed = DateTime.tryParse(stamp);
    if (parsed == null) return null;
    return RecoveryEntry(path: path, content: content, updatedAt: parsed);
  }
}

/// Small write-ahead recovery journal stored in preferences. Corrupt entries
/// are ignored and the entire payload is replaced on the next write.
class RecoveryJournal {
  static const _storageKey = 'hiide.recovery.v1';

  Future<List<RecoveryEntry>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final data = jsonDecode(raw);
      if (data is! List) return const [];
      return data.map(RecoveryEntry.fromJson).whereType<RecoveryEntry>().toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> put(String path, String content) async {
    final current = await load();
    final next = <RecoveryEntry>[
      RecoveryEntry(path: path, content: content, updatedAt: DateTime.now()),
      ...current.where((entry) => entry.path != path),
    ].take(32).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(next.map((e) => e.toJson()).toList()));
  }

  Future<void> remove(String path) async {
    final next = (await load()).where((entry) => entry.path != path).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(next.map((e) => e.toJson()).toList()));
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
  }
}
