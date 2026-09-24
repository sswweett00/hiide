import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ai_provider.dart';
import 'anthropic_provider.dart';
import 'openai_compatible_provider.dart';
import '../ai_chat_client.dart';
import '../../mechanics/circuit_breaker.dart';

/// Runtime catalog entry for a hosted or local provider.
class BuiltInAiProviderSpec {
  const BuiltInAiProviderSpec({
    required this.id,
    required this.displayName,
    required this.baseUrl,
    required this.defaultModel,
    this.requiresApiKey = true,
    this.envKey,
    this.extraHeaders = const <String, String>{},
    this.apiKeyHeader = 'Authorization',
    this.apiKeyPrefix = 'Bearer ',
  });

  final String id;
  final String displayName;
  final String baseUrl;
  final String defaultModel;
  final bool requiresApiKey;
  final String? envKey;
  final Map<String, String> extraHeaders;
  final String apiKeyHeader;
  final String apiKeyPrefix;
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
      defaultModel: 'deepseek-chat',
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
      defaultModel: 'sonar',
      envKey: 'PERPLEXITY_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'xai',
      displayName: 'xAI (Grok)',
      baseUrl: 'https://api.x.ai/v1',
      defaultModel: 'grok-4',
      envKey: 'XAI_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'gemini',
      displayName: 'Google Gemini',
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
      defaultModel: 'gemini-2.5-flash',
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
      id: 'cohere',
      displayName: 'Cohere',
      baseUrl: 'https://api.cohere.com/compatibility/v1',
      defaultModel: 'command-a-03-2025',
      envKey: 'COHERE_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'nvidia',
      displayName: 'NVIDIA NIM',
      baseUrl: 'https://integrate.api.nvidia.com/v1',
      defaultModel: 'moonshotai/kimi-k2.6',
      envKey: 'NVIDIA_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'sambanova',
      displayName: 'SambaNova',
      baseUrl: 'https://api.sambanova.ai/v1',
      defaultModel: 'Meta-Llama-3.3-70B-Instruct',
      envKey: 'SAMBANOVA_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'deepinfra',
      displayName: 'DeepInfra',
      baseUrl: 'https://api.deepinfra.com/v1/openai',
      defaultModel: 'meta-llama/Meta-Llama-3.3-70B-Instruct',
      envKey: 'DEEPINFRA_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'huggingface',
      displayName: 'Hugging Face',
      baseUrl: 'https://router.huggingface.co/v1',
      defaultModel: 'meta-llama/Llama-3.3-70B-Instruct',
      envKey: 'HF_TOKEN',
    ),
    BuiltInAiProviderSpec(
      id: 'qwen',
      displayName: 'Qwen / Alibaba Cloud',
      baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      defaultModel: 'qwen-plus',
      envKey: 'DASHSCOPE_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'siliconflow',
      displayName: 'SiliconFlow',
      baseUrl: 'https://api.siliconflow.com/v1',
      defaultModel: 'Qwen/Qwen3-8B',
      envKey: 'SILICONFLOW_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'novita',
      displayName: 'Novita AI',
      baseUrl: 'https://api.novita.ai/openai',
      defaultModel: 'meta-llama/llama-3.1-70b-instruct',
      envKey: 'NOVITA_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'baseten',
      displayName: 'Baseten',
      baseUrl: 'https://inference.baseten.co/v1',
      defaultModel: 'moonshotai/Kimi-K2-Instruct-0905',
      envKey: 'BASETEN_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'friendli',
      displayName: 'FriendliAI',
      baseUrl: 'https://api.friendli.ai/serverless/v1',
      defaultModel: 'meta-llama-3.1-70b-instruct',
      envKey: 'FRIENDLI_TOKEN',
    ),
    BuiltInAiProviderSpec(
      id: 'ai21',
      displayName: 'AI21 Labs',
      baseUrl: 'https://api.ai21.com/studio/v1',
      defaultModel: 'jamba-large',
      envKey: 'AI21_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'opencode-zen',
      displayName: 'OpenCode Zen',
      baseUrl: 'https://opencode.ai/zen/v1',
      defaultModel: 'claude-sonnet-4-6',
      envKey: 'OPENCODE_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'lm-studio',
      displayName: 'LM Studio (Local)',
      baseUrl: 'http://127.0.0.1:1234/v1',
      defaultModel: 'local-model',
      requiresApiKey: false,
    ),
    BuiltInAiProviderSpec(
      id: 'vllm',
      displayName: 'vLLM (Local / Self-hosted)',
      baseUrl: 'http://127.0.0.1:8000/v1',
      defaultModel: 'local-model',
      requiresApiKey: false,
    ),
    BuiltInAiProviderSpec(
      id: 'azure-openai',
      displayName: 'Azure OpenAI / Foundry',
      baseUrl: 'https://YOUR-RESOURCE-NAME.openai.azure.com/openai/v1',
      defaultModel: 'gpt-4.1-mini',
      envKey: 'AZURE_OPENAI_API_KEY',
      extraHeaders: const {},
      apiKeyHeader: 'api-key',
      apiKeyPrefix: '',
    ),
    BuiltInAiProviderSpec(
      id: 'litellm',
      displayName: 'LiteLLM Gateway',
      baseUrl: 'http://127.0.0.1:4000/v1',
      defaultModel: 'gpt-4o-mini',
      envKey: 'LITELLM_API_KEY',
    ),
    BuiltInAiProviderSpec(
      id: 'ollama',
      displayName: 'Ollama (Local)',
      baseUrl: 'http://127.0.0.1:11434/v1',
      defaultModel: 'llama3.2',
      requiresApiKey: false,
    ),
  ]

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
  final Map<String, _AvailabilityEntry> _availabilityCache =
      <String, _AvailabilityEntry>{};
  final Map<String, CircuitBreaker> _providerBreakers =
      <String, CircuitBreaker>{};
  final Map<String, _ModelCacheEntry> _modelCache =
      <String, _ModelCacheEntry>{};
  final Map<String, Future<List<String>>> _modelRequests =
      <String, Future<List<String>>>{};
  final Map<String, _ProviderRuntimeState> _runtimeStats =
      <String, _ProviderRuntimeState>{};

  static const _availabilityTtl = Duration(seconds: 15);
  static const _modelCacheTtl = Duration(minutes: 2);
  static const _providerResetTimeout = Duration(seconds: 20);

  AiProvider get active =>
      _providers.firstWhere((p) => p.id == _activeProviderId, orElse: () => _providers.first);

  String get activeProviderId => active.id;

  String get activeModel {
    final selected = _selectedModels[active.id]?.trim();
    return selected == null || selected.isEmpty ? active.defaultModel : selected;
  }

  List<AiProvider> get available => List.unmodifiable(_providers);

  Map<String, ProviderRuntimeSnapshot> get runtimeStats {
    return {
      for (final provider in _providers)
        provider.id: (_runtimeStats[provider.id] ?? _ProviderRuntimeState())
            .snapshot(),
    };
  }

  _ProviderRuntimeState _runtimeStateFor(String providerId) {
    return _runtimeStats.putIfAbsent(
      providerId,
      _ProviderRuntimeState.new,
    );
  }

  void _recordRuntime(
    String providerId,
    Duration latency, {
    required bool success,
  }) {
    _runtimeStateFor(providerId).record(latency, success: success);
  }

  CircuitBreaker _breakerFor(String providerId) {
    return _providerBreakers.putIfAbsent(
      providerId,
      () => CircuitBreaker(
        failureThreshold: 3,
        resetTimeout: _providerResetTimeout,
      ),
    );
  }

  Future<bool> _cachedAvailability(AiProvider provider) async {
    if (!provider.isConfigured) return false;

    final now = DateTime.now();
    final cached = _availabilityCache[provider.id];
    if (cached != null && now.difference(cached.checkedAt) < _availabilityTtl) {
      return cached.available;
    }

    try {
      final available = await provider.isAvailable;
      _availabilityCache[provider.id] =
          _AvailabilityEntry(checkedAt: now, available: available);
      return available;
    } catch (_) {
      _availabilityCache[provider.id] =
          _AvailabilityEntry(checkedAt: now, available: false);
      return false;
    }
  }

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
    if (preferred != null && await _cachedAvailability(preferred)) {
      return preferred;
    }

    for (final provider in _providers) {
      if (preferred != null && identical(provider, preferred)) continue;
      if (await _cachedAvailability(provider)) {
        _activeProviderId = provider.id;
        return provider;
      }
    }

    return preferred ?? _providers.first;
  }

  void switchTo(String providerId) {
    if (_providers.any((p) => p.id == providerId)) {
      _activeProviderId = providerId;
      _availabilityCache.remove(providerId);
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
    if (!provider.isConfigured) return const [];

    final now = DateTime.now();
    final cached = _modelCache[provider.id];
    if (cached != null && now.difference(cached.fetchedAt) < _modelCacheTtl) {
      return cached.models;
    }

    final inFlight = _modelRequests[provider.id];
    if (inFlight != null) return inFlight;

    final request = _fetchModelsUncached(provider);
    _modelRequests[provider.id] = request;
    try {
      return await request;
    } finally {
      _modelRequests.remove(provider.id);
    }
  }

  Future<List<String>> _fetchModelsUncached(AiProvider provider) async {
    try {
      final models = await provider.fetchAvailableModels();
      _modelCache[provider.id] = _ModelCacheEntry(
        fetchedAt: DateTime.now(),
        models: List<String>.unmodifiable(models),
      );
      return models;
    } catch (_) {
      return const [];
    }
  }

  Future<Map<String, dynamic>> _request(
    AiProvider provider, {
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    required String model,
    required double temperature,
  }) async {
    final breaker = _breakerFor(provider.id);
    if (breaker.state == CircuitState.open) {
      throw CircuitOpenException(DateTime.now().add(_providerResetTimeout));
    }
    return breaker.run(() async {
      final result = await provider.chatCompletion(
        messages: messages,
        tools: tools,
        model: model,
        temperature: temperature,
      );
      final error = result['error']?.toString().trim() ?? '';
      if (error.isNotEmpty) throw _ProviderRequestException(error);
      return result;
    });
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

  List<AiProvider> _orderedProviders() {
    if (_providers.isEmpty) return const [];

    final ordered = List<AiProvider>.from(_providers);
    ordered.sort((a, b) {
      if (a.id == _activeProviderId) return -1;
      if (b.id == _activeProviderId) return 1;

      final sa = _runtimeStats[a.id]?.routeScore ?? 0;
      final sb = _runtimeStats[b.id]?.routeScore ?? 0;
      if (sa != sb) return sa.compareTo(sb);
      return a.id.compareTo(b.id);
    });
    return ordered;
  }

  @override
  Future<Map<String, dynamic>> chatCompletion({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    String? model,
    double temperature = 0.2,
  }) async {
    final requestedProviderId = _activeProviderId;
    Object? lastError;

    for (final provider in _orderedProviders()) {
      if (!provider.isConfigured) continue;
      if (_breakerFor(provider.id).state == CircuitState.open) continue;

      // Availability probes are advisory. A provider can omit /models while
      // still supporting chat completions, so the real request is authoritative.
      final requestModel = _modelFor(
        provider,
        requestedModel: model,
        requestedProviderId: requestedProviderId,
      );

      final started = DateTime.now();
      try {
        final result = await _request(
          provider,
          messages: messages,
          tools: tools,
          model: requestModel,
          temperature: temperature,
        );
        _recordRuntime(provider.id, DateTime.now().difference(started), success: true);
        _activeProviderId = provider.id;
        _availabilityCache[provider.id] = _AvailabilityEntry(
          checkedAt: DateTime.now(),
          available: true,
        );
        return result;
      } catch (error) {
        _recordRuntime(
          provider.id,
          DateTime.now().difference(started),
          success: false,
        );
        lastError = error;
      }
    }

    return {
      'error': lastError?.toString() ??
          'No configured AI provider could complete the request.',
    };
  }

  @override
  Stream<String> chatCompletionStream({
    required List<Map<String, dynamic>> messages,
    String? model,
  }) async* {
    if (_providers.isEmpty) {
      yield 'No AI providers are configured.';
      return;
    }

    final requestedProviderId = _activeProviderId;
    Object? lastError;

    for (final provider in _orderedProviders()) {
      if (!provider.isConfigured) continue;
      if (_breakerFor(provider.id).state == CircuitState.open) continue;

      final requestModel = _modelFor(
        provider,
        requestedModel: model,
        requestedProviderId: requestedProviderId,
      );

      var emitted = false;
      final started = DateTime.now();
      try {
        await for (final chunk in provider.chatCompletionStream(
          messages: messages,
          model: requestModel,
        )) {
          emitted = true;
          yield chunk;
        }
        if (emitted) {
          _recordRuntime(provider.id, DateTime.now().difference(started), success: true);
          _activeProviderId = provider.id;
          _breakerFor(provider.id).recordSuccess();
          _availabilityCache[provider.id] = _AvailabilityEntry(
            checkedAt: DateTime.now(),
            available: true,
          );
          return;
        }
        lastError = StateError(
          provider.id + ' did not emit any streaming content.',
        );
        _breakerFor(provider.id).recordFailure();
      } catch (error) {
        _breakerFor(provider.id).recordFailure();
        _recordRuntime(provider.id, DateTime.now().difference(started), success: false);
        lastError = error;
        // Once a stream has emitted content, switching providers would append
        // a second, unrelated completion to the same answer.
        if (emitted) {
          yield '[' + provider.id + ' stream interrupted: ' + error.toString() + ']';
          return;
        }
      }
    }

    yield 'All configured AI providers failed. ' +
        (lastError?.toString() ?? '');
  }

  Future<String?> completeCode(String prompt, {String? model}) async {
    final requestedProviderId = _activeProviderId;
    for (final provider in _orderedProviders()) {
      if (!provider.isConfigured) continue;
      if (_breakerFor(provider.id).state == CircuitState.open) continue;
      final started = DateTime.now();
      try {
        final value = await _breakerFor(provider.id).run(() async {
          final result = await provider.completeCode(
            prompt,
            model: _modelFor(
              provider,
              requestedModel: model,
              requestedProviderId: requestedProviderId,
            ),
          );
          if (result == null || result.trim().isEmpty) {
            throw const _ProviderRequestException(
              'Code completion returned no content.',
            );
          }
          return result;
        });
        _recordRuntime(provider.id, DateTime.now().difference(started), success: true);
        _activeProviderId = provider.id;
        return value;
      } catch (_) {
        _recordRuntime(provider.id, DateTime.now().difference(started), success: false);
      }
    }
    return null;
  }

  /// There is deliberately no write-side API for secrets here. Credentials
  /// enter via SettingsService/Riverpod and are passed to providers by value.
}


/// Short-lived provider reachability cache used to avoid an HTTP availability
/// probe before every streamed completion.
class _AvailabilityEntry {
  const _AvailabilityEntry({
    required this.checkedAt,
    required this.available,
  });

  final DateTime checkedAt;
  final bool available;
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

/// Per-provider endpoint overrides. This enables deployment-specific endpoints
/// such as Azure OpenAI without changing the provider transport.
final aiProviderBaseUrlsProvider =
    StateProvider<Map<String, String>>((ref) => const <String, String>{});

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
  final baseUrls = ref.watch(aiProviderBaseUrlsProvider);
  final activeId = ref.watch(aiProviderIdProvider);
  final models = ref.watch(aiProviderModelsProvider);

  final providers = <AiProvider>[];

  for (final spec in AiProviderCatalog.specs) {
    final key = keys[spec.id] ?? '';
    providers.add(
      OpenAiCompatibleProvider(
        id: spec.id,
        displayName: spec.displayName,
        baseUrl: baseUrls[spec.id]?.trim().isNotEmpty == true
            ? baseUrls[spec.id]!
            : spec.baseUrl,
        apiKey: key,
        defaultModel: spec.defaultModel,
        requiresApiKey: spec.requiresApiKey,
        extraHeaders: spec.extraHeaders,
        apiKeyHeader: spec.apiKeyHeader,
        apiKeyPrefix: spec.apiKeyPrefix,
      ),
    );
  }

  final anthropicBaseUrl = baseUrls['anthropic']?.trim().isNotEmpty == true
      ? baseUrls['anthropic']!
      : 'https://api.anthropic.com/v1';
  providers.add(
    AnthropicProvider(
      apiKey: keys['anthropic'] ?? '',
      baseUrl: anthropicBaseUrl,
    ),
  );

  for (final raw in custom) {
    final id = raw['id']?.trim() ?? '';
    final name = raw['name']?.trim() ?? '';
    final baseUrl = raw['baseUrl']?.trim() ?? '';
    final model = raw['model']?.trim() ?? '';
    if (id.isEmpty || name.isEmpty || baseUrl.isEmpty || model.isEmpty) {
      continue;
    }
    if (AiProviderCatalog.byId(id) != null) {
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


class _ProviderRequestException implements Exception {
  const _ProviderRequestException(this.message);
  final String message;
  @override
  String toString() => message;
}

class _ModelCacheEntry {
  const _ModelCacheEntry({
    required this.fetchedAt,
    required this.models,
  });

  final DateTime fetchedAt;
  final List<String> models;
}


class ProviderRuntimeSnapshot {
  const ProviderRuntimeSnapshot({
    required this.successes,
    required this.failures,
    required this.averageLatencyMs,
  });

  final int successes;
  final int failures;
  final double averageLatencyMs;

  double get routeScore =>
      failures * 10 + averageLatencyMs / 1000.0;
}

class _ProviderRuntimeState {
  int successes = 0;
  int failures = 0;
  double averageLatencyMs = 0;

  double get routeScore => failures * 10 + averageLatencyMs / 1000.0;

  void record(Duration latency, {required bool success}) {
    final value = latency.inMicroseconds / 1000.0;
    if (success) {
      successes++;
    } else {
      failures++;
    }

    final total = successes + failures;
    if (total == 1) {
      averageLatencyMs = value;
    } else {
      // Exponential smoothing avoids overreacting to one slow response while
      // still adapting quickly when a provider degrades.
      const alpha = 0.25;
      averageLatencyMs =
          averageLatencyMs * (1 - alpha) + value * alpha;
    }
  }

  ProviderRuntimeSnapshot snapshot() {
    return ProviderRuntimeSnapshot(
      successes: successes,
      failures: failures,
      averageLatencyMs: averageLatencyMs,
    );
  }
}
