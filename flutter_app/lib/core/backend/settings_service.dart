import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists IDE settings including AI provider keys and editor preferences.
class SettingsService {
  static const _keyApiKey = 'groq_api_key';
  static const _keyModel = 'groq_model';
  static const _keyLastWorkspace = 'last_workspace';
  static const _keyRecentWorkspaces = 'recent_workspaces';
  static const _keyFontSize = 'editor_font_size';
  static const _keyTabSize = 'editor_tab_size';
  static const _keyWordWrap = 'editor_word_wrap';
  static const _keyMinimap = 'editor_minimap';
  static const _keyAutoSave = 'editor_auto_save';
  static const _keyUiMode = 'ui_mode';
  static const _keyAiProvider = 'ai_provider';
  static const _keyOpenaiApiKey = 'openai_api_key';
  static const _keyAnthropicApiKey = 'anthropic_api_key';
  static const _keyOllamaUrl = 'ollama_url';

  static const List<String> availableModels = [
    'llama-3.1-8b-instant',
    'llama-3.3-70b-versatile',
    'openai/gpt-oss-20b',
    'openai/gpt-oss-120b',
    'qwen/qwen3.6-27b',
    'groq/compound',
    'allam-2-7b',
  ];

  static const Set<String> excludedModels = {
    'gemma2-9b-it',
    'mixtral-8x7b-32768',
    'llama3-70b-8192',
    'groq/compound-mini',
  };

  static List<String> filterLiveModels(List<String> ids) =>
      ids.where((id) => !excludedModels.contains(id)).toList();

  static String get defaultModel => availableModels.first;

  static const int minFontSize = 10;
  static const int maxFontSize = 32;
  static const int minTabSize = 1;
  static const int maxTabSize = 16;

  late SharedPreferences _prefs;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    _initialized = true;
  }

  @visibleForTesting
  void resetForTesting() => _initialized = false;

  String? _safeGetString(String key) {
    try {
      return _prefs.getString(key);
    } catch (_) {
      return null;
    }
  }

  int? _safeGetInt(String key) {
    try {
      return _prefs.getInt(key);
    } catch (_) {
      return null;
    }
  }

  bool? _safeGetBool(String key) {
    try {
      return _prefs.getBool(key);
    } catch (_) {
      return null;
    }
  }

  Future<String> getApiKey() async {
    await init();
    final stored = _safeGetString(_keyApiKey);
    if (stored != null && stored.trim().isNotEmpty) return stored.trim();

    try {
      final envKey = Platform.environment['GROQ_API_KEY'];
      if (envKey != null && envKey.trim().isNotEmpty) return envKey.trim();
    } catch (_) {}

    final home = Platform.environment['HOME'] ?? '';
    final candidates = [
      'groq-api-key',
      '../groq-api-key',
      '../../groq-api-key',
      if (home.isNotEmpty) '$home/.groq-api-key',
    ];
    for (final path in candidates) {
      try {
        final file = File(path);
        if (await file.exists()) {
          final content = (await file.readAsString()).trim();
          if (content.isNotEmpty) return content;
        }
      } catch (_) {}
    }
    return '';
  }

  Future<void> setApiKey(String key) async {
    await init();
    await _prefs.setString(_keyApiKey, key.trim());
  }

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

  Future<int> getFontSize() async {
    await init();
    return (_safeGetInt(_keyFontSize) ?? 14).clamp(minFontSize, maxFontSize);
  }

  Future<void> setFontSize(int size) async {
    await init();
    await _prefs.setInt(_keyFontSize, size.clamp(minFontSize, maxFontSize));
  }

  Future<int> getTabSize() async {
    await init();
    return (_safeGetInt(_keyTabSize) ?? 4).clamp(minTabSize, maxTabSize);
  }

  Future<void> setTabSize(int size) async {
    await init();
    await _prefs.setInt(_keyTabSize, size.clamp(minTabSize, maxTabSize));
  }

  Future<bool> getWordWrap() async {
    await init();
    return _safeGetBool(_keyWordWrap) ?? false;
  }

  Future<void> setWordWrap(bool value) async {
    await init();
    await _prefs.setBool(_keyWordWrap, value);
  }

  Future<bool> getMinimap() async {
    await init();
    return _safeGetBool(_keyMinimap) ?? true;
  }

  Future<void> setMinimap(bool value) async {
    await init();
    await _prefs.setBool(_keyMinimap, value);
  }

  Future<bool> getAutoSave() async {
    await init();
    return _safeGetBool(_keyAutoSave) ?? true;
  }

  Future<void> setAutoSave(bool value) async {
    await init();
    await _prefs.setBool(_keyAutoSave, value);
  }

  Future<UiMode> getUiMode() async {
    await init();
    final stored = _safeGetString(_keyUiMode);
    return switch (stored) {
      'aiNative' => UiMode.aiNative,
      'ide' => UiMode.ide,
      _ => UiMode.ide,
    };
  }

  Future<void> setUiMode(UiMode mode) async {
    await init();
    await _prefs.setString(_keyUiMode, mode.name);
  }

  Future<String> getAiProvider() async {
    await init();
    final provider = _safeGetString(_keyAiProvider)?.trim().toLowerCase();
    return switch (provider) {
      'groq' => 'groq',
      'openai' => 'openai',
      'anthropic' => 'anthropic',
      'ollama' => 'ollama',
      _ => 'groq',
    };
  }

  Future<void> setAiProvider(String provider) async {
    await init();
    final normalized = provider.trim().toLowerCase();
    final safe = const {'groq', 'openai', 'anthropic', 'ollama'};
    await _prefs.setString(_keyAiProvider, safe.contains(normalized) ? normalized : 'groq');
  }

  Future<String> getOpenaiApiKey() async {
    await init();
    return _safeGetString(_keyOpenaiApiKey)?.trim() ?? '';
  }

  Future<void> setOpenaiApiKey(String key) async {
    await init();
    await _prefs.setString(_keyOpenaiApiKey, key.trim());
  }

  Future<String> getAnthropicApiKey() async {
    await init();
    return _safeGetString(_keyAnthropicApiKey)?.trim() ?? '';
  }

  Future<void> setAnthropicApiKey(String key) async {
    await init();
    await _prefs.setString(_keyAnthropicApiKey, key.trim());
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

enum UiMode { aiNative, ide }

final settingsService = SettingsService();
