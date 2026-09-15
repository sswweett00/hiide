import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/app_themes.dart';
import 'core/providers/theme_provider.dart';
import 'core/providers/backend_provider.dart';
import 'core/routing/router.dart';
import 'core/backend/backend_service.dart';
import 'core/backend/hiide_backend_service.dart';
import 'core/backend/mock_backend_service.dart';
import 'core/backend/settings_service.dart';
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
    AppThemePreference.light => AppThemes.darkTheme,
  };
}

/// Connects to the native Zig engine (hiide-ipc-server on 127.0.0.1:4879).
/// Falls back to the in-memory mock when the engine is not running so the IDE
/// stays usable offline.
Future<BackendService> _createBackendService() async {
  if (kIsWeb) return MockBackendService();

  final backend = HiideBackendService();
  try {
    await backend.connect();
    debugPrint(
        'Connected to Hiide Zig engine at ${backend.host}:${backend.port}');
    return backend;
  } catch (e) {
    debugPrint(
        'Zig engine not reachable (${backend.host}:${backend.port}); using mock backend: $e');
    return MockBackendService();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final backendService = await _createBackendService();

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

  // Restore the last UI style (AI-native chat vs classic IDE shell) so the
  // app reopens in the layout the user left it in.
  var uiMode = UiMode.ide;
  try {
    uiMode = await settingsService.getUiMode();
  } catch (e) {
    debugPrint('Could not restore UI mode: $e');
  }

  // Restore the auto-save preference.
  var autoSave = true;
  try {
    autoSave = await settingsService.getAutoSave();
  } catch (e) {
    debugPrint('Could not restore auto-save: $e');
  }

  // Restore editor preferences (font size, tab size, word wrap, minimap).
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

  // Restore AI provider settings.
  String aiProviderId = 'groq';
  String openaiKey = '';
  String anthropicKey = '';
  String ollamaUrl = 'http://127.0.0.1:11434';
  try {
    aiProviderId = await settingsService.getAiProvider();
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

  runApp(
    ProviderScope(
      overrides: [
        if (workspaceRoot != null)
          workspaceRootProvider.overrideWith((ref) => workspaceRoot!),
        workspaceRestoredProvider.overrideWith((ref) => restoredWorkspace),
        uiModeProvider.overrideWith((ref) => uiMode),
        autoSaveEnabledProvider.overrideWith((ref) => autoSave),
        editorFontSizeProvider.overrideWith((ref) => fontSize),
        editorTabSizeProvider.overrideWith((ref) => tabSize),
        editorWordWrapProvider.overrideWith((ref) => wordWrap),
        settingsProvider.overrideWith((ref) => {
          'theme': 'Dark',
          'fontSize': fontSize.toInt(),
          'tabSize': tabSize,
          'wordWrap': wordWrap,
          'minimap': minimap,
          'aiSuggestions': true,
          'autoSave': autoSave,
          'formatOnSave': true,
        }),
        aiProviderTypeProvider.overrideWith(
          (ref) => aiProviderTypeFromId(aiProviderId),
        ),
        openaiApiKeyProvider.overrideWith((ref) => openaiKey),
        anthropicApiKeyProvider.overrideWith((ref) => anthropicKey),
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
        title: 'Hiide AI IDE',
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
