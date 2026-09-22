import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'ai_provider.dart';
import 'groq_provider.dart';
import 'openai_provider.dart';
import 'anthropic_provider.dart';
import 'ollama_provider.dart';
import '../ai_chat_client.dart';

/// Manages the active AI provider and handles fallback through a chain
/// when the primary provider is unavailable. Exposes a single
/// [AiChatClient] interface so the rest of the app doesn't care which
/// provider is active.
class ProviderManager implements AiChatClient {
  final List<AiProvider> _providers;
  int _activeIndex;

  ProviderManager(this._providers) : _activeIndex = 0;

  /// The currently selected provider.
  AiProvider get active => _providers[_activeIndex];

  /// All registered providers (for the settings dropdown).
  List<AiProvider> get available => List.unmodifiable(_providers);

  /// Try each provider, prioritizing the user's selected active provider.
  Future<AiProvider> _resolve() async {
    if (_providers.isEmpty) {
      throw StateError('No AI providers registered');
    }
    // Prioritize the user's selected provider if it is available.
    if (_activeIndex >= 0 && _activeIndex < _providers.length) {
      try {
        if (await _providers[_activeIndex].isAvailable) {
          return _providers[_activeIndex];
        }
      } catch (_) {}
    }
    // Fall back to the first available provider.
    for (var i = 0; i < _providers.length; i++) {
      if (i == _activeIndex) continue;
      try {
        if (await _providers[i].isAvailable) {
          _activeIndex = i;
          return _providers[i];
        }
      } catch (_) {}
    }
    // Fall back to the selected active provider even if unavailable
    // (the specific provider error will surface naturally).
    return active;
  }

  /// Switch the active provider by id.
  void switchTo(String providerId) {
    final idx = _providers.indexWhere((p) => p.id == providerId);
    if (idx >= 0) _activeIndex = idx;
  }

  // ─── AiChatClient implementation ──────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> chatCompletion({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    String? model,
    double temperature = 0.2,
  }) async {
    final provider = await _resolve();
    return provider.chatCompletion(
      messages: messages,
      tools: tools,
      model: model,
      temperature: temperature,
    );
  }

  @override
  Stream<String> chatCompletionStream({
    required List<Map<String, dynamic>> messages,
    String? model,
  }) async* {
    final provider = await _resolve();
    yield* provider.chatCompletionStream(messages: messages, model: model);
  }
}

// ─── Riverpod providers ──────────────────────────────────────────────────────

/// The active provider type, persisted in settings.
final aiProviderTypeProvider = StateProvider<AiProviderType>((ref) {
  return AiProviderType.groq;
});

/// Groq API key.
final groqApiKeyProvider = StateProvider<String>((ref) => '');

/// OpenAI API key.
final openaiApiKeyProvider = StateProvider<String>((ref) => '');

/// Anthropic API key.
final anthropicApiKeyProvider = StateProvider<String>((ref) => '');

/// Ollama base URL.
final ollamaUrlProvider =
    StateProvider<String>((ref) => 'http://127.0.0.1:11434');

/// Selected model per provider.
final selectedModelProvider = StateProvider<String>((ref) => '');

/// Creates the provider manager with all registered providers.
final providerManagerProvider = Provider<ProviderManager>((ref) {
  final groqKey = ref.watch(groqApiKeyProvider);
  final openaiKey = ref.watch(openaiApiKeyProvider);
  final anthropicKey = ref.watch(anthropicApiKeyProvider);
  final ollamaUrl = ref.watch(ollamaUrlProvider);
  final type = ref.watch(aiProviderTypeProvider);

  final providers = <AiProvider>[
    GroqProvider(apiKey: groqKey),
    OpenAiProvider(apiKey: openaiKey),
    AnthropicProvider(apiKey: anthropicKey),
    OllamaProvider(baseUrl: ollamaUrl),
  ];

  final manager = ProviderManager(providers);
  manager.switchTo(type.name);
  return manager;
});

/// The unified AI chat client used by the agent controller and editor.
final unifiedAiClientProvider = Provider<AiChatClient>((ref) {
  return ref.watch(providerManagerProvider);
});
