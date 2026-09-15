/// Contract for the LLM chat client used by the agent loop.
///
/// [GroqAiService] is the production implementation; tests inject a scripted
/// fake to exercise the agent loop without network access.
abstract class AiChatClient {
  /// Sends a chat completion request with optional OpenAI-style tool
  /// definitions. Returns the raw decoded JSON response body.
  Future<Map<String, dynamic>> chatCompletion({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    String? model,
    double temperature,
  });

  /// Streams response tokens for real-time typing effect.
  Stream<String> chatCompletionStream({
    required List<Map<String, dynamic>> messages,
    String? model,
  });
}
