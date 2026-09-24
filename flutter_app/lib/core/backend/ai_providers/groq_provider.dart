import 'package:http/http.dart' as http;

import 'ai_provider.dart';
import '../groq_ai_service.dart';

/// Groq provider — wraps the existing [GroqAiService] behind the unified
/// [AiProvider] interface.
class GroqProvider implements AiProvider {
  final String apiKey;
  late final GroqAiService _service;

  GroqProvider({required this.apiKey, http.Client? client})
      : _service = GroqAiService(apiKey: apiKey, client: client);

  @override
  String get displayName => 'Groq';

  @override
  String get baseUrl => 'https://api.groq.com/openai/v1';

  @override
  String get baseUrl => 'https://api.groq.com/openai/v1';

  @override
  String get defaultModel => 'openai/gpt-oss-120b';

  @override
  String get id => 'groq';

  @override
  bool get requiresApiKey => true;

  @override
  bool get isConfigured => apiKey.trim().isNotEmpty;

  @override
  Future<bool> get isAvailable async {
    if (apiKey.isEmpty) return false;
    final result = await _service.checkConnection();
    return result.ok;
  }

  @override
  Future<Map<String, dynamic>> chatCompletion({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    String? model,
    double temperature = 0.2,
  }) {
    return _service.chatCompletion(
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
  }) {
    return _service.chatCompletionStream(messages: messages, model: model);
  }

  @override
  Future<String?> completeCode(String prompt, {String? model}) {
    return _service.completeCode(prompt, model: model);
  }

  @override
  Future<List<String>> fetchAvailableModels() {
    return _service.fetchModelIds();
  }
}
