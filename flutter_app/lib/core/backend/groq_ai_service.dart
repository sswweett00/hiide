import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'ai_chat_client.dart';

/// Thrown when a Groq API call fails (non-200 or network). Carries a
/// human-readable message for UI surfacing.
class GroqApiException implements Exception {
  GroqApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GroqAiService implements AiChatClient {
  final String apiKey;
  final String defaultModel;
  final http.Client _client;

  GroqAiService({
    required this.apiKey,
    // Current Groq agent-friendly default. The provider manager may override
    // this with a persisted or discovered model at runtime.
    this.defaultModel = 'openai/gpt-oss-120b',
    http.Client? client,
  }) : _client = client ?? http.Client();

  static Future<GroqAiService> fromFile(String keyFilePath) async {
    try {
      final file = File(keyFilePath);
      if (await file.exists()) {
        final key = (await file.readAsString()).trim();
        return GroqAiService(apiKey: key);
      }
    } catch (e) {
      debugPrint('Could not read Groq API key from file: $e');
    }
    return GroqAiService(apiKey: '');
  }

  /// Cheap connectivity + key-validity probe: GET /models (no tokens are
  /// consumed). Never throws; returns `(ok, message)` for the status bar and
  /// the chat header to render.
  Future<({bool ok, String message})> checkConnection() async {
    if (apiKey.isEmpty) {
      return (
        ok: false,
        message:
            'API key is not set — add it in Settings or the groq-api-key file.',
      );
    }
    try {
      final response = await _client.get(
        Uri.parse('https://api.groq.com/openai/v1/models'),
        headers: {'Authorization': 'Bearer $apiKey'},
      );
      if (response.statusCode == 200) {
        return (ok: true, message: 'Connected to Groq');
      }
      return (
        ok: false,
        message: _extractError(response.body) ?? 'HTTP ${response.statusCode}'
      );
    } catch (e) {
      return (ok: false, message: 'Network error: $e');
    }
  }

  /// Fetches the model ids currently served by the Groq API (GET /models —
  /// no tokens are consumed). Throws [GroqApiException] on failure so
  /// callers can fall back to a curated list.
  Future<List<String>> fetchModelIds() async {
    if (apiKey.isEmpty) {
      throw GroqApiException(
          'API key is not set — add it in Settings or the groq-api-key file.');
    }
    try {
      final response = await _client.get(
        Uri.parse('https://api.groq.com/openai/v1/models'),
        headers: {'Authorization': 'Bearer $apiKey'},
      );
      if (response.statusCode != 200) {
        throw GroqApiException(
            _extractError(response.body) ?? 'HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(response.body);
      final data = (decoded is Map<String, dynamic>) ? decoded['data'] : null;
      if (data is! List) return const [];
      return data
          .whereType<Map<String, dynamic>>()
          .map((m) => m['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toList();
    } on GroqApiException {
      rethrow;
    } catch (e) {
      throw GroqApiException('Network error: $e');
    }
  }

  /// Pulls the human-readable message out of an OpenAI-style error body.
  String? _extractError(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is Map<String, dynamic>) {
          return error['message']?.toString();
        }
        if (error is String) return error;
      }
    } catch (_) {}
    return null;
  }

  /// Sends a chat completion request with optional tool definitions.
  ///
  /// Responses that include tool calls are returned verbatim; callers inspect
  /// `choices[0].message.tool_calls` to drive the agent loop.
  @override
  Future<Map<String, dynamic>> chatCompletion({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    String? model,
    double temperature = 0.2,
  }) async {
    if (apiKey.isEmpty) {
      return {
        'error':
            'Groq API Key is not set. Please set the API key in settings or groq-api-key file.'
      };
    }

    final url = Uri.parse('https://api.groq.com/openai/v1/chat/completions');
    final body = <String, dynamic>{
      'model': model ?? defaultModel,
      'messages': messages,
      'temperature': temperature,
    };

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools;
      body['tool_choice'] = 'auto';
    }

    try {
      final response = await _client.post(
        url,
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      } else {
        return {
          'error': _extractError(response.body) ??
              'API Error: ${response.statusCode} - ${response.body}'
        };
      }
    } catch (e) {
      return {'error': 'Network connection failed: $e'};
    }
  }

  /// Requests a short single-line code completion for [prompt] (built by
  /// [buildCompletionPrompt]). Returns the raw assistant text, or null when
  /// the API key is missing or the call failed — the editor then simply
  /// offers nothing instead of showing an error.
  Future<String?> completeCode(String prompt, {String? model}) async {
    if (apiKey.isEmpty) return null;
    final response = await chatCompletion(
      messages: [
        {
          'role': 'system',
          'content': 'You are an expert code completion engine. Complete the '
              'code that follows the caret. Reply with ONLY the completion '
              'text — no explanations, no markdown fences, no repetition of '
              'the prompt. Keep it on a single line unless a newline is '
              'required.',
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
    if (message is! Map<String, dynamic>) return null;
    final content = message['content'];
    if (content is! String) return null;
    final trimmed = content.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Stream response tokens for fast real-time typing effect
  @override
  Stream<String> chatCompletionStream({
    required List<Map<String, dynamic>> messages,
    String? model,
  }) async* {
    if (apiKey.isEmpty) {
      yield 'Error: API key missing.';
      return;
    }

    final url = Uri.parse('https://api.groq.com/openai/v1/chat/completions');
    final request = http.Request('POST', url)
      ..headers['Authorization'] = 'Bearer $apiKey'
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'model': model ?? defaultModel,
        'messages': messages,
        'stream': true,
      });

    final client = http.Client();
    try {
      final response = await client.send(request);
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
            if (content != null) {
              yield content.toString();
            }
          } catch (_) {}
        }
      }
    } finally {
      client.close();
    }
  }

  /// Releases the HTTP transport owned by this service.
  void dispose() => _client.close();
}

/// Builds the prompt for an inline code completion from the current editor
/// context: the file's language, the code before the caret on the current
/// line, and the indentation so the model knows the nesting level. Pure
/// function so the editor can build it without touching the network.
String buildCompletionPrompt({
  required String language,
  required String linePrefix,
  required String indentation,
}) {
  final buffer = StringBuffer();
  if (language.isNotEmpty && language != '—') {
    buffer.writeln('Language: $language');
  }
  if (indentation.isNotEmpty) {
    buffer.writeln('Indentation: ${indentation.length} spaces');
  }
  buffer.writeln('Complete the code after the caret (`|`):');
  buffer.write(linePrefix);
  buffer.write('|');
  return buffer.toString();
}
