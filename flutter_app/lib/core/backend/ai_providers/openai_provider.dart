import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'ai_provider.dart';

/// OpenAI API provider (also compatible with OpenAI-style proxies like
/// Together AI, Fireworks, etc.).
class OpenAiProvider implements AiProvider {
  final String apiKey;
  @override
  final String baseUrl;
  String _selectedModel;
  final http.Client _client;

  OpenAiProvider({
    required this.apiKey,
    this.baseUrl = 'https://api.openai.com/v1',
    String selectedModel = 'gpt-4o',
    http.Client? client,
  })  : _selectedModel = selectedModel,
        _client = client ?? http.Client();

  @override
  void dispose() => _client.close();

  @override
  String get displayName => 'OpenAI';

  @override
  String get defaultModel => _selectedModel;

  @override
  String get id => 'openai';

  @override
  bool get requiresApiKey => true;

  @override
  bool get isConfigured => apiKey.trim().isNotEmpty;

  @override
  Future<bool> get isAvailable async {
    if (apiKey.isEmpty) return false;
    try {
      final response = await _client
          .get(
            Uri.parse('$baseUrl/models'),
            headers: {'Authorization': 'Bearer $apiKey'},
          )
          .timeout(const Duration(seconds: 5));
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
    if (apiKey.isEmpty) {
      return {'error': 'OpenAI API key is not set.'};
    }

    final body = <String, dynamic>{
      'model': model ?? _selectedModel,
      'messages': messages,
      'temperature': temperature,
    };

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools;
      body['tool_choice'] = 'auto';
    }

    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/chat/completions'),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 60));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return {
        'error': _extractError(response.body) ??
            'HTTP ${response.statusCode}',
      };
    } catch (e) {
      return {'error': 'OpenAI network error: $e'};
    }
  }

  @override
  Stream<String> chatCompletionStream({
    required List<Map<String, dynamic>> messages,
    String? model,
  }) async* {
    if (apiKey.isEmpty) {
      throw StateError('OpenAI API key is missing.');
    }

    final request = http.Request(
      'POST',
      Uri.parse('$baseUrl/chat/completions'),
    )
      ..headers['Authorization'] = 'Bearer $apiKey'
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'model': model ?? _selectedModel,
        'messages': messages,
        'stream': true,
      });

    final response = await _client.send(request).timeout(
      const Duration(seconds: 30),
    );
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString().timeout(
        const Duration(seconds: 10),
      );
      throw StateError(
        _extractError(body) ??
            'OpenAI HTTP ' + response.statusCode.toString(),
      );
    }

    final stream = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(const Duration(seconds: 120));

    try {
      await for (final line in stream) {
        if (!line.startsWith('data: ')) continue;
        final data = line.substring(6).trim();
        if (data == '[DONE]') break;
        try {
          final json = jsonDecode(data);
          final content = json['choices']?[0]?['delta']?['content'];
          if (content is String && content.isNotEmpty) {
            yield content;
          }
        } catch (_) {}
      }
    } on TimeoutException {
      throw StateError('OpenAI streaming timed out.');
    }
  }
  @override
  Future<String?> completeCode(String prompt, {String? model}) async {
    if (apiKey.isEmpty) return null;
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
    final first = choices.first;
    if (first is! Map) return null;
    final message = first['message'];
    final content = message is Map ? message['content']?.toString().trim() : null;
    return (content != null && content.isNotEmpty) ? content : null;
  }

  @override
  Future<List<String>> fetchAvailableModels() async {
    if (apiKey.isEmpty) return const [];
    try {
      final response = await _client.get(
        Uri.parse('$baseUrl/models'),
        headers: {'Authorization': 'Bearer $apiKey'},
      );
      if (response.statusCode != 200) return const [];
      final decoded = jsonDecode(response.body);
      final data = decoded['data'];
      if (data is! List) return const [];
      return data
          .whereType<Map<String, dynamic>>()
          .map((m) => m['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toList()
        ..sort();
    } catch (e) {
      debugPrint('OpenAI fetchAvailableModels error: $e');
      return const [];
    }
  }

  void updateSelectedModel(String model) => _selectedModel = model;

  String? _extractError(String body) {
    try {
      final decoded = jsonDecode(body);
      final error = decoded['error'];
      if (error is Map<String, dynamic>) return error['message']?.toString();
      if (error is String) return error;
    } catch (_) {}
    return null;
  }
}
