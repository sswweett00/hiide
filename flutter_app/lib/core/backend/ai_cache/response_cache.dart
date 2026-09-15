import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Caches AI responses to avoid redundant API calls for identical queries.
/// Uses a hash of the prompt + model as the cache key.
class AiResponseCache {
  static const _maxEntries = 500;
  static const _defaultTtl = Duration(hours: 1);

  late SharedPreferences _prefs;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    _initialized = true;
  }

  /// Returns a cached response for the given prompt, or null if expired/missing.
  Future<String?> get({
    required String prompt,
    required String model,
    String? systemPrompt,
  }) async {
    await init();
    final key = _cacheKey(prompt: prompt, model: model, systemPrompt: systemPrompt);
    final raw = _prefs.getString('aican_cache_$key');
    if (raw == null || raw.isEmpty) return null;

    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final timestamp = DateTime.parse(decoded['timestamp'] as String);
      if (DateTime.now().difference(timestamp) > _defaultTtl) {
        await _prefs.remove('aican_cache_$key');
        return null;
      }
      return decoded['response'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Stores a response in the cache.
  Future<void> put({
    required String prompt,
    required String model,
    required String response,
    String? systemPrompt,
  }) async {
    await init();
    final key = _cacheKey(prompt: prompt, model: model, systemPrompt: systemPrompt);

    // Evict oldest if at capacity
    await _evictIfNeeded();

    await _prefs.setString(
      'aican_cache_$key',
      jsonEncode({
        'response': response,
        'timestamp': DateTime.now().toIso8601String(),
      }),
    );
  }

  /// Clears all cached entries.
  Future<void> clear() async {
    await init();
    final keys = _prefs.getKeys().where((k) => k.startsWith('aican_cache_'));
    for (final key in keys) {
      await _prefs.remove(key);
    }
  }

  /// Returns the number of cached entries.
  Future<int> size() async {
    await init();
    return _prefs.getKeys().where((k) => k.startsWith('aican_cache_')).length;
  }

  String _cacheKey({
    required String prompt,
    required String model,
    String? systemPrompt,
  }) {
    final input = '$model:${systemPrompt ?? ""}:$prompt';
    return md5.convert(utf8.encode(input)).toString();
  }

  Future<void> _evictIfNeeded() async {
    final keys = _prefs.getKeys().where((k) => k.startsWith('aican_cache_')).toList();
    if (keys.length < _maxEntries) return;

    // Remove oldest 20%
    final toRemove = (keys.length * 0.2).ceil();
    for (var i = 0; i < toRemove && i < keys.length; i++) {
      await _prefs.remove(keys[i]);
    }
  }
}

/// Singleton instance
final aiResponseCache = AiResponseCache();
