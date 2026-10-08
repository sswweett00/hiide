import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_store.dart';

/// Persists AI provider credentials, models and workspace preferences.
class SettingsService {
  SettingsService({SecretStore? secretStore})
      : _secretStore = secretStore ?? FlutterSecretStore();

  static const _keyApiKey = 'groq_api_key';
  static const _keyModel = 'groq_model';
  static const _keyLastWorkspace = 'last_workspace';
  static const _keyRecentWorkspaces = 'recent_workspaces';
  static const _keyAiProvider = 'ai_provider';
  static const _keyOpenaiApiKey = 'openai_api_key';
  static const _keyAnthropicApiKey = 'anthropic_api_key';
  static const _keyOllamaUrl = 'ollama_url';
  static const _keyAiApiKeys = 'ai_api_keys_v2';
  static const _keyAiModels = 'ai_provider_models_v2';
  static const _keyAiBaseUrls = 'ai_provider_base_urls_v1';
  static const _keyCustomAiProviders = 'ai_custom_providers_v1';

  static const List<String> availableModels = [
    'openai/gpt-oss-120b',
    'openai/gpt-oss-20b',
    'qwen/qwen3.8-27b',
    'minimaxai/minimax-m2.7',
  ];

  static const Set<String> excludedModels = {
    'groq/compound',
    'groq/compound-mini',
    'qwen/qwen3.6-27b',
    'llama-3.1-8b-instant',
    'llama-3.3-70b-versatile',
    'gemma2-9b-it',
    'mixtral-8x7b-32768',
    'llama3-70b-8192',
  };

  static List<String> filterLiveModels(List<String> ids) =>
      ids.where((id) => !excludedModels.contains(id)).toList();

  static String get defaultModel => availableModels.first;

  static const int minFontSize = 10;
  static const int maxFontSize = 32;
  static const int minTabSize = 1;
  static const int maxTabSize = 16;

  late SharedPreferences _prefs;
  SecretStore _secretStore;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    _initialized = true;
  }

  @visibleForTesting
  void resetForTesting() {
    _initialized = false;
    _secretStore = InMemorySecretStore();
  }

  String? _safeGetString(String key) {
    try {
      return _prefs.getString(key);
    } catch (_) {
      return null;
    }
  }

  Future<String> getApiKey() async {
    return getAiApiKey('groq');
  }

  static const _secretPrefix = 'hiide.ai.api_key.';
  static const _legacyPlaintextKeys = <String, String>{
    'groq': _keyApiKey,
    'openai': _keyOpenaiApiKey,
    'anthropic': _keyAnthropicApiKey,
  };

  Future<Map<String, String>> getAiApiKeys() async {
    await init();

    final secure = await _readSecureApiKeys();
    final migrated = await _migrateLegacyApiKeys(secure);
    final values = <String, String>{...secure, ...migrated};

    try {
      const envNames = <String, String>{
        'groq': 'GROQ_API_KEY',
        'openai': 'OPENAI_API_KEY',
        'openrouter': 'OPENROUTER_API_KEY',
        'deepseek': 'DEEPSEEK_API_KEY',
        'mistral': 'MISTRAL_API_KEY',
        'together': 'TOGETHER_API_KEY',
        'fireworks': 'FIREWORKS_API_KEY',
        'perplexity': 'PERPLEXITY_API_KEY',
        'xai': 'XAI_API_KEY',
        'gemini': 'GEMINI_API_KEY',
        'cerebras': 'CEREBRAS_API_KEY',
        'cohere': 'COHERE_API_KEY',
        'nvidia': 'NVIDIA_API_KEY',
        'sambanova': 'SAMBANOVA_API_KEY',
        'deepinfra': 'DEEPINFRA_API_KEY',
        'huggingface': 'HF_TOKEN',
        'qwen': 'DASHSCOPE_API_KEY',
        'siliconflow': 'SILICONFLOW_API_KEY',
        'novita': 'NOVITA_API_KEY',
        'baseten': 'BASETEN_API_KEY',
        'friendli': 'FRIENDLI_TOKEN',
        'ai21': 'AI21_API_KEY',
        'opencode-zen': 'OPENCODE_API_KEY',
        'litellm': 'LITELLM_API_KEY',
      };
      for (final entry in envNames.entries) {
        if ((values[entry.key] ?? '').isNotEmpty) continue;
        final key = Platform.environment[entry.value]?.trim() ?? '';
        if (key.isNotEmpty) values[entry.key] = key;
      }
    } catch (_) {}

    return values;
  }

  Future<Map<String, String>> _readSecureApiKeys() async {
    try {
      final raw = await _secretStore.readAll();
      final values = <String, String>{};
      for (final entry in raw.entries) {
        if (!entry.key.startsWith(_secretPrefix)) continue;
        final id = entry.key.substring(_secretPrefix.length).trim().toLowerCase();
        final value = entry.value.trim();
        if (id.isNotEmpty && value.isNotEmpty) values[id] = value;
      }
      return values;
    } on Exception {
      // Never fall back to plaintext storage when the secure store is
      // unavailable. Environment variables/local providers remain usable.
      return <String, String>{};
    }
  }

  Future<Map<String, String>> _migrateLegacyApiKeys(
    Map<String, String> existing,
  ) async {
    final legacy = <String, String>{};

    try {
      final raw = _safeGetString(_keyAiApiKeys);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final id = entry.key.toString().trim().toLowerCase();
            final value = entry.value?.toString().trim() ?? '';
            if (id.isNotEmpty && value.isNotEmpty) legacy[id] = value;
          }
        }
      }
    } catch (_) {}

    for (final entry in _legacyPlaintextKeys.entries) {
      final value = _safeGetString(entry.value)?.trim() ?? '';
      if (value.isNotEmpty) legacy.putIfAbsent(entry.key, () => value);
    }

    if (legacy.isEmpty) return <String, String>{};

    try {
      final secureRaw = await _secretStore.readAll();
      final toMigrate = <MapEntry<String, String>>[];
      for (final entry in legacy.entries) {
        if ((existing[entry.key] ?? '').isNotEmpty) continue;
        final secureKey = _secretPrefix + entry.key;
        if (!secureRaw.containsKey(secureKey)) {
          toMigrate.add(MapEntry(secureKey, entry.value));
        }
      }

      for (final entry in toMigrate) {
        await _secretStore.write(entry.key, entry.value);
      }

      // Once the secure store is reachable and contains every legacy value,
      // plaintext copies are no longer necessary.
      if (toMigrate.isNotEmpty || legacy.isNotEmpty) {
        await _prefs.remove(_keyAiApiKeys);
        for (final key in _legacyPlaintextKeys.values) {
          await _prefs.remove(key);
        }
      }

      return {
        for (final entry in legacy.entries)
          if ((existing[entry.key] ?? '').isEmpty) entry.key: entry.value,
      };
    } on Exception {
      // Secure-store failures must never trigger plaintext writes or deletes.
      // The legacy data stays untouched for a future successful migration.
      return <String, String>{};
    }
  }

  Future<String> getAiApiKey(String providerId) async {
    final id = providerId.trim().toLowerCase();
    if (id.isEmpty) return '';
    final values = await getAiApiKeys();
    return values[id] ?? '';
  }

  /// Legacy compatibility accessors used by application bootstrap.
  Future<String> getOpenaiApiKey() => getAiApiKey('openai');

  Future<String> getAnthropicApiKey() => getAiApiKey('anthropic');

  Future<void> setAiApiKey(String providerId, String key) async {
    await init();
    final id = providerId.trim().toLowerCase();
    if (id.isEmpty) return;
    final normalized = key.trim();
    final secureKey = _secretPrefix + id;

    try {
      if (normalized.isEmpty) {
        await _secretStore.delete(secureKey);
      } else {
        await _secretStore.write(secureKey, normalized);
      }
    } on Exception catch (error) {
      throw StateError(
        'Secure AI credential storage is unavailable: $error',
      );
    }

    // Remove all legacy plaintext copies for this provider after the secure
    // value is confirmed written/deleted.
    await _prefs.remove(_keyAiApiKeys);
    await _prefs.remove(_keyApiKey);
    await _prefs.remove(_keyOpenaiApiKey);
    await _prefs.remove(_keyAnthropicApiKey);
  }

  Future<void> setApiKey(String key) => setAiApiKey('groq', key);

  Future<String?> getLastWorkspace() async {
    await init();
    return _safeGetString(_keyLastWorkspace);
  }

  Future<void> setLastWorkspace(String? path) async {
    await init();
    if (path == null || path.trim().isEmpty) {
      await _prefs.remove(_keyLastWorkspace);
    } else {
      await _prefs.setString(_keyLastWorkspace, path.trim());
    }
  }

  Future<List<String>> getRecentWorkspaces() async {
    await init();
    final raw = _safeGetString(_keyRecentWorkspaces);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.whereType<String>().toList();
    } catch (_) {}
    return const [];
  }

  Future<void> setRecentWorkspaces(List<String> paths) async {
    await init();
    await _prefs.setString(
      _keyRecentWorkspaces,
      jsonEncode(paths.where((p) => p.trim().isNotEmpty).take(8).toList()),
    );
  }

  Future<String> getModel() async {
    await init();
    final stored = _safeGetString(_keyModel);
    if (stored != null && stored.isNotEmpty && !excludedModels.contains(stored)) {
      return stored;
    }
    return defaultModel;
  }

  Future<void> setModel(String model) async {
    await init();
    final normalized = model.trim();
    if (normalized.isEmpty || excludedModels.contains(normalized)) {
      await _prefs.setString(_keyModel, defaultModel);
      return;
    }
    await _prefs.setString(_keyModel, normalized);
  }

  Future<String> getAiProvider() async {
    await init();
    final provider = _safeGetString(_keyAiProvider)?.trim().toLowerCase();
    return provider == null || provider.isEmpty ? 'groq' : provider;
  }

  Future<void> setAiProvider(String provider) async {
    await init();
    final normalized = provider.trim().toLowerCase();
    if (normalized.isEmpty || normalized.length > 128) return;
    await _prefs.setString(_keyAiProvider, normalized);
  }

  Future<Map<String, String>> getAiProviderModels() async {
    await init();
    final raw = _safeGetString(_keyAiModels);
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      return {
        for (final entry in decoded.entries)
          if (entry.key.toString().trim().isNotEmpty &&
              (entry.value?.toString().trim() ?? '').isNotEmpty)
            entry.key.toString().trim().toLowerCase():
                entry.value.toString().trim(),
      };
    } catch (_) {
      return <String, String>{};
    }
  }

  Future<void> setAiProviderModel(String providerId, String model) async {
    await init();
    final id = providerId.trim().toLowerCase();
    if (id.isEmpty) return;
    final values = await getAiProviderModels();
    final normalized = model.trim();
    if (normalized.isEmpty) {
      values.remove(id);
    } else {
      values[id] = normalized;
    }
    await _prefs.setString(_keyAiModels, jsonEncode(values));
  }

  Future<Map<String, String>> getAiProviderBaseUrls() async {
    await init();
    final raw = _safeGetString(_keyAiBaseUrls);
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      return {
        for (final entry in decoded.entries)
          if (entry.key.toString().trim().isNotEmpty &&
              (entry.value?.toString().trim() ?? '').isNotEmpty)
            entry.key.toString().trim().toLowerCase():
                entry.value.toString().trim(),
      };
    } catch (_) {
      return <String, String>{};
    }
  }

  Future<void> setAiProviderBaseUrl(String providerId, String baseUrl) async {
    await init();
    final id = providerId.trim().toLowerCase();
    if (id.isEmpty) return;
    final values = await getAiProviderBaseUrls();
    final normalized = baseUrl.trim();
    if (normalized.isEmpty) {
      values.remove(id);
    } else if (normalized.length <= 512) {
      values[id] = normalized;
    }
    await _prefs.setString(_keyAiBaseUrls, jsonEncode(values));
  }

  Future<List<Map<String, String>>> getCustomAiProviders() async {
    await init();
    final raw = _safeGetString(_keyCustomAiProviders);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final result = <Map<String, String>>[];
      final seen = <String>{};
      for (final item in decoded) {
        if (item is! Map) continue;
        final id = item['id']?.toString().trim() ?? '';
        final name = item['name']?.toString().trim() ?? '';
        final baseUrl = item['baseUrl']?.toString().trim() ?? '';
        final model = item['model']?.toString().trim() ?? '';
        if (id.isEmpty || name.isEmpty || baseUrl.isEmpty || model.isEmpty) continue;
        if (!seen.add(id)) continue;
        result.add({
          'id': id,
          'name': name,
          'baseUrl': baseUrl,
          'model': model,
        });
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  Future<void> setCustomAiProviders(
      List<Map<String, String>> providers) async {
    await init();
    final clean = <Map<String, String>>[];
    final seen = <String>{};
    for (final raw in providers) {
      final id = raw['id']?.trim() ?? '';
      final name = raw['name']?.trim() ?? '';
      final baseUrl = raw['baseUrl']?.trim() ?? '';
      final model = raw['model']?.trim() ?? '';
      if (id.isEmpty || name.isEmpty || baseUrl.isEmpty || model.isEmpty) continue;
      if (id.length > 128 || name.length > 120 ||
          baseUrl.length > 512 || model.length > 256) {
        continue;
      }
      final normalizedId = id.toLowerCase();
      if (!seen.add(normalizedId)) continue;
      clean.add({
        'id': normalizedId,
        'name': name,
        'baseUrl': baseUrl,
        'model': model,
      });
      if (clean.length >= 32) break;
    }
    await _prefs.setString(_keyCustomAiProviders, jsonEncode(clean));
  }


  Future<String> getOllamaUrl() async {
    await init();
    final value = _safeGetString(_keyOllamaUrl)?.trim();
    return value == null || value.isEmpty ? 'http://127.0.0.1:11434' : value;
  }

  Future<void> setOllamaUrl(String url) async {
    await init();
    final normalized = url.trim();
    await _prefs.setString(
      _keyOllamaUrl,
      normalized.isEmpty ? 'http://127.0.0.1:11434' : normalized,
    );
  }
}


final settingsService = SettingsService();
