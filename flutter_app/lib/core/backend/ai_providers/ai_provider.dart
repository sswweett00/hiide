/// Unified interface for all AI providers (Groq, OpenAI, Anthropic, Ollama).
///
/// Every provider implements [chatCompletion] with OpenAI-compatible tool
/// calling, plus a [streamChat] variant for real-time token output. The
/// provider manager falls back through a chain when one is unavailable.
abstract class AiProvider {
  /// Human-readable label shown in Settings (e.g. "Groq", "OpenAI").
  String get displayName;

  /// Stable id used for persistence (e.g. "groq", "openai", "ollama").
  String get id;

  /// Whether this provider needs an API key (Ollama does not).
  bool get requiresApiKey;

  /// Default model used when the UI has not selected a provider-specific model.
  String get defaultModel;

  /// Whether this provider has enough credentials/configuration to be used.
  bool get isConfigured => !requiresApiKey;

  /// Whether the provider is reachable right now.
  Future<bool> get isAvailable;

  /// Send a chat completion request with optional tool definitions.
  /// Returns the raw decoded JSON response body.
  Future<Map<String, dynamic>> chatCompletion({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    String? model,
    double temperature = 0.2,
  });

  /// Stream response tokens for real-time typing effect.
  Stream<String> chatCompletionStream({
    required List<Map<String, dynamic>> messages,
    String? model,
  });

  /// Short single-line code completion (convenience wrapper).
  Future<String?> completeCode(String prompt, {String? model});

  /// Models actually served by this provider (for the settings dropdown).
  Future<List<String>> fetchAvailableModels();
}

/// Identifies which provider the user has selected.
enum AiProviderType {
  groq,
  openai,
  anthropic,
  ollama,
  openrouter,
  deepseek,
  mistral,
  together,
  fireworks,
  perplexity,
  xai,
  gemini,
  cerebras,
}

/// Parses a string id into an [AiProviderType], defaulting to Groq.
AiProviderType aiProviderTypeFromId(String id) {
  return AiProviderType.values.firstWhere(
    (t) => t.name == id,
    orElse: () => AiProviderType.groq,
  );
}
