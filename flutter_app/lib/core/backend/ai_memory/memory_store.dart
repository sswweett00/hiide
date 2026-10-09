import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Stores AI memory entries: project context, user preferences, past
/// interactions, and code patterns. Persists to SharedPreferences.
class AiMemoryStore {
  static const _maxEntries = 200;
  static const _maxTokensPerEntry = 2000;

  late SharedPreferences _prefs;
  bool _initialized = false;
  Future<void> _writeQueue = Future<void>.value();

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
    final normalizedKey = _truncate(key.trim(), 160);
    if (normalizedKey.isEmpty) return;
    final normalizedValue = _truncate(value.trim(), _maxTokensPerEntry);
    await _serializeWrite(() async {
      final memories = await getProjectContext(workspaceRoot);
      memories[normalizedKey] = normalizedValue;
      // Keep persistence bounded even if an agent repeatedly learns new keys.
      while (memories.length > 64) {
        memories.remove(memories.keys.first);
      }
      await _prefs.setString(
        'ai_mem_ctx_$workspaceRoot',
        jsonEncode(memories),
      );
    });
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
    await _serializeWrite(() async {
      final entries = await _getConversations(workspaceRoot);
      final normalizedTopics = topics
          .map((topic) => _truncate(topic.trim().toLowerCase(), 80))
          .where((topic) => topic.isNotEmpty)
          .toSet()
          .take(24)
          .toList();
      final normalizedSummary = _truncate(summary.trim(), _maxTokensPerEntry);
      if (normalizedSummary.isEmpty) return;
      entries.insert(0, {
        'summary': normalizedSummary,
        'topics': normalizedTopics,
        'timestamp': DateTime.now().toIso8601String(),
      });
      if (entries.length > _maxEntries) {
        entries.removeRange(_maxEntries, entries.length);
      }
      await _prefs.setString(
        'ai_mem_conv_$workspaceRoot',
        jsonEncode(entries),
      );
    });
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
    final normalizedPattern = _truncate(pattern.trim(), 240);
    if (normalizedPattern.isEmpty) return;
    await _serializeWrite(() async {
      final patterns = await getCodePatterns(workspaceRoot);
      if (patterns.any((p) => p['pattern']?.toString() == normalizedPattern)) {
        return;
      }
      patterns.add({
        'pattern': normalizedPattern,
        'example': _truncate(example.trim(), 800),
        'timestamp': DateTime.now().toIso8601String(),
      });
      if (patterns.length > 50) {
        patterns.removeRange(0, patterns.length - 50);
      }
      await _prefs.setString(
        'ai_mem_patterns_$workspaceRoot',
        jsonEncode(patterns),
      );
    });
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
    await _serializeWrite(() async {
      final normalizedKey = _truncate(key.trim(), 120);
      if (normalizedKey.isEmpty) return;
      final prefs = await getPreferences();
      prefs[normalizedKey] = _truncate(value.trim(), 1000);
      while (prefs.length > 128) {
        prefs.remove(prefs.keys.first);
      }
      await _prefs.setString('ai_mem_prefs', jsonEncode(prefs));
    });
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

  Future<T> _serializeWrite<T>(Future<T> Function() action) {
    final result = _writeQueue.then<T>((_) => action());
    _writeQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  /// Builds a bounded, non-instructional memory context for an agent turn.
  ///
  /// Stored memory is reference data only. Callers should wrap the returned
  /// string as untrusted context so historical text cannot override the task.
  Future<String> buildContext({
    required String workspaceRoot,
    List<String> keywords = const <String>[],
    int maxChars = 8000,
  }) async {
    if (maxChars <= 0) return '';

    final normalizedKeywords = keywords
        .map((word) => word.trim().toLowerCase())
        .where((word) => word.isNotEmpty)
        .toSet()
        .toList();

    // Reserve space for each memory class so a single oversized project note
    // cannot starve relevant conversation history or learned code conventions.
    final conversationBudget = (maxChars * 0.45).floor();
    final patternBudget = (maxChars * 0.25).floor();
    final projectBudget = maxChars - conversationBudget - patternBudget;
    final sections = <String>[];

    final conversations = await searchConversations(
      workspaceRoot,
      normalizedKeywords,
    );
    final conversationSection = _boundedSection(
      'RELEVANT PAST TASK SUMMARIES',
      conversations
          .take(5)
          .map((entry) => entry['summary']?.toString() ?? '')
          .where((summary) => summary.trim().isNotEmpty)
          .toList(),
      conversationBudget,
    );
    if (conversationSection.isNotEmpty) sections.add(conversationSection);

    final patterns = await getCodePatterns(workspaceRoot);
    final patternSection = _boundedSection(
      'OBSERVED CODE PATTERNS',
      patterns.reversed.take(12).map((entry) {
        final pattern = entry['pattern']?.toString() ?? '';
        final example = entry['example']?.toString();
        return example == null || example.isEmpty
            ? pattern
            : '$pattern: $example';
      }).where((entry) => entry.trim().isNotEmpty).toList(),
      patternBudget,
    );
    if (patternSection.isNotEmpty) sections.add(patternSection);

    final project = await getProjectContext(workspaceRoot);
    final projectSection = _boundedSection(
      'PROJECT CONTEXT',
      project.entries
          .take(32)
          .map((entry) => '${entry.key}: ${entry.value}')
          .toList(),
      projectBudget,
    );
    if (projectSection.isNotEmpty) sections.add(projectSection);

    return sections.join('\n\n');
  }

  String _boundedSection(String title, List<String> entries, int budget) {
    if (budget <= title.length + 2 || entries.isEmpty) return '';
    final lines = <String>[title];
    var used = title.length;
    for (final entry in entries) {
      final remaining = budget - used - 2;
      if (remaining <= 0) break;
      final line = '- ' + _truncate(entry, remaining - 2);
      if (line.length <= 2) break;
      lines.add(line);
      used += line.length + 1;
    }
    if (lines.length == 1) return '';
    return lines.join('\n');
  }

  // ─── Cleanup ─────────────────────────────────────────────────────────────

  /// Clears all memory for a workspace.
  Future<void> clearWorkspace(String workspaceRoot) async {
    await init();
    await _serializeWrite(() async {
      await _prefs.remove('ai_mem_ctx_$workspaceRoot');
      await _prefs.remove('ai_mem_conv_$workspaceRoot');
      await _prefs.remove('ai_mem_patterns_$workspaceRoot');
    });
  }

  /// Clears all memory.
  Future<void> clearAll() async {
    await init();
    await _serializeWrite(() async {
      final keys = _prefs.getKeys();
      for (final key in keys) {
        if (key.startsWith('ai_mem_')) {
          await _prefs.remove(key);
        }
      }
    });
  }

  String _truncate(String text, int maxLen) {
    if (text.length <= maxLen) return text;
    return '${text.substring(0, maxLen)}...';
  }
}

/// Singleton instance
final aiMemoryStore = AiMemoryStore();
