import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Stores AI memory entries: project context, user preferences, past
/// interactions, and code patterns. Persists to SharedPreferences.
class AiMemoryStore {
  static const _maxEntries = 200;
  static const _maxTokensPerEntry = 2000;

  late SharedPreferences _prefs;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    _initialized = true;
  }

  // ─── Project Context Memory ──────────────────────────────────────────────

  /// Stores key facts about the project (architecture, conventions, etc.)
  Future<void> storeProjectContext({
    required String workspaceRoot,
    required String key,
    required String value,
  }) async {
    await init();
    final memories = await getProjectContext(workspaceRoot);
    memories[key] = value;
    await _prefs.setString(
      'ai_mem_ctx_$workspaceRoot',
      jsonEncode(memories),
    );
  }

  Future<Map<String, String>> getProjectContext(String workspaceRoot) async {
    await init();
    final raw = _prefs.getString('ai_mem_ctx_$workspaceRoot');
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {}
    return {};
  }

  // ─── Conversation Memory ────────────────────────────────────────────────

  /// Stores a summary of a past conversation for future reference.
  Future<void> storeConversationSummary({
    required String workspaceRoot,
    required String summary,
    required List<String> topics,
  }) async {
    await init();
    final entries = await _getConversations(workspaceRoot);
    entries.insert(0, {
      'summary': summary,
      'topics': topics,
      'timestamp': DateTime.now().toIso8601String(),
    });
    // Keep only the most recent entries
    if (entries.length > _maxEntries) {
      entries.removeRange(_maxEntries, entries.length);
    }
    await _prefs.setString(
      'ai_mem_conv_$workspaceRoot',
      jsonEncode(entries),
    );
  }

  Future<List<Map<String, dynamic>>> _getConversations(
      String workspaceRoot) async {
    await init();
    final raw = _prefs.getString('ai_mem_conv_$workspaceRoot');
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map<String, dynamic>>()
            .toList();
      }
    } catch (_) {}
    return [];
  }

  /// Retrieves relevant past conversations based on topic keywords.
  Future<List<Map<String, dynamic>>> searchConversations(
    String workspaceRoot,
    List<String> keywords,
  ) async {
    final all = await _getConversations(workspaceRoot);
    if (keywords.isEmpty) return all.take(5).toList();

    final scored = all.map((entry) {
      final topics = (entry['topics'] as List?)
              ?.map((t) => t.toString().toLowerCase())
              .toList() ??
          [];
      var score = 0;
      for (final kw in keywords) {
        final lower = kw.toLowerCase();
        if (topics.any((t) => t.contains(lower))) score += 2;
        final summary = entry['summary']?.toString().toLowerCase() ?? '';
        if (summary.contains(lower)) score += 1;
      }
      return (score: score, entry: entry);
    }).toList();

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored
        .where((s) => s.score > 0)
        .take(5)
        .map((s) => s.entry)
        .toList();
  }

  // ─── Code Pattern Memory ────────────────────────────────────────────────

  /// Stores a code pattern the AI observed (naming convention, structure, etc.)
  Future<void> storeCodePattern({
    required String workspaceRoot,
    required String pattern,
    required String example,
  }) async {
    await init();
    final patterns = await getCodePatterns(workspaceRoot);
    // Deduplicate
    if (patterns.any((p) =>
        p['pattern']?.toString() == pattern)) return;
    patterns.add({
      'pattern': pattern,
      'example': _truncate(example, _maxTokensPerEntry),
      'timestamp': DateTime.now().toIso8601String(),
    });
    if (patterns.length > 50) {
      patterns.removeRange(0, patterns.length - 50);
    }
    await _prefs.setString(
      'ai_mem_patterns_$workspaceRoot',
      jsonEncode(patterns),
    );
  }

  Future<List<Map<String, dynamic>>> getCodePatterns(
      String workspaceRoot) async {
    await init();
    final raw = _prefs.getString('ai_mem_patterns_$workspaceRoot');
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<Map<String, dynamic>>().toList();
      }
    } catch (_) {}
    return [];
  }

  // ─── User Preference Memory ─────────────────────────────────────────────

  /// Stores a user preference learned from interactions.
  Future<void> storePreference({
    required String key,
    required String value,
  }) async {
    await init();
    final prefs = await getPreferences();
    prefs[key] = value;
    await _prefs.setString('ai_mem_prefs', jsonEncode(prefs));
  }

  Future<Map<String, String>> getPreferences() async {
    await init();
    final raw = _prefs.getString('ai_mem_prefs');
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {}
    return {};
  }

  // ─── Cleanup ─────────────────────────────────────────────────────────────

  /// Clears all memory for a workspace.
  Future<void> clearWorkspace(String workspaceRoot) async {
    await init();
    await _prefs.remove('ai_mem_ctx_$workspaceRoot');
    await _prefs.remove('ai_mem_conv_$workspaceRoot');
    await _prefs.remove('ai_mem_patterns_$workspaceRoot');
  }

  /// Clears all memory.
  Future<void> clearAll() async {
    await init();
    final keys = _prefs.getKeys();
    for (final key in keys) {
      if (key.startsWith('ai_mem_')) {
        await _prefs.remove(key);
      }
    }
  }

  String _truncate(String text, int maxLen) {
    if (text.length <= maxLen) return text;
    return '${text.substring(0, maxLen)}...';
  }
}

/// Singleton instance
final aiMemoryStore = AiMemoryStore();
