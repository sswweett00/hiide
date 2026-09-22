import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Caches AI responses to avoid redundant API calls for identical queries.
/// Uses a hash of the prompt + model as the cache key.
class AiResponseCache {
  static const _maxEntries = 500;
  static const _maxResponseBytes = 512 * 1024;
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

    final responseBytes = utf8.encode(response);
    if (responseBytes.length > _maxResponseBytes) {
      throw ArgumentError.value(response.length, 'response', 'AI response exceeds cache size limit');
    }

    // Evict expired entries first, then oldest entries deterministically.
    await _evictIfNeeded(key);

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
    // Length-delimited input avoids ambiguous concatenation boundaries.
    final input = [
      model.length.toString(),
      model,
      (systemPrompt ?? '').length.toString(),
      systemPrompt ?? '',
      prompt.length.toString(),
      prompt,
    ].join(':');
    return sha256.convert(utf8.encode(input)).toString();
  }

  Future<void> _evictIfNeeded(String incomingKey) async {
    final entries = <({String key, DateTime timestamp})>[];
    final now = DateTime.now();

    for (final key in _prefs.getKeys().where((k) => k.startsWith('aican_cache_'))) {
      if (key == 'aican_cache_$incomingKey') continue;
      final raw = _prefs.getString(key);
      if (raw == null) {
        await _prefs.remove(key);
        continue;
      }
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        final timestamp = DateTime.parse(decoded['timestamp'] as String);
        if (now.difference(timestamp) > _defaultTtl) {
          await _prefs.remove(key);
          continue;
        }
        entries.add((key: key, timestamp: timestamp));
      } catch (_) {
        await _prefs.remove(key);
      }
    }

    final retained = entries.length;
    if (retained < _maxEntries) return;

    entries.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final removeCount = retained - _maxEntries + 1;
    for (var i = 0; i < removeCount; i++) {
      await _prefs.remove(entries[i].key);
    }
  }
}

/// Singleton instance
final aiResponseCache = AiResponseCache();
