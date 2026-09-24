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
  late final TextEditingController _modelCtrl;
  late final TextEditingController _customNameCtrl;
  late final TextEditingController _customUrlCtrl;
  late final TextEditingController _customModelCtrl;
  late final TextEditingController _customKeyCtrl;
  late final TextEditingController _customAuthHeaderCtrl;
  late final TextEditingController _customAuthPrefixCtrl;
  late final TextEditingController _baseUrlCtrl;
  bool _apiKeyObscured = true;
  bool _customRequiresApiKey = true;
  String? _formProviderId;

  @override
  void initState() {
    super.initState();
    _apiKeyCtrl = TextEditingController();
    _openaiKeyCtrl = TextEditingController();
    _anthropicKeyCtrl = TextEditingController();
    _ollamaUrlCtrl = TextEditingController();
    _modelCtrl = TextEditingController();
    _customNameCtrl = TextEditingController();
    _customUrlCtrl = TextEditingController();
    _customModelCtrl = TextEditingController();
    _customKeyCtrl = TextEditingController();
    _customAuthHeaderCtrl = TextEditingController(text: 'Authorization');
    _customAuthPrefixCtrl = TextEditingController(text: 'Bearer ');
    _baseUrlCtrl = TextEditingController();
    // Restore the full provider registry state.
    settingsService.getAiApiKeys().then((keys) {
      if (mounted) {
        ref.read(aiProviderKeysProvider.notifier).state = keys;
        final id = ref.read(aiProviderIdProvider);
        _apiKeyCtrl.text = keys[id] ?? '';
      }
    });
    settingsService.getAiProviderBaseUrls().then((baseUrls) {
      if (mounted) {
        ref.read(aiProviderBaseUrlsProvider.notifier).state = baseUrls;
        final id = ref.read(aiProviderIdProvider);
        _baseUrlCtrl.text = baseUrls[id] ??
            ref.read(providerManagerProvider).active.baseUrl;
      }
    });
    settingsService.getAiProviderModels().then((models) {
      if (mounted) {
        ref.read(aiProviderModelsProvider.notifier).state = models;
        final id = ref.read(aiProviderIdProvider);
        final fallback = ref.read(providerManagerProvider).active.defaultModel;
        _modelCtrl.text = models[id] ?? fallback;
      }
    });
    settingsService.getAiProvider().then((id) {
      if (mounted) {
        ref.read(aiProviderIdProvider.notifier).state = id;
        ref.read(aiProviderTypeProvider.notifier).state =
            aiProviderTypeFromId(id);
        _apiKeyCtrl.text = ref.read(aiProviderKeysProvider)[id] ?? '';
        final models = ref.read(aiProviderModelsProvider);
        _modelCtrl.text =
            models[id] ?? ref.read(providerManagerProvider).active.defaultModel;
      }
    });
    settingsService.getCustomAiProviders().then((custom) {
      if (mounted) {
        ref.read(customAiProvidersProvider.notifier).state = custom;
      }
    });

  }

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    _openaiKeyCtrl.dispose();
    _anthropicKeyCtrl.dispose();
    _ollamaUrlCtrl.dispose();
    _modelCtrl.dispose();
    _customNameCtrl.dispose();
    _customUrlCtrl.dispose();
    _customModelCtrl.dispose();
    _customKeyCtrl.dispose();
    _customAuthHeaderCtrl.dispose();
    _customAuthPrefixCtrl.dispose();
    _baseUrlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final settings = ref.watch(settingsProvider);


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
                // ── Unified agent provider runtime ─────────────────────────
                _SettingsSection(
                  title: 'AI Agent Runtime',
                  highlight: true,
                  children: [
                    Builder(builder: (context) {
                      final manager = ref.watch(providerManagerProvider);
                      final activeId = ref.watch(aiProviderIdProvider);
                      final keys = ref.watch(aiProviderKeysProvider);
                      final models = ref.watch(aiProviderModelsProvider);
                      final baseUrls = ref.watch(aiProviderBaseUrlsProvider);
                      final active = manager.active;
                      final configured = !active.requiresApiKey ||
                          (keys[active.id] ?? '').trim().isNotEmpty;
                      final model = models[active.id]?.trim().isNotEmpty == true
                          ? models[active.id]!
                          : active.defaultModel;
                      final activeBaseUrl = baseUrls[active.id]?.trim().isNotEmpty == true
                          ? baseUrls[active.id]!
                          : active.baseUrl;
                      if (_formProviderId != active.id) {
                        _formProviderId = active.id;
                        _modelCtrl.text = model;
                        _apiKeyCtrl.text = keys[active.id] ?? '';
                        _baseUrlCtrl.text = baseUrls[active.id] ?? activeBaseUrl;
                      } else if (_modelCtrl.text.isEmpty) {
                        _modelCtrl.text = model;
                      }

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(DesignTokens.space4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Active provider',
                                  style: TextStyle(
                                    color: cs.onSurface,
                                    fontWeight:
                                        DesignTokens.fontWeightMedium,
                                    fontSize: DesignTokens.fontSizeMD,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Aynı agent runtime; farklı sağlayıcılar ve yerel modeller.',
                                  style: TextStyle(
                                    color: cs.onSurfaceVariant,
                                    fontSize: DesignTokens.fontSizeSM,
                                  ),
                                ),
                                const SizedBox(height: DesignTokens.space3),
                                DropdownButton<String>(
                                  value: manager.available.any(
                                          (provider) => provider.id == activeId)
                                      ? activeId
                                      : manager.available.first.id,
                                  isExpanded: true,
                                  items: manager.available
                                      .map(
                                        (provider) => DropdownMenuItem<String>(
                                          value: provider.id,
                                          child: Text(
                                            provider.displayName,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (value) async {
                                    if (value == null) return;
                                    ref
                                        .read(aiProviderIdProvider.notifier)
                                        .state = value;
                                    ref
                                        .read(aiProviderTypeProvider.notifier)
                                        .state = aiProviderTypeFromId(value);
                                    await settingsService.setAiProvider(value);
                                    final nextKeys =
                                        ref.read(aiProviderKeysProvider);
                                    final nextModels =
                                        ref.read(aiProviderModelsProvider);
                                    _apiKeyCtrl.text = nextKeys[value] ?? '';
                                    _baseUrlCtrl.text =
                                        ref.read(aiProviderBaseUrlsProvider)[value] ??
                                            manager.available
                                                .firstWhere(
                                                  (p) => p.id == value,
                                                  orElse: () => active,
                                                )
                                                .baseUrl;
                                    _modelCtrl.text = nextModels[value] ??
                                        manager.available
                                            .firstWhere(
                                              (p) => p.id == value,
                                              orElse: () => active,
                                            )
                                            .defaultModel;
                                    if (mounted) setState(() {});
                                  },
                                ),
                              ],
                            ),
                          ),
                          if (active.requiresApiKey)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                DesignTokens.space4,
                                0,
                                DesignTokens.space4,
                                DesignTokens.space4,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    active.displayName + ' API key',
                                    style: TextStyle(
                                      color: cs.onSurface,
                                      fontWeight:
                                          DesignTokens.fontWeightMedium,
                                      fontSize: DesignTokens.fontSizeMD,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    configured
                                        ? 'Kimlik bilgisi yerel ayarlarda kayıtlı.'
                                        : 'Bu sağlayıcıyı kullanmak için anahtar ekleyin.',
                                    style: TextStyle(
                                      color: cs.onSurfaceVariant,
                                      fontSize: DesignTokens.fontSizeSM,
                                    ),
                                  ),
                                  const SizedBox(height: DesignTokens.space3),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: _apiKeyCtrl,
                                          obscureText: _apiKeyObscured,
                                          decoration: InputDecoration(
                                            hintText: 'API key',
                                            suffixIcon: IconButton(
                                              icon: Icon(
                                                _apiKeyObscured
                                                    ? Icons.visibility
                                                    : Icons.visibility_off,
                                              ),
                                              onPressed: () => setState(
                                                () => _apiKeyObscured =
                                                    !_apiKeyObscured,
                                              ),
                                            ),
                                            border: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                          ),
                                          onChanged: (_) => setState(() {}),
                                        ),
                                      ),
                                      const SizedBox(width: DesignTokens.space2),
                                      ElevatedButton(
                                        onPressed: () async {
                                          final value = _apiKeyCtrl.text.trim();
                                          final next = {
                                            ...ref.read(aiProviderKeysProvider),
                                            active.id: value,
                                          };
                                          if (value.isEmpty) {
                                            next.remove(active.id);
                                          }
                                          ref
                                              .read(aiProviderKeysProvider
                                                  .notifier)
                                              .state = next;
                                          await settingsService.setAiApiKey(
                                            active.id,
                                            value,
                                          );
                                          if (mounted) setState(() {});
                                        },
                                        child: const Text('Save'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              DesignTokens.space4,
                              0,
                              DesignTokens.space4,
                              DesignTokens.space4,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'API endpoint',
                                  style: TextStyle(
                                    color: cs.onSurface,
                                    fontWeight: DesignTokens.fontWeightMedium,
                                    fontSize: DesignTokens.fontSizeMD,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Override the default endpoint for this provider. Useful for Azure, gateways and self-hosted deployments.',
                                  style: TextStyle(
                                    color: cs.onSurfaceVariant,
                                    fontSize: DesignTokens.fontSizeSM,
                                  ),
                                ),
                                const SizedBox(height: DesignTokens.space3),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _baseUrlCtrl,
                                        decoration: InputDecoration(
                                          hintText: activeBaseUrl,
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: DesignTokens.space2),
                                    ElevatedButton(
                                      onPressed: () async {
                                        final value = _baseUrlCtrl.text.trim();
                                        final next = {
                                          ...ref.read(aiProviderBaseUrlsProvider),
                                        };
                                        if (value.isEmpty || value == activeBaseUrl) {
                                          next.remove(active.id);
                                        } else {
                                          next[active.id] = value;
                                        }
                                        ref.read(aiProviderBaseUrlsProvider.notifier).state = next;
                                        await settingsService.setAiProviderBaseUrl(active.id, value == activeBaseUrl ? '' : value);
                                        if (mounted) setState(() {});
                                      },
                                      child: const Text('Save'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              DesignTokens.space4,
                              0,
                              DesignTokens.space4,
                              DesignTokens.space4,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Model',
                                  style: TextStyle(
                                    color: cs.onSurface,
                                    fontWeight:
                                        DesignTokens.fontWeightMedium,
                                    fontSize: DesignTokens.fontSizeMD,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  active.defaultModel +
                                      ' · ' +
                                      (configured ? 'configured' : 'waiting for credentials'),
                                  style: TextStyle(
                                    color: cs.onSurfaceVariant,
                                    fontSize: DesignTokens.fontSizeSM,
                                  ),
                                ),
                                const SizedBox(height: DesignTokens.space3),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _modelCtrl,
                                        decoration: InputDecoration(
                                          hintText: active.defaultModel,
                                          border: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: DesignTokens.space2),
                                    ElevatedButton(
                                      onPressed: () async {
                                        await settingsService
                                            .setAiProviderModel(
                                          active.id,
                                          _modelCtrl.text,
                                        );
                                        ref
                                            .read(aiProviderModelsProvider
                                                .notifier)
                                            .state = {
                                          ...ref.read(
                                            aiProviderModelsProvider,
                                          ),
                                          active.id: _modelCtrl.text.trim(),
                                        };
                                        if (mounted) setState(() {});
                                      },
                                      child: const Text('Use'),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: DesignTokens.space2),
                                Wrap(
                                  spacing: DesignTokens.space2,
                                  runSpacing: DesignTokens.space2,
                                  children: [
                                    OutlinedButton.icon(
                                      icon: const Icon(Icons.sync, size: 16),
                                      label: const Text('Discover models'),
                                      onPressed: configured ||
                                              !active.requiresApiKey
                                          ? () async {
                                              final models =
                                                  await manager.fetchModels();
                                              if (!context.mounted) return;
                                              if (models.isEmpty) {
                                                ScaffoldMessenger.of(context)
                                                    .showSnackBar(
                                                  const SnackBar(
                                                    content: Text(
                                                      'Model endpoint returned no models.',
                                                    ),
                                                  ),
                                                );
                                                return;
                                              }
                                              await showDialog<void>(
                                                context: context,
                                                builder: (dialogContext) =>
                                                    AlertDialog(
                                                  title: Text(
                                                      active.displayName +
                                                          ' models'),
                                                  content: SizedBox(
                                                    width: 520,
                                                    height: 420,
                                                    child: ListView.builder(
                                                      itemCount: models.length,
                                                      itemBuilder:
                                                          (context, index) {
                                                        final item = models[index];
                                                        return ListTile(
                                                          title: Text(item),
                                                          onTap: () async {
                                                            Navigator.of(
                                                                    dialogContext)
                                                                .pop();
                                                            _modelCtrl.text =
                                                                item;
                                                            await settingsService
                                                                .setAiProviderModel(
                                                              active.id,
                                                              item,
                                                            );
                                                            ref
                                                                .read(
                                                                  aiProviderModelsProvider
                                                                      .notifier,
                                                                )
                                                                .state = {
                                                              ...ref.read(
                                                                aiProviderModelsProvider,
                                                              ),
                                                              active.id: item,
                                                            };
                                                            if (mounted) {
                                                              setState(() {});
                                                            }
                                                          },
                                                        );
                                                      },
                                                    ),
                                                  ),
                                                ),
                                              );
                                            }
                                          : null,
                                    ),
                                    OutlinedButton.icon(
                                      icon:
                                          const Icon(Icons.network_check, size: 16),
                                      label: const Text('Probe'),
                                      onPressed: configured ||
                                              !active.requiresApiKey
                                          ? () async {
                                              final ok =
                                                  await active.isAvailable;
                                              if (!context.mounted) return;
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    active.displayName +
                                                        (ok
                                                            ? ' erişilebilir.'
                                                            : ' /models probe başarısız.'),
                                                  ),
                                                ),
                                              );
                                            }
                                          : null,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    }),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        DesignTokens.space4,
                        0,
                        DesignTokens.space4,
                        DesignTokens.space4,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Custom OpenAI-compatible endpoint',
                            style: TextStyle(
                              color: cs.onSurface,
                              fontWeight: DesignTokens.fontWeightMedium,
                              fontSize: DesignTokens.fontSizeMD,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'OpenAI-compatible /chat/completions sunan herhangi bir servis eklenebilir.',
                            style: TextStyle(
                              color: cs.onSurfaceVariant,
                              fontSize: DesignTokens.fontSizeSM,
                            ),
                          ),
                          const SizedBox(height: DesignTokens.space3),
                          TextField(
                            controller: _customNameCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Name',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: DesignTokens.space2),
                          TextField(
                            controller: _customUrlCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Base URL',
                              hintText: 'https://example.com/v1',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: DesignTokens.space2),
                          TextField(
                            controller: _customModelCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Default model',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: DesignTokens.space2),
                          TextField(
                            controller: _customKeyCtrl,
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: 'API key',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: DesignTokens.space2),
                          CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            value: _customRequiresApiKey,
                            onChanged: (value) => setState(
                              () => _customRequiresApiKey = value ?? true,
                            ),
                            title: const Text('Requires API key'),
                            subtitle: const Text(
                              'Disable for local gateways that accept anonymous requests.',
                            ),
                          ),
                          const SizedBox(height: DesignTokens.space1),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _customAuthHeaderCtrl,
                                  decoration: const InputDecoration(
                                    labelText: 'Auth header',
                                    hintText: 'Authorization / x-api-key / api-key',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ),
                              const SizedBox(width: DesignTokens.space2),
                              Expanded(
                                child: TextField(
                                  controller: _customAuthPrefixCtrl,
                                  decoration: const InputDecoration(
                                    labelText: 'Auth prefix',
                                    hintText: 'Bearer ',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: DesignTokens.space3),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.add),
                            label: const Text('Add endpoint'),
                            onPressed: () async {
                              final name = _customNameCtrl.text.trim();
                              final baseUrl = _customUrlCtrl.text.trim();
                              final model = _customModelCtrl.text.trim();
                              if (name.isEmpty || baseUrl.isEmpty || model.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content:
                                        Text('Name, Base URL ve model gerekli.'),
                                  ),
                                );
                                return;
                              }
                              var id = name
                                  .toLowerCase()
                                  .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
                                  .replaceAll(RegExp(r'^-+|-+$'), '');
                              if (id.isEmpty) {
                                id = 'custom-' +
                                    DateTime.now().millisecondsSinceEpoch
                                        .toString();
                              }
                              final existing =
                                  ref.read(customAiProvidersProvider);
                              var uniqueId = id.startsWith('custom-') ? id : 'custom-' + id;
                              var n = 2;
                              while (existing.any((p) => p['id'] == uniqueId)) {
                                uniqueId = '$id-$n';
                                n++;
                              }
                              final next = [
                                ...existing,
                                {
                                  'id': uniqueId,
                                  'name': name,
                                  'baseUrl': baseUrl,
                                  'model': model,
                                  'apiKeyHeader': _customAuthHeaderCtrl.text.trim().isEmpty
                                      ? 'Authorization'
                                      : _customAuthHeaderCtrl.text.trim(),
                                  'apiKeyPrefix': _customAuthPrefixCtrl.text,
                                  'requiresApiKey': _customRequiresApiKey.toString(),
                                },
                              ];
                              ref
                                  .read(customAiProvidersProvider.notifier)
                                  .state = next;
                              final keys = {
                                ...ref.read(aiProviderKeysProvider),
                                uniqueId: _customKeyCtrl.text.trim(),
                              };
                              ref
                                  .read(aiProviderKeysProvider.notifier)
                                  .state = keys;
                              await settingsService.setCustomAiProviders(next);
                              await settingsService.setAiApiKey(
                                uniqueId,
                                _customKeyCtrl.text.trim(),
                              );
                              await settingsService.setAiProvider(uniqueId);
                              ref
                                  .read(aiProviderIdProvider.notifier)
                                  .state = uniqueId;
                              _customNameCtrl.clear();
                              _customUrlCtrl.clear();
                              _customModelCtrl.clear();
                              _customKeyCtrl.clear();
                              _customAuthHeaderCtrl.text = 'Authorization';
                              _customAuthPrefixCtrl.text = 'Bearer ';
                              _customRequiresApiKey = true;
                              _apiKeyCtrl.text = keys[uniqueId] ?? '';
                              _modelCtrl.text = model;
                              if (mounted) setState(() {});
                            },
                          ),
                          const SizedBox(height: DesignTokens.space4),
                          ...ref.watch(customAiProvidersProvider).map(
                                (provider) => ListTile(
                                  dense: true,
                                  title: Text(provider['name'] ?? provider['id'] ?? ''),
                                  subtitle: Text(
                                    (provider['baseUrl'] ?? '') +
                                        ' · ' +
                                        (provider['model'] ?? '') +
                                        ' · ' +
                                        (provider['apiKeyHeader'] ?? 'Authorization'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    tooltip: 'Remove endpoint',
                                    onPressed: () async {
                                      final id = provider['id'] ?? '';
                                      final next = ref
                                          .read(customAiProvidersProvider)
                                          .where((p) => p['id'] != id)
                                          .toList();
                                      ref
                                          .read(customAiProvidersProvider
                                              .notifier)
                                          .state = next;
                                      final keys = {
                                        ...ref.read(aiProviderKeysProvider),
                                      }..remove(id);
                                      ref
                                          .read(aiProviderKeysProvider.notifier)
                                          .state = keys;
                                      await settingsService
                                          .setCustomAiProviders(next);
                                      await settingsService.setAiApiKey(id, '');
                                      if (ref.read(aiProviderIdProvider) == id) {
                                        const fallback = 'groq';
                                        ref
                                            .read(aiProviderIdProvider.notifier)
                                            .state = fallback;
                                        await settingsService
                                            .setAiProvider(fallback);
                                      }
                                      if (mounted) setState(() {});
                                    },
                                  ),
                                ),
                              ),
                        ],
                      ),
                    ),
                  ],
                ),
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
