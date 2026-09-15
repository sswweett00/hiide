import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists IDE settings including the Groq API key and selected model.
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

  /// Curated fallback model list — mirrors `curated_models` in
  /// `src/core/provider/groq.zig` (same ids, same order).
  ///
  /// Retired ids (gemma2-9b-it, mixtral-8x7b-32768, llama3-70b-8192) are
  /// excluded because selecting one 404s on every API call. Only models that
  /// support OpenAI-style function calling are listed: the agent loop depends
  /// on tools. This list is the OFFLINE fallback; once a valid API key is
  /// configured, Settings fetches the live `/models` response from Groq and
  /// the dropdown prefers that over this list.
  ///
  /// Order: fast/instant models first (matches the Zig engine's preference).
  static const List<String> availableModels = [
    'llama-3.1-8b-instant',   // default — fast, low-latency IDE chat
    'llama-3.3-70b-versatile',
    'openai/gpt-oss-20b',
    'openai/gpt-oss-120b',
    'qwen/qwen3.6-27b',
    'groq/compound',
    'allam-2-7b',
  ];

  /// Models the Groq API serves that must never be selectable: retired ids
  /// 404 on every request. `groq/compound-mini` does not support OpenAI-style
  /// function calling, which the agent loop requires. Used to filter the live
  /// `/models` response and to sanitize a persisted selection.
  static const Set<String> excludedModels = {
    'gemma2-9b-it',
    'mixtral-8x7b-32768',
    'llama3-70b-8192',
    'groq/compound-mini',
  };

  /// Filters a live `/models` response down to ids that are safe to select.
  static List<String> filterLiveModels(List<String> ids) =>
      ids.where((id) => !excludedModels.contains(id)).toList();

  /// The model used when nothing is configured. Kept as the first entry of
  /// [availableModels] so the settings screen default stays in sync.
  static String get defaultModel => availableModels.first;

  late SharedPreferences _prefs;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    _initialized = true;
  }

  /// Drops the cached prefs handle so the next [init] re-reads storage.
  /// Test-only: lets a test inject new [SharedPreferences.setMockInitialValues]
  /// state between cases.
  @visibleForTesting
  void resetForTesting() {
    _initialized = false;
  }

  // ─── API Key ───────────────────────────────────────────────────────────────

  /// Reads a stored string, tolerating any stored format. SharedPreferences
  /// (especially the web backend, which JSON-decodes every value) throws a
  /// cast error when a key holds a value from an older app version, manual
  /// localStorage edits, or another tool — that must never crash a caller
  /// (it used to abort workspace activation mid-flight).
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

  /// Returns the stored API key, or reads from environment/key file as fallback.
  Future<String> getApiKey() async {
    await init();
    final stored = _safeGetString(_keyApiKey);
    if (stored != null && stored.trim().isNotEmpty) return stored.trim();

    // Check environment variable
    try {
      final envKey = Platform.environment['GROQ_API_KEY'];
      if (envKey != null && envKey.trim().isNotEmpty) {
        return envKey.trim();
      }
    } catch (_) {}

    // Fallback: read from key file candidates
    final home = Platform.environment['HOME'] ?? '';
    final candidates = [
      'groq-api-key',
      '../groq-api-key',
      '../../groq-api-key',
      '/home/kaan/projeler/hiide/groq-api-key',
      if (home.isNotEmpty) '$home/.groq-api-key',
    ];
    for (final p in candidates) {
      try {
        final file = File(p);
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

  // ─── Workspace ───────────────────────────────────────────────────────────

  /// The workspace folder opened on the last run, or null on first launch.
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

  /// Recently opened workspaces, most recent first (max 8). Tolerates a
  /// wrong-format stored value (old builds, manual edits): a corrupted entry
  /// yields an empty list, and the next [setRecentWorkspaces] overwrites it
  /// with the correct format — self-healing instead of crash-prone.
  Future<List<String>> getRecentWorkspaces() async {
    await init();
    final raw = _safeGetString(_keyRecentWorkspaces);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<String>().toList();
      }
    } catch (_) {}
    return const [];
  }

  Future<void> setRecentWorkspaces(List<String> paths) async {
    await init();
    await _prefs.setString(
        _keyRecentWorkspaces, jsonEncode(paths.take(8).toList()));
  }

  // ─── Model ────────────────────────────────────────────────────────────────

  /// Returns the stored model, falling back to [defaultModel]. A model known
  /// to be retired from the API (or lacking tool support) is sanitized to the
  /// current default so the agent never sends a dead model id. Models picked
  /// from the live `/models` list are kept even when they are not in the
  /// curated [availableModels].
  Future<String> getModel() async {
    await init();
    final stored = _safeGetString(_keyModel);
    if (stored != null &&
        stored.isNotEmpty &&
        !excludedModels.contains(stored)) {
      return stored;
    }
    return defaultModel;
  }

  Future<void> setModel(String model) async {
    await init();
    await _prefs.setString(_keyModel, model);
  }

  // ─── Editor Preferences ───────────────────────────────────────────────────

  Future<int> getFontSize() async {
    await init();
    return _safeGetInt(_keyFontSize) ?? 14;
  }

  Future<void> setFontSize(int size) async {
    await init();
    await _prefs.setInt(_keyFontSize, size);
  }

  Future<int> getTabSize() async {
    await init();
    return _safeGetInt(_keyTabSize) ?? 4;
  }

  Future<void> setTabSize(int size) async {
    await init();
    await _prefs.setInt(_keyTabSize, size);
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

  // ─── UI Mode ──────────────────────────────────────────────────────────────

  /// The UI style (AI-native chat vs classic IDE shell) selected on the last
  /// run. Unknown, empty or corrupt stored values fall back to the classic
  /// IDE layout.
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

  // ─── AI Provider Settings ───────────────────────────────────────────────

  Future<String> getAiProvider() async {
    await init();
    return _safeGetString(_keyAiProvider) ?? 'groq';
  }

  Future<void> setAiProvider(String provider) async {
    await init();
    await _prefs.setString(_keyAiProvider, provider);
  }

  Future<String> getOpenaiApiKey() async {
    await init();
    return _safeGetString(_keyOpenaiApiKey) ?? '';
  }

  Future<void> setOpenaiApiKey(String key) async {
    await init();
    await _prefs.setString(_keyOpenaiApiKey, key.trim());
  }

  Future<String> getAnthropicApiKey() async {
    await init();
    return _safeGetString(_keyAnthropicApiKey) ?? '';
  }

  Future<void> setAnthropicApiKey(String key) async {
    await init();
    await _prefs.setString(_keyAnthropicApiKey, key.trim());
  }

  Future<String> getOllamaUrl() async {
    await init();
    return _safeGetString(_keyOllamaUrl) ?? 'http://127.0.0.1:11434';
  }

  Future<void> setOllamaUrl(String url) async {
    await init();
    await _prefs.setString(_keyOllamaUrl, url.trim());
  }
}

/// The two top-level UI styles: the full-screen AI chat (AI native) and the
/// classic IDE shell (explorer + editor + terminal + chat sidebar).
enum UiMode { aiNative, ide }

/// Singleton instance
final settingsService = SettingsService();
