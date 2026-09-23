// Verifies the model list shipped in SettingsService: only models the Groq
// API currently serves (and that support function calling) are advertised,
// and a retired model persisted in storage is sanitized to the default.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hiide_flutter/core/backend/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('availableModels only contains live, tool-calling-capable models', () {
    // Verified against the Groq /models endpoint: these ids are retired and
    // every request 404s — they must never be selectable.
    const retired = {'gemma2-9b-it', 'mixtral-8x7b-32768', 'llama3-70b-8192'};
    for (final m in SettingsService.availableModels) {
      expect(retired.contains(m), isFalse, reason: '$m was retired');
    }

    // groq/compound-mini exists on the API but does NOT support function
    // calling, so the agent loop cannot use it.
    expect(SettingsService.availableModels.contains('groq/compound-mini'),
        isFalse);

    // The default is the first entry and is itself valid.
    expect(SettingsService.defaultModel, SettingsService.availableModels.first);
    expect(SettingsService.availableModels,
        contains(SettingsService.defaultModel));
  });

  test('getModel sanitizes a retired stored model to the default', () async {
    settingsService.resetForTesting();
    SharedPreferences.setMockInitialValues(
        {'groq_model': 'mixtral-8x7b-32768'});

    expect(await settingsService.getModel(), SettingsService.defaultModel);
  });

  test('getModel keeps a still-valid stored model', () async {
    settingsService.resetForTesting();
    SharedPreferences.setMockInitialValues(
        {'groq_model': 'llama-3.3-70b-versatile'});

    expect(await settingsService.getModel(), 'llama-3.3-70b-versatile');
  });

  test('getModel keeps a model picked from the live /models list', () async {
    // A model chosen from the live list may not be in the curated
    // availableModels — it must still survive a restart, unlike a retired id.
    settingsService.resetForTesting();
    SharedPreferences.setMockInitialValues(
        {'groq_model': 'llama-4-scout-17b-16e-instruct'});

    expect(await settingsService.getModel(), 'llama-4-scout-17b-16e-instruct');
  });

  test('filterLiveModels drops retired and non-tool-calling ids', () {
    final live = [
      'llama-3.3-70b-versatile',
      'openai/gpt-oss-120b',
      'groq/compound-mini',
      'mixtral-8x7b-32768',
      'llama-4-scout-17b-16e-instruct',
    ];

    expect(SettingsService.filterLiveModels(live), [
      'llama-3.3-70b-versatile',
      'openai/gpt-oss-120b',
      'llama-4-scout-17b-16e-instruct',
    ]);
  });

  // SharedPreferences (web especially) can hold values in a legacy or
  // foreign format — a stale/contaminated entry must never crash a read
  // (it used to abort workspace activation on the web).

  test('getRecentWorkspaces tolerates a Map stored under the key', () async {
    settingsService.resetForTesting();
    SharedPreferences.setMockInitialValues({
      'recent_workspaces': {'bad': 'format'},
    });

    expect(await settingsService.getRecentWorkspaces(), isEmpty);
  });

  test('getRecentWorkspaces tolerates a List of non-strings', () async {
    settingsService.resetForTesting();
    SharedPreferences.setMockInitialValues({
      'recent_workspaces': [1, 2, 3],
    });

    expect(await settingsService.getRecentWorkspaces(), isEmpty);
  });

  test('getApiKey tolerates a non-string stored value', () async {
    settingsService.resetForTesting();
    SharedPreferences.setMockInitialValues({
      'groq_api_key': {'not': 'a key'},
    });

    final key = await settingsService.getApiKey();
    expect(key, isA<String>());
  });

  test('getModel tolerates a non-string stored value', () async {
    settingsService.resetForTesting();
    SharedPreferences.setMockInitialValues({
      'groq_model': 42,
    });

    expect(await settingsService.getModel(), SettingsService.defaultModel);
  });

  test('getFontSize tolerates a non-int stored value', () async {
    settingsService.resetForTesting();
    SharedPreferences.setMockInitialValues({
      'editor_font_size': 'fourteen',
    });

    expect(await settingsService.getFontSize(), 14);
  });

  // ─── UI mode (AI native / IDE) persistence ────────────────────────────────

  test('getUiMode defaults to the agent-native layout when nothing is stored', () async {
    settingsService.resetForTesting();
    SharedPreferences.setMockInitialValues({});

    expect(await settingsService.getUiMode(), UiMode.aiNative);
  });

  test('getUiMode restores a persisted AI-native choice', () async {
    settingsService.resetForTesting();
    SharedPreferences.setMockInitialValues({'ui_mode': 'aiNative'});

    expect(await settingsService.getUiMode(), UiMode.aiNative);
  });

  test('setUiMode persists the choice for the next launch', () async {
    settingsService.resetForTesting();
    SharedPreferences.setMockInitialValues({});

    await settingsService.setUiMode(UiMode.aiNative);
    expect(await settingsService.getUiMode(), UiMode.aiNative);

    await settingsService.setUiMode(UiMode.ide);
    expect(await settingsService.getUiMode(), UiMode.ide);
  });

  test('getUiMode tolerates a corrupt stored value and stays agent-native', () async {
    settingsService.resetForTesting();
    SharedPreferences.setMockInitialValues({'ui_mode': 'quantum'});

    expect(await settingsService.getUiMode(), UiMode.aiNative);
  });
}
