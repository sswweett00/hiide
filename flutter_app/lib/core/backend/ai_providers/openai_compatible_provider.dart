import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'ai_provider.dart';

/// Generic OpenAI-compatible provider.
///
/// This is the common transport for hosted APIs and local gateways that expose
/// /chat/completions and optionally /models. Keeping the wire format here means
/// the agent runtime does not need provider-specific branches.
class OpenAiCompatibleProvider implements AiProvider {
  OpenAiCompatibleProvider({
    required this.id,
    required this.displayName,
    required this.baseUrl,
    required this.apiKey,
    required this.defaultModel,
    this.requiresApiKey = true,
    this.extraHeaders = const <String, String>{},
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  final String id;

  @override
  final String displayName;

  @override
  final String apiKey;

  @override
  final bool requiresApiKey;

  @override
  final String defaultModel;

  final Map<String, String> extraHeaders;
  final http.Client _client;

  String get _base => _normalizeBaseUrl(baseUrl);

  static String _normalizeBaseUrl(String value) {
    var url = value.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  Uri _uri(String suffix) => Uri.parse('$_base$suffix');

  Map<String, String> _headers({bool json = false}) => {
        if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        if (json) 'Content-Type': 'application/json',
        ...extraHeaders,
      };

  @override
  Future<bool> get isAvailable async {
    if (requiresApiKey && apiKey.trim().isEmpty) return false;
    try {
      final response = await _client
          .get(_uri('/models'), headers: _headers())
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
    if (requiresApiKey && apiKey.trim().isEmpty) {
      return {'error': '$displayName API key is not set.'};
    }

    final body = <String, dynamic>{
      'model': (model == null || model.trim().isEmpty)
          ? defaultModel
          : model.trim(),
      'messages': messages,
      'temperature': temperature,
      'stream': false,
    };

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools;
      body['tool_choice'] = 'auto';
    }

    try {
      final response = await _client
          .post(
            _uri('/chat/completions'),
            headers: _headers(json: true),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 120));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) return decoded;
        return {'error': '$displayName returned a non-object response.'};
      }

      return {
        'error': _extractError(response.body) ??
            '$displayName HTTP ' + response.statusCode.toString(),
      };
    } on TimeoutException {
      return {'error': '$displayName request timed out.'};
    } catch (e) {
      return {'error': '$displayName network error: $e'};
    }
  }

  @override
  Stream<String> chatCompletionStream({
    required List<Map<String, dynamic>> messages,
    String? model,
  }) async* {
    if (requiresApiKey && apiKey.trim().isEmpty) {
      yield '$displayName API key missing.';
      return;
    }

    final request = http.Request('POST', _uri('/chat/completions'))
      ..headers.addAll(_headers(json: true))
      ..body = jsonEncode({
        'model': (model == null || model.trim().isEmpty)
            ? defaultModel
            : model.trim(),
        'messages': messages,
        'stream': true,
      });

    final client = http.Client();
    try {
      final response = await client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        yield _extractError(await response.stream.bytesToString()) ??
            '$displayName HTTP ' + response.statusCode.toString();
        return;
      }

      final stream = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in stream) {
        var payload = line.trim();
        if (payload.isEmpty || payload.startsWith(':')) continue;
        if (payload.startsWith('data:')) {
          payload = payload.substring(5).trim();
        }
        if (payload == '[DONE]') break;

        try {
          final decoded = jsonDecode(payload);
          final content = decoded['choices']?[0]?['delta']?['content'];
          if (content != null) yield content.toString();
        } catch (_) {
          // Ignore keep-alives/provider-specific SSE metadata.
        }
      }
    } catch (e) {
      yield '$displayName stream error: $e';
    } finally {
      client.close();
    }
  }

  @override
  Future<String?> completeCode(String prompt, {String? model}) async {
    final response = await chatCompletion(
      messages: [
        {
          'role': 'system',
          'content':
              'You are an expert code completion engine. Return only the completion text. No explanations or markdown fences.',
        },
        {'role': 'user', 'content': prompt},
      ],
      model: model,
      temperature: 0.2,
    );

    final choices = response['choices'];
    if (response.containsKey('error') || choices is! List || choices.isEmpty) {
      return null;
    }
    final message = choices.first;
    if (message is! Map) return null;
    final content = (message['message'] as Map?)?['content']?.toString().trim();
    return content == null || content.isEmpty ? null : content;
  }

  @override
  Future<List<String>> fetchAvailableModels() async {
    if (requiresApiKey && apiKey.trim().isEmpty) return const [];
    try {
      final response = await _client
          .get(_uri('/models'), headers: _headers())
          .timeout(const Duration(seconds: 8));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const [];
      }

      final decoded = jsonDecode(response.body);
      final data = decoded is Map ? decoded['data'] : null;
      if (data is! List) return const [];
      return data
          .whereType<Map>()
          .map((m) => m['id']?.toString().trim() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
    } catch (e) {
      debugPrint('$displayName model discovery failed: $e');
      return const [];
    }
  }

  String? _extractError(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map) {
          final message = error['message']?.toString();
          if (message != null && message.isNotEmpty) return message;
        }
        if (error is String && error.isNotEmpty) return error;
        final message = decoded['message']?.toString();
        if (message != null && message.isNotEmpty) return message;
      }
    } catch (_) {
      final trimmed = body.trim();
      if (trimmed.isNotEmpty && trimmed.length < 1000) return trimmed;
    }
    return null;
  }
}
