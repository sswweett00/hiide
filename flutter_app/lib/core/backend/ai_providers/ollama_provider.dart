import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'ai_provider.dart';

/// Local Ollama provider — runs models on the user's machine with no API key.
/// Ollama serves an OpenAI-compatible API on port 11434 by default.
class OllamaProvider implements AiProvider {
  String baseUrl;
  String _selectedModel;
  final http.Client _client;

  OllamaProvider({
    this.baseUrl = 'http://127.0.0.1:11434',
    String selectedModel = 'llama3.2',
    http.Client? client,
  })  : _selectedModel = selectedModel,
        _client = client ?? http.Client();

  @override
  String get displayName => 'Ollama (Local)';

  @override
  String get defaultModel => _selectedModel;

  @override
  String get id => 'ollama';

  @override
  bool get requiresApiKey => false;

  @override
  bool get isConfigured => true;

  @override
  Future<bool> get isAvailable async {
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/api/tags'))
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Map<String, dynamic>> chatCompletion({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    String? model,
    double temperature = 0.2,
  }) async {
    // Ollama uses the OpenAI-compatible endpoint
    final body = <String, dynamic>{
      'model': model ?? _selectedModel,
      'messages': messages,
      'temperature': temperature,
      'stream': false,
    };

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools;
    }

    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/v1/chat/completions'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 120));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return {
        'error': 'Ollama error ${response.statusCode}: ${response.body}',
      };
    } catch (e) {
      return {'error': 'Ollama not reachable: $e'};
    }
  }

  @override
  Stream<String> chatCompletionStream({
    required List<Map<String, dynamic>> messages,
    String? model,
  }) async* {
    final request = http.Request(
      'POST',
      Uri.parse('$baseUrl/v1/chat/completions'),
    )
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'model': model ?? _selectedModel,
        'messages': messages,
        'stream': true,
      });

    try {
      final response = await _client.send(request);
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        yield 'Error ${response.statusCode}: $body';
        return;
      }

      final stream = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in stream) {
        if (line.startsWith('data: ')) {
          final data = line.substring(6).trim();
          if (data == '[DONE]') break;
          try {
            final json = jsonDecode(data);
            final content = json['choices']?[0]?['delta']?['content'];
            if (content != null) yield content.toString();
          } catch (_) {}
        }
      }
    }
  }

  @override
  Future<String?> completeCode(String prompt, {String? model}) async {
    final response = await chatCompletion(
      messages: [
        {
          'role': 'system',
          'content':
              'You are an expert code completion engine. Complete the code that follows the caret. Reply with ONLY the completion text — no explanations, no markdown fences. Keep it on a single line unless a newline is required.',
        },
        {'role': 'user', 'content': prompt},
      ],
      model: model,
      temperature: 0.2,
    );
    if (response.containsKey('error')) return null;
    final choices = response['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final message = (choices.first as Map<String, dynamic>)['message'];
    final content = message?['content']?.toString().trim();
    return (content != null && content.isNotEmpty) ? content : null;
  }

  @override
  Future<List<String>> fetchAvailableModels() async {
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/api/tags'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return const [];
      final decoded = jsonDecode(response.body);
      final models = decoded['models'];
      if (models is! List) return const [];
      return models
          .whereType<Map<String, dynamic>>()
          .map((m) => m['name']?.toString() ?? '')
          .where((n) => n.isNotEmpty)
          .toList()
        ..sort();
    } catch (e) {
      debugPrint('Ollama fetchAvailableModels error: $e');
      return const [];
    }
  }

  void updateSelectedModel(String model) => _selectedModel = model;
  void updateBaseUrl(String url) => baseUrl = url;
}
