import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/app_themes.dart';
import 'core/providers/theme_provider.dart';
import 'core/providers/backend_provider.dart';
import 'core/routing/router.dart';
import 'core/backend/backend_service.dart';
import 'core/backend/hiide_backend_service.dart';
import 'core/backend/native_engine_supervisor.dart';
import 'core/backend/mock_backend_service.dart';
import 'core/backend/settings_service.dart';
import 'core/backend/agent_task_store.dart';
import 'core/backend/ai_providers/ai_provider.dart';
import 'core/backend/ai_providers/provider_manager.dart';
import 'core/localization/app_localizations.dart';
import 'shared/providers/editor_providers.dart';
import 'features/settings/settings_screen.dart';

ThemeData _resolveDarkTheme(AppThemePreference preference) {
  return switch (preference) {
    AppThemePreference.dark => AppThemes.darkTheme,
    AppThemePreference.oledBlack => AppThemes.oledBlackTheme,
    AppThemePreference.highContrast => AppThemes.highContrastTheme,
    AppThemePreference.light => AppThemes.lightTheme,
  };
}

/// Connects to the native Zig engine and starts a bundled/local engine when
/// the server is not already running. The in-memory mock remains the final
/// fallback for tests and engine-less environments.
Process? _spawnedEngineProcess;
Future<BackendService> _createBackendService() async {
  if (kIsWeb) return MockBackendService();

  final launch = await NativeEngineSupervisor().connectOrStart();
  final process = launch.process;
  if (process != null) {
    _spawnedEngineProcess = process;
    process.exitCode.then((_) {
      if (identical(_spawnedEngineProcess, process)) {
        _spawnedEngineProcess = null;
      }
    });
    debugPrint('Started managed Hiide Zig engine (pid ${process.pid})');
  }
  if (launch.backend is HiideBackendService) {
    final backend = launch.backend as HiideBackendService;
    debugPrint('Connected to Hiide Zig engine at ${backend.host}:${backend.port}');
  } else {
    debugPrint('Native engine unavailable; using mock backend.');
  }
  return launch.backend;
}

void _cleanupManagedEngine() {
  final process = _spawnedEngineProcess;
  _spawnedEngineProcess = null;
  process?.kill();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final backendService = await _createBackendService();
  final agentTaskStore = await AgentTaskStore.load();

  // Restore the last workspace (when it still exists) so the IDE opens where
  // the user left off; a vanished entry falls back to the folder browser.
  var restoredWorkspace = false;
  String? workspaceRoot;
  try {
    final stored = await resolveStartupWorkspace();
    if (stored != null) {
      workspaceRoot = stored;
      restoredWorkspace = true;
    }
  } catch (e) {
    debugPrint('Could not restore workspace: $e');
  }

  // No developer-specific absolute path is used as the production fallback.
  // When there is no persisted workspace yet, start from the process working
  // directory on desktop; the normal workspace picker can immediately replace
  // it with an explicit project folder.
  final fallbackWorkspace = kIsWeb ? '/' : Directory.current.path;
  var recentWorkspaces = <String>[];
  try {
    recentWorkspaces = await settingsService.getRecentWorkspaces();
  } catch (e) {
    debugPrint('Could not restore recent workspaces: $e');
  }

  var uiMode = UiMode.aiNative;
  try {
    uiMode = await settingsService.getUiMode();
  } catch (e) {
    debugPrint('Could not restore UI mode: $e');
  }

  var autoSave = true;
  try {
    autoSave = await settingsService.getAutoSave();
  } catch (e) {
    debugPrint('Could not restore auto-save: $e');
  }

  double fontSize = 14.0;
  int tabSize = 4;
  bool wordWrap = false;
  bool minimap = true;
  try {
    fontSize = (await settingsService.getFontSize()).toDouble();
  } catch (_) {}
  try {
    tabSize = await settingsService.getTabSize();
  } catch (_) {}
  try {
    wordWrap = await settingsService.getWordWrap();
  } catch (_) {}
  try {
    minimap = await settingsService.getMinimap();
  } catch (_) {}

  String aiProviderId = 'groq';
  Map<String, String> aiProviderKeys = const <String, String>{};
  Map<String, String> aiProviderModels = const <String, String>{};
  List<Map<String, String>> customAiProviders = const <Map<String, String>>[];
  String openaiKey = '';
  String anthropicKey = '';
  String ollamaUrl = 'http://127.0.0.1:11434';
  try {
    aiProviderId = await settingsService.getAiProvider();
  } catch (_) {}
  try {
    aiProviderKeys = await settingsService.getAiApiKeys();
  } catch (_) {}
  try {
    aiProviderModels = await settingsService.getAiProviderModels();
  } catch (_) {}
  try {
    customAiProviders = await settingsService.getCustomAiProviders();
  } catch (_) {}
  try {
    openaiKey = await settingsService.getOpenaiApiKey();
  } catch (_) {}
  try {
    anthropicKey = await settingsService.getAnthropicApiKey();
  } catch (_) {}
  try {
    ollamaUrl = await settingsService.getOllamaUrl();
  } catch (_) {}

  if (_spawnedEngineProcess != null && !kIsWeb) {
    ProcessSignal.sigint.watch().listen((_) => _cleanupManagedEngine());
    ProcessSignal.sigterm.watch().listen((_) => _cleanupManagedEngine());
  }

  runApp(
    ProviderScope(
      overrides: [
        agentTaskStoreProvider.overrideWithValue(agentTaskStore),
        workspaceRootProvider.overrideWith(
          (ref) => workspaceRoot ?? fallbackWorkspace,
        ),
        recentWorkspacesProvider.overrideWith((ref) => recentWorkspaces),
        workspaceRestoredProvider.overrideWith((ref) => restoredWorkspace),
        uiModeProvider.overrideWith((ref) => uiMode),
        autoSaveEnabledProvider.overrideWith((ref) => autoSave),
        editorFontSizeProvider.overrideWith((ref) => fontSize.clamp(10.0, 32.0)),
        editorTabSizeProvider.overrideWith((ref) => tabSize.clamp(1, 16)),
        editorWordWrapProvider.overrideWith((ref) => wordWrap),
        settingsProvider.overrideWith((ref) => {
          'theme': 'Dark',
          'fontSize': fontSize.clamp(10.0, 32.0).toInt(),
          'tabSize': tabSize.clamp(1, 16),
          'wordWrap': wordWrap,
          'minimap': minimap,
          'aiSuggestions': true,
          'autoSave': autoSave,
          'formatOnSave': true,
        }),
        aiProviderIdProvider.overrideWith((ref) => aiProviderId),
        aiProviderTypeProvider.overrideWith(
          (ref) => aiProviderTypeFromId(aiProviderId),
        ),
        aiProviderKeysProvider.overrideWith((ref) => aiProviderKeys),
        aiProviderModelsProvider.overrideWith((ref) => aiProviderModels),
        customAiProvidersProvider.overrideWith((ref) => customAiProviders),
        openaiApiKeyProvider.overrideWith(
          (ref) => aiProviderKeys['openai'] ?? openaiKey,
        ),
        anthropicApiKeyProvider.overrideWith(
          (ref) => aiProviderKeys['anthropic'] ?? anthropicKey,
        ),
        ollamaUrlProvider.overrideWith((ref) => ollamaUrl),
      ],
      child: HiideApp(backendService: backendService),
    ),
  );
}

class HiideApp extends ConsumerWidget {
  final BackendService backendService;

  const HiideApp({super.key, required this.backendService});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final preference = ref.watch(appThemePreferenceProvider);

    return ProviderScope(
      overrides: [backendServiceProvider.overrideWithValue(backendService)],
      child: MaterialApp.router(
        title: 'Hiide Agent Workspace',
        debugShowCheckedModeBanner: false,
        theme: AppThemes.lightTheme,
        darkTheme: _resolveDarkTheme(preference),
        themeMode: preference == AppThemePreference.light
            ? ThemeMode.light
            : ThemeMode.dark,
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );
  }
}