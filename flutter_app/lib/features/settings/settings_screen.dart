import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/design_system/tokens.dart';
import '../../core/providers/theme_provider.dart';
import '../../core/backend/settings_service.dart';
import '../../shared/providers/editor_providers.dart';
import '../../shared/widgets/ai_widgets.dart';
import '../../shared/widgets/ide_shell.dart';
import '../../shared/widgets/hiide_widgets.dart';
import '../../core/backend/ai_providers/ai_provider.dart';
import '../../core/backend/ai_providers/provider_manager.dart';

final settingsProvider = StateProvider<Map<String, dynamic>>((ref) => {
      'theme': 'Dark',
      'fontSize': 14,
      'tabSize': 4,
      'wordWrap': false,
      'minimap': true,
      'aiSuggestions': true,
      'autoSave': true,
      'formatOnSave': true,
    });

final groqApiKeyProvider = StateProvider<String>((ref) => '');
final groqModelProvider =
    StateProvider<String>((ref) => SettingsService.availableModels.first);

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, this.standalone = false});

  /// When true the page is rendered outside the IDE shell (welcome-flow
  /// style: aurora backdrop, centered card, back button) instead of inside
  /// the full IDE chrome.
  final bool standalone;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _apiKeyCtrl;
  late final TextEditingController _openaiKeyCtrl;
  late final TextEditingController _anthropicKeyCtrl;
  late final TextEditingController _ollamaUrlCtrl;
  bool _apiKeyObscured = true;
  bool _apiKeyDirty = false;

  @override
  void initState() {
    super.initState();
    _apiKeyCtrl = TextEditingController();
    _openaiKeyCtrl = TextEditingController();
    _anthropicKeyCtrl = TextEditingController();
    _ollamaUrlCtrl = TextEditingController();
    // Load stored keys
    settingsService.getApiKey().then((key) {
      if (mounted) {
        _apiKeyCtrl.text = key;
        ref.read(groqApiKeyProvider.notifier).state = key;
      }
    });
    settingsService.getModel().then((model) {
      if (mounted) {
        ref.read(groqModelProvider.notifier).state = model;
      }
    });
    settingsService.getOpenaiApiKey().then((key) {
      if (mounted) {
        _openaiKeyCtrl.text = key;
        ref.read(openaiApiKeyProvider.notifier).state = key;
      }
    });
    settingsService.getAnthropicApiKey().then((key) {
      if (mounted) {
        _anthropicKeyCtrl.text = key;
        ref.read(anthropicApiKeyProvider.notifier).state = key;
      }
    });
    settingsService.getOllamaUrl().then((url) {
      if (mounted) {
        _ollamaUrlCtrl.text = url;
        ref.read(ollamaUrlProvider.notifier).state = url;
      }
    });
  }

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    _openaiKeyCtrl.dispose();
    _anthropicKeyCtrl.dispose();
    _ollamaUrlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final settings = ref.watch(settingsProvider);

    // When the live /models list arrives and the persisted model is no longer
    // served (e.g. it was retired since it was chosen), switch to the first
    // live model and persist the correction so the chat never sends a dead id.
    // Only fires on an actual value change, so the service invalidation below
    // cannot loop: a refetch returning the same list is treated as unchanged.
    ref.listen(groqLiveModelsProvider, (previous, next) {
      next.whenData((models) {
        if (models.isEmpty) return;
        final current = ref.read(groqModelProvider);
        if (!models.contains(current)) {
          final fallback = models.first;
          ref.read(groqModelProvider.notifier).state = fallback;
          settingsService.setModel(fallback);
          ref.invalidate(groqAiServiceProvider);
        }
      });
    });

    final content = Container(
      color: cs.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AiPageHeader(
            icon: Icons.settings_outlined,
            title: 'Settings',
            subtitle: 'Tune your IDE and AI provider',
            actions: widget.standalone
                ? [
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => context.go('/welcome'),
                      tooltip: 'Geri',
                    ),
                  ]
                : const [],
          ),
          Expanded(
            child: ListView(
              padding:
                  const EdgeInsets.symmetric(horizontal: DesignTokens.space4),
              children: [
                // ── AI Provider ──────────────────────────────────────────
                _SettingsSection(
                    title: 'AI Provider',
                    highlight: true,
                    children: [
                      // Provider Selector
                      Container(
                        padding: const EdgeInsets.all(DesignTokens.space4),
                        decoration: BoxDecoration(
                          border: Border(
                              bottom: BorderSide(
                                  color: cs.outlineVariant,
                                  width: DesignTokens.borderWidthThin)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Active Provider',
                                      style: TextStyle(
                                          color: cs.onSurface,
                                          fontWeight: DesignTokens.fontWeightMedium,
                                          fontSize: DesignTokens.fontSizeMD)),
                                  const SizedBox(height: 4),
                                  Text('Choose which AI service to use',
                                      style: TextStyle(
                                          color: cs.onSurfaceVariant,
                                          fontSize: DesignTokens.fontSizeSM)),
                                ],
                              ),
                            ),
                            const SizedBox(width: DesignTokens.space3),
                            SizedBox(
                              width: 180,
                              child: DropdownButton<String>(
                                value: ref.watch(aiProviderTypeProvider).name,
                                isExpanded: true,
                                items: const [
                                  DropdownMenuItem(value: 'groq', child: Text('Groq')),
                                  DropdownMenuItem(value: 'openai', child: Text('OpenAI')),
                                  DropdownMenuItem(value: 'anthropic', child: Text('Anthropic')),
                                  DropdownMenuItem(value: 'ollama', child: Text('Ollama (Local)')),
                                ],
                                onChanged: (value) {
                                  if (value != null) {
                                    ref.read(aiProviderTypeProvider.notifier).state =
                                        aiProviderTypeFromId(value);
                                    settingsService.setAiProvider(value);
                                  }
                                },
                                style: TextStyle(
                                    color: cs.onSurface,
                                    fontSize: DesignTokens.fontSizeMD),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Groq API Key
                      Container(
                        padding: const EdgeInsets.all(DesignTokens.space4),
                        decoration: BoxDecoration(
                          border: Border(
                              bottom: BorderSide(
                                  color: cs.outlineVariant,
                                  width: DesignTokens.borderWidthThin)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Groq API Key',
                                style: TextStyle(
                                    color: cs.onSurface,
                                    fontWeight: DesignTokens.fontWeightMedium,
                                    fontSize: DesignTokens.fontSizeMD)),
                            const SizedBox(height: 4),
                            Text(
                                'Fast inference. Get your key at console.groq.com',
                                style: TextStyle(
                                    color: cs.onSurfaceVariant,
                                    fontSize: DesignTokens.fontSizeSM)),
                            const SizedBox(height: DesignTokens.space3),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _apiKeyCtrl,
                                    obscureText: _apiKeyObscured,
                                    style: TextStyle(
                                        color: cs.onSurface,
                                        fontFamily: 'JetBrains Mono',
                                        fontSize: DesignTokens.fontSizeSM),
                                    decoration: InputDecoration(
                                      hintText: 'gsk_...',
                                      hintStyle:
                                          TextStyle(color: cs.onSurfaceVariant),
                                      suffixIcon: IconButton(
                                        icon: Icon(
                                            _apiKeyObscured
                                                ? Icons.visibility
                                                : Icons.visibility_off,
                                            size: 18),
                                        onPressed: () => setState(() =>
                                            _apiKeyObscured = !_apiKeyObscured),
                                      ),
                                      border: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(8)),
                                    ),
                                    onChanged: (_) =>
                                        setState(() => _apiKeyDirty = true),
                                  ),
                                ),
                                const SizedBox(width: DesignTokens.space2),
                                ElevatedButton(
                                  onPressed: _apiKeyDirty
                                      ? () async {
                                          final key = _apiKeyCtrl.text.trim();
                                          await settingsService.setApiKey(key);
                                          ref
                                              .read(groqApiKeyProvider.notifier)
                                              .state = key;
                                          ref.invalidate(groqAiServiceProvider);
                                          setState(() => _apiKeyDirty = false);
                                          if (!context.mounted) return;
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            const SnackBar(
                                                content: Text('API key saved!'),
                                                duration: Duration(seconds: 2)),
                                          );
                                        }
                                      : null,
                                  child: const Text('Save'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      // Model selection — prefers the models the Groq API
                      // actually serves for the configured key; falls back to
                      // the curated list while no key is set or while the
                      // live fetch is loading/failing.
                      Builder(builder: (context) {
                        final modelsAsync = ref.watch(groqLiveModelsProvider);
                        final liveModels =
                            modelsAsync.valueOrNull ?? const <String>[];
                        final models = liveModels.isNotEmpty
                            ? liveModels
                            : SettingsService.availableModels;
                        final currentModel = ref.watch(groqModelProvider);
                        final apiKey = ref.watch(groqApiKeyProvider);

                        String status;
                        if (modelsAsync.isLoading && apiKey.isNotEmpty) {
                          status = 'Fetching models from Groq…';
                        } else if (liveModels.isNotEmpty) {
                          status =
                              '${liveModels.length} models from the Groq API';
                        } else if (modelsAsync.hasError) {
                          status =
                              'Could not reach Groq — using the default list';
                        } else {
                          status =
                              'Default list — save an API key to sync with Groq';
                        }

                        return Container(
                          padding: const EdgeInsets.all(DesignTokens.space4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('AI Model',
                                        style: TextStyle(
                                            color: cs.onSurface,
                                            fontWeight:
                                                DesignTokens.fontWeightMedium,
                                            fontSize: DesignTokens.fontSizeMD)),
                                    const SizedBox(height: 2),
                                    Text(status,
                                        style: TextStyle(
                                            color: cs.onSurfaceVariant,
                                            fontSize: DesignTokens.fontSizeSM)),
                                  ],
                                ),
                              ),
                              const SizedBox(width: DesignTokens.space3),
                              SizedBox(
                                width: 220,
                                child: Material(
                                  child: DropdownButton<String>(
                                    value: models.contains(currentModel)
                                        ? currentModel
                                        : models.first,
                                    isExpanded: true,
                                    items: models
                                        .map((m) => DropdownMenuItem(
                                            value: m,
                                            child: Text(m,
                                                overflow: TextOverflow.ellipsis,
                                                style:
                                                    TextStyle(fontSize: 12))))
                                        .toList(),
                                    onChanged: (value) async {
                                      if (value != null) {
                                        await settingsService.setModel(value);
                                        ref
                                            .read(groqModelProvider.notifier)
                                            .state = value;
                                        ref.invalidate(groqAiServiceProvider);
                                      }
                                    },
                                    style: TextStyle(
                                        color: cs.onSurface,
                                        fontSize: DesignTokens.fontSizeMD),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                      // OpenAI API Key
                      Container(
                        padding: const EdgeInsets.all(DesignTokens.space4),
                        decoration: BoxDecoration(
                          border: Border(
                              bottom: BorderSide(
                                  color: cs.outlineVariant,
                                  width: DesignTokens.borderWidthThin)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('OpenAI API Key',
                                style: TextStyle(
                                    color: cs.onSurface,
                                    fontWeight: DesignTokens.fontWeightMedium,
                                    fontSize: DesignTokens.fontSizeMD)),
                            const SizedBox(height: 4),
                            Text('For GPT-4o and other OpenAI models',
                                style: TextStyle(
                                    color: cs.onSurfaceVariant,
                                    fontSize: DesignTokens.fontSizeSM)),
                            const SizedBox(height: DesignTokens.space3),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _openaiKeyCtrl,
                                    obscureText: true,
                                    style: TextStyle(
                                        color: cs.onSurface,
                                        fontFamily: 'JetBrains Mono',
                                        fontSize: DesignTokens.fontSizeSM),
                                    decoration: InputDecoration(
                                      hintText: 'sk-...',
                                      hintStyle: TextStyle(color: cs.onSurfaceVariant),
                                      border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(8)),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: DesignTokens.space2),
                                ElevatedButton(
                                  onPressed: () async {
                                    final key = _openaiKeyCtrl.text.trim();
                                    await settingsService.setOpenaiApiKey(key);
                                    ref.read(openaiApiKeyProvider.notifier).state = key;
                                    if (!context.mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('OpenAI key saved!'), duration: Duration(seconds: 2)),
                                    );
                                  },
                                  child: const Text('Save'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      // Anthropic API Key
                      Container(
                        padding: const EdgeInsets.all(DesignTokens.space4),
                        decoration: BoxDecoration(
                          border: Border(
                              bottom: BorderSide(
                                  color: cs.outlineVariant,
                                  width: DesignTokens.borderWidthThin)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Anthropic API Key',
                                style: TextStyle(
                                    color: cs.onSurface,
                                    fontWeight: DesignTokens.fontWeightMedium,
                                    fontSize: DesignTokens.fontSizeMD)),
                            const SizedBox(height: 4),
                            Text('For Claude models (Sonnet, Haiku, Opus)',
                                style: TextStyle(
                                    color: cs.onSurfaceVariant,
                                    fontSize: DesignTokens.fontSizeSM)),
                            const SizedBox(height: DesignTokens.space3),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _anthropicKeyCtrl,
                                    obscureText: true,
                                    style: TextStyle(
                                        color: cs.onSurface,
                                        fontFamily: 'JetBrains Mono',
                                        fontSize: DesignTokens.fontSizeSM),
                                    decoration: InputDecoration(
                                      hintText: 'sk-ant-...',
                                      hintStyle: TextStyle(color: cs.onSurfaceVariant),
                                      border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(8)),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: DesignTokens.space2),
                                ElevatedButton(
                                  onPressed: () async {
                                    final key = _anthropicKeyCtrl.text.trim();
                                    await settingsService.setAnthropicApiKey(key);
                                    ref.read(anthropicApiKeyProvider.notifier).state = key;
                                    if (!context.mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Anthropic key saved!'), duration: Duration(seconds: 2)),
                                    );
                                  },
                                  child: const Text('Save'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      // Ollama URL
                      Container(
                        padding: const EdgeInsets.all(DesignTokens.space4),
                        decoration: BoxDecoration(
                          border: Border(
                              bottom: BorderSide(
                                  color: cs.outlineVariant,
                                  width: DesignTokens.borderWidthThin)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Ollama URL (Local)',
                                style: TextStyle(
                                    color: cs.onSurface,
                                    fontWeight: DesignTokens.fontWeightMedium,
                                    fontSize: DesignTokens.fontSizeMD)),
                            const SizedBox(height: 4),
                            Text('Connect to a local Ollama instance — no API key needed',
                                style: TextStyle(
                                    color: cs.onSurfaceVariant,
                                    fontSize: DesignTokens.fontSizeSM)),
                            const SizedBox(height: DesignTokens.space3),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _ollamaUrlCtrl,
                                    style: TextStyle(
                                        color: cs.onSurface,
                                        fontFamily: 'JetBrains Mono',
                                        fontSize: DesignTokens.fontSizeSM),
                                    decoration: InputDecoration(
                                      hintText: 'http://127.0.0.1:11434',
                                      hintStyle: TextStyle(color: cs.onSurfaceVariant),
                                      border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(8)),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: DesignTokens.space2),
                                ElevatedButton(
                                  onPressed: () async {
                                    final url = _ollamaUrlCtrl.text.trim();
                                    await settingsService.setOllamaUrl(url);
                                    ref.read(ollamaUrlProvider.notifier).state = url;
                                    if (!context.mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Ollama URL saved!'), duration: Duration(seconds: 2)),
                                    );
                                  },
                                  child: const Text('Save'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ]),
                _SettingsSection(title: 'Appearance', children: [
                  _SettingsItem(
                    title: 'Theme',
                    description: 'Choose your preferred theme',
                    trailing: SizedBox(
                      width: 120,
                      height: 40,
                      child: Material(
                        child: DropdownButton<String>(
                          value: settings['theme'] as String,
                          isExpanded: true,
                          items: const [
                            DropdownMenuItem(
                                value: 'Dark', child: Text('Dark')),
                            DropdownMenuItem(
                                value: 'Light', child: Text('Light')),
                            DropdownMenuItem(
                                value: 'OLED Black', child: Text('OLED Black')),
                            DropdownMenuItem(
                                value: 'High Contrast',
                                child: Text('High Contrast')),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              ref.read(settingsProvider.notifier).state = {
                                ...settings,
                                'theme': value
                              };
                              // Apply the selected theme immediately.
                              final preference = switch (value) {
                                'Light' => AppThemePreference.light,
                                'OLED Black' => AppThemePreference.oledBlack,
                                'High Contrast' =>
                                  AppThemePreference.highContrast,
                                _ => AppThemePreference.dark,
                              };
                              ref
                                  .read(appThemePreferenceProvider.notifier)
                                  .state = preference;
                            }
                          },
                          style: TextStyle(
                              color: cs.onSurface,
                              fontSize: DesignTokens.fontSizeMD),
                        ),
                      ),
                    ),
                  ),
                  _SettingsItem(
                    title: 'Font Size',
                    description: 'Adjust the editor font size',
                    trailing: HiideTextField(
                      hintText: '${settings['fontSize']}',
                      maxLines: 1,
                      onChanged: (value) {
                        final fontSize =
                            int.tryParse(value) ?? settings['fontSize'];
                        ref.read(settingsProvider.notifier).state = {
                          ...settings,
                          'fontSize': fontSize
                        };
                        // Live-update the editor font size and persist.
                        ref.read(editorFontSizeProvider.notifier).state =
                            fontSize.toDouble();
                        settingsService.setFontSize(fontSize);
                      },
                    ),
                  ),
                ]),
                _SettingsSection(title: 'Editor', children: [
                  _SettingsItem(
                    title: 'Tab Size',
                    description: 'Number of spaces per tab',
                    trailing: HiideTextField(
                      hintText: '${settings['tabSize']}',
                      maxLines: 1,
                      onChanged: (value) {
                        final tabSize =
                            int.tryParse(value) ?? settings['tabSize'];
                        ref.read(settingsProvider.notifier).state = {
                          ...settings,
                          'tabSize': tabSize
                        };
                        // Live-update the editor tab size and persist.
                        ref.read(editorTabSizeProvider.notifier).state = tabSize;
                        settingsService.setTabSize(tabSize);
                      },
                    ),
                  ),
                  _SettingsItem(
                    title: 'Word Wrap',
                    description: 'Wrap lines at viewport width',
                    trailing: Switch(
                      value: settings['wordWrap'] as bool,
                      onChanged: (value) {
                        ref.read(settingsProvider.notifier).state = {
                          ...settings,
                          'wordWrap': value
                        };
                        // Live-toggle word wrap in the editor and persist.
                        ref.read(editorWordWrapProvider.notifier).state = value;
                        settingsService.setWordWrap(value);
                      },
                    ),
                  ),
                  _SettingsItem(
                    title: 'Minimap',
                    description: 'Show minimap in editor',
                    trailing: Switch(
                      value: settings['minimap'] as bool,
                      onChanged: (value) {
                        ref.read(settingsProvider.notifier).state = {
                          ...settings,
                          'minimap': value
                        };
                        settingsService.setMinimap(value);
                      },
                    ),
                  ),
                ]),
                _SettingsSection(title: 'AI Features', children: [
                  _SettingsItem(
                    title: 'AI Suggestions',
                    description: 'Show AI-powered code suggestions',
                    trailing: Switch(
                      value: settings['aiSuggestions'] as bool,
                      onChanged: (value) {
                        ref.read(settingsProvider.notifier).state = {
                          ...settings,
                          'aiSuggestions': value
                        };
                      },
                    ),
                  ),
                  _SettingsItem(
                    title: 'Auto Save',
                    description: 'Automatically save files',
                    trailing: Switch(
                      value: settings['autoSave'] as bool,
                      onChanged: (value) {
                        ref.read(settingsProvider.notifier).state = {
                          ...settings,
                          'autoSave': value
                        };
                        // Live-toggle the editor behavior and persist it.
                        ref.read(autoSaveEnabledProvider.notifier).state =
                            value;
                        settingsService.setAutoSave(value);
                      },
                    ),
                  ),
                  _SettingsItem(
                    title: 'Format on Save',
                    description: 'Auto-format code when saving',
                    trailing: Switch(
                      value: settings['formatOnSave'] as bool,
                      onChanged: (value) {
                        ref.read(settingsProvider.notifier).state = {
                          ...settings,
                          'formatOnSave': value
                        };
                      },
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ],
      ),
    );

    if (widget.standalone) {
      // Welcome-flow presentation: centered card on the aurora backdrop, no
      // IDE chrome — the settings page, not the IDE screen.
      return Scaffold(
        body: AiBackdrop(
          intensity: 0.6,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880),
              child: content,
            ),
          ),
        ),
      );
    }
    return IdeShell(showAiSidebar: false, child: content);
  }
}

class _SettingsSection extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final bool highlight;

  const _SettingsSection({
    required this.title,
    required this.children,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final card = Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(DesignTokens.radiusLG),
        border: Border.all(
            color: cs.outlineVariant, width: DesignTokens.borderWidthThin),
      ),
      child: Column(children: children),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AiSectionHeader(title: title),
        if (highlight)
          AiGlowCard(padding: EdgeInsets.zero, wash: true, child: card)
        else
          card,
        const SizedBox(height: DesignTokens.space6),
      ],
    );
  }
}

class _SettingsItem extends StatelessWidget {
  final String title;
  final String description;
  final Widget trailing;

  const _SettingsItem(
      {required this.title, required this.description, required this.trailing});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(DesignTokens.space4),
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(
                color: cs.outlineVariant, width: DesignTokens.borderWidthThin)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: cs.onSurface,
                        fontSize: DesignTokens.fontSizeMD,
                        fontWeight: DesignTokens.fontWeightMedium)),
                Text(description,
                    style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: DesignTokens.fontSizeSM)),
              ],
            ),
          ),
          const SizedBox(width: DesignTokens.space3),
          SizedBox(width: 120, child: trailing),
        ],
      ),
    );
  }
}
