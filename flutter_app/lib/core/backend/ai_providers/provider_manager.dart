import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ai_provider.dart';
import 'anthropic_provider.dart';
import 'openai_compatible_provider.dart';
import '../ai_chat_client.dart';

/// Runtime catalog entry for a hosted or local provider.
class BuiltInAiProviderSpec {
  const BuiltInAiProviderSpec({
    required this.id,
    required this.displayName,
    required this.baseUrl,
    required this.defaultModel,
    this.requiresApiKey = true,
    this.envKey,
  });

  final String id;
  final String displayName;
  final String baseUrl;
  final String defaultModel;
  final bool requiresApiKey;
  final String? envKey;
}

/// Providers shipped with Hiide. OpenAI-compatible services all share the same
/// transport, so adding another compatible endpoint does not require changing
/// the agent runtime.
class AiProviderCatalog {
  static const specs = <BuiltInAiProviderSpec>[
    BuiltInAiProviderSpec(
      id: 'groq',
      displayName: 'Groq',
      baseUrl: 'https://api.groq.com/openai/v1',
      defaultModel: 'openai/gpt-oss-120b',
      envKey: 'GROQ_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'openai',
      displayName: 'OpenAI',
      baseUrl: 'https://api.openai.com/v1',
      defaultModel: 'gpt-4o-mini',
      envKey: 'OPENAI_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'openrouter',
      displayName: 'OpenRouter',
      baseUrl: 'https://openrouter.ai/api/v1',
      defaultModel: 'openai/gpt-4o-mini',
      envKey: 'OPENROUTER_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'deepseek',
      displayName: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com',
      defaultModel: 'deepseek-flash',
      envKey: 'DEEPSEEK_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'mistral',
      displayName: 'Mistral',
      baseUrl: 'https://api.mistral.ai/v1',
      defaultModel: 'mistral-large-latest',
      envKey: 'MISTRAL_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'together',
      displayName: 'Together AI',
      baseUrl: 'https://api.together.xyz/v1',
      defaultModel: 'meta-llama/Llama-3.3-70B-Instruct-Turbo',
      envKey: 'TOGETHER_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'fireworks',
      displayName: 'Fireworks AI',
      baseUrl: 'https://api.fireworks.ai/inference/v1',
      defaultModel: 'accounts/fireworks/models/llama-v3p1-70b-instruct',
      envKey: 'FIREWORKS_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'perplexity',
      displayName: 'Perplexity',
      baseUrl: 'https://api.perplexity.ai',
      defaultModel: 'sonar-pro',
      envKey: 'PERPLEXITY_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'xai',
      displayName: 'xAI (Grok)',
      baseUrl: 'https://api.x.ai/v1',
      defaultModel: 'grok-4.7',
      envKey: 'XAI_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'gemini',
      displayName: 'Google Gemini',
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
      defaultModel: 'gemini-3.8-flash',
      envKey: 'GEMINI_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'cerebras',
      displayName: 'Cerebras',
      baseUrl: 'https://api.cerebras.ai/v1',
      defaultModel: 'llama-3.3-70b',
      envKey: 'CEREBRAS_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'ollama',
      displayName: 'Ollama (Local)',
      baseUrl: 'http://127.0.0.1:11434/v1',
      defaultModel: 'llama3.2',
      requiresApiKey: false,
    ),
  ];

  static BuiltInAiProviderSpec? byId(String id) {
    for (final spec in specs) {
      if (spec.id == id) return spec;
    }
    return null;
  }

  static String displayNameFor(String id) {
    return byId(id)?.displayName ?? id;
  }
}

/// Manages all configured providers and provides one stable AI contract to the
/// rest of Hiide. Fallback happens at request time: a broken primary endpoint
/// does not make the agent runtime unusable when another configured endpoint is
/// available.
class ProviderManager implements AiChatClient {
  ProviderManager(
    this._providers, {
    required String activeProviderId,
    required Map<String, String> selectedModels,
  })  : _activeProviderId = activeProviderId,
        _selectedModels = Map<String, String>.from(selectedModels);

  final List<AiProvider> _providers;
  String _activeProviderId;
  final Map<String, String> _selectedModels;

  AiProvider get active =>
      _providers.firstWhere((p) => p.id == _activeProviderId, orElse: () => _providers.first);

  String get activeProviderId => active.id;

  String get activeModel {
    final selected = _selectedModels[active.id]?.trim();
    return selected == null || selected.isEmpty ? active.defaultModel : selected;
  }

  List<AiProvider> get available => List.unmodifiable(_providers);

  Future<AiProvider> _resolve() async {
    if (_providers.isEmpty) {
      throw StateError('No AI providers registered');
    }

    AiProvider? preferred;
    for (final provider in _providers) {
      if (provider.id == _activeProviderId) {
        preferred = provider;
        break;
      }
    }
    if (preferred != null) {
      try {
        if (await preferred.isAvailable) return preferred;
      } catch (_) {}
    }

    for (final provider in _providers) {
      if (preferred != null && identical(provider, preferred)) continue;
      try {
        if (await provider.isAvailable) {
          _activeProviderId = provider.id;
          return provider;
        }
      } catch (_) {}
    }

    return preferred ?? _providers.first;
  }

  void switchTo(String providerId) {
    if (_providers.any((p) => p.id == providerId)) {
      _activeProviderId = providerId;
    }
  }

  void setModel(String providerId, String model) {
    final value = model.trim();
    if (value.isEmpty) {
      _selectedModels.remove(providerId);
    } else {
      _selectedModels[providerId] = value;
    }
  }

  Future<List<String>> fetchModels([String? providerId]) async {
    final provider = providerId == null
        ? active
        : _providers.firstWhere(
            (p) => p.id == providerId,
            orElse: () => active,
          );
    return provider.fetchAvailableModels();
  }

  String _modelFor(
    AiProvider provider, {
    String? requestedModel,
    required String requestedProviderId,
  }) {
    // A model id belongs to its provider. When runtime fallback selects a
    // different provider, never forward the previous provider's id.
    if (provider.id == requestedProviderId &&
        requestedModel != null &&
        requestedModel.trim().isNotEmpty) {
      return requestedModel.trim();
    }
    return _selectedModels[provider.id] ?? provider.defaultModel;
  }

  @override
  Future<Map<String, dynamic>> chatCompletion({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    String? model,
    double temperature = 0.2,
  }) async {
    final requestedProviderId = _activeProviderId;
    final provider = await _resolve();
    return provider.chatCompletion(
      messages: messages,
      tools: tools,
      model: _modelFor(
        provider,
        requestedModel: model,
        requestedProviderId: requestedProviderId,
      ),
      temperature: temperature,
    );
  }

  @override
  Stream<String> chatCompletionStream({
    required List<Map<String, dynamic>> messages,
    String? model,
  }) async* {
    final requestedProviderId = _activeProviderId;
    final provider = await _resolve();
    yield* provider.chatCompletionStream(
      messages: messages,
      model: _modelFor(
        provider,
        requestedModel: model,
        requestedProviderId: requestedProviderId,
      ),
    );
  }

  @override
  Future<String?> completeCode(String prompt, {String? model}) async {
    final requestedProviderId = _activeProviderId;
    final provider = await _resolve();
    return provider.completeCode(
      prompt,
      model: _modelFor(
        provider,
        requestedModel: model,
        requestedProviderId: requestedProviderId,
      ),
    );
  }

  /// There is deliberately no write-side API for secrets here. Credentials
  /// enter via SettingsService/Riverpod and are passed to providers by value.
}

final aiProviderIdProvider = StateProvider<String>((ref) => 'groq');

/// Kept for compatibility with older settings/tests. New code should prefer
/// [aiProviderIdProvider] because it also supports custom providers.
final aiProviderTypeProvider = StateProvider<AiProviderType>((ref) {
  return AiProviderType.groq;
});

final aiProviderKeysProvider =
    StateProvider<Map<String, String>>((ref) => const <String, String>{});

final aiProviderModelsProvider =
    StateProvider<Map<String, String>>((ref) => const <String, String>{});

/// Custom OpenAI-compatible endpoints. Each map must contain at least id,
/// name, baseUrl, and model. The API key is kept in [aiProviderKeysProvider].
final customAiProvidersProvider =
    StateProvider<List<Map<String, String>>>((ref) => const []);

final groqApiKeyProvider = StateProvider<String>((ref) {
  return ref.watch(aiProviderKeysProvider)['groq'] ?? '';
});
final openaiApiKeyProvider = StateProvider<String>((ref) {
  return ref.watch(aiProviderKeysProvider)['openai'] ?? '';
});
final anthropicApiKeyProvider = StateProvider<String>((ref) {
  return ref.watch(aiProviderKeysProvider)['anthropic'] ?? '';
});
final ollamaUrlProvider =
    StateProvider<String>((ref) => 'http://127.0.0.1:11434');

final selectedModelProvider = StateProvider<String>((ref) => '');

final providerManagerProvider = Provider<ProviderManager>((ref) {
  final keys = ref.watch(aiProviderKeysProvider);
  final custom = ref.watch(customAiProvidersProvider);
  final activeId = ref.watch(aiProviderIdProvider);
  final models = ref.watch(aiProviderModelsProvider);

  final providers = <AiProvider>[];

  for (final spec in AiProviderCatalog.specs) {
    final key = keys[spec.id] ?? '';
    providers.add(
      OpenAiCompatibleProvider(
        id: spec.id,
        displayName: spec.displayName,
        baseUrl: spec.baseUrl,
        apiKey: key,
        defaultModel: spec.defaultModel,
        requiresApiKey: spec.requiresApiKey,
      ),
    );
  }

  if ((keys['anthropic'] ?? '').isNotEmpty) {
    providers.add(
      AnthropicProvider(apiKey: keys['anthropic']!),
    );
  } else {
    providers.add(AnthropicProvider(apiKey: ''));
  }

  for (final raw in custom) {
    final id = raw['id']?.trim() ?? '';
    final name = raw['name']?.trim() ?? '';
    final baseUrl = raw['baseUrl']?.trim() ?? '';
    final model = raw['model']?.trim() ?? '';
    if (id.isEmpty || name.isEmpty || baseUrl.isEmpty || model.isEmpty) {
      continue;
    }
    providers.add(
      OpenAiCompatibleProvider(
        id: id,
        displayName: name,
        baseUrl: baseUrl,
        apiKey: keys[id] ?? '',
        defaultModel: model,
      ),
    );
  }

  final manager = ProviderManager(
    providers,
    activeProviderId: activeId,
    selectedModels: models,
  );
  return manager;
});

final unifiedAiClientProvider = Provider<AiChatClient>((ref) {
  return ref.watch(providerManagerProvider);
});
