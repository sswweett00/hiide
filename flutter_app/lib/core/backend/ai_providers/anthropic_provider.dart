import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import 'ai_provider.dart';

/// Anthropic Claude provider. Uses the Messages API (not the legacy
/// Completions API). Tool calling is supported on Claude 3.5+ models.
class AnthropicProvider implements AiProvider {
  final String apiKey;
  @override
  final String baseUrl;
  String _selectedModel;
  final http.Client _client;

  AnthropicProvider({
    required this.apiKey,
    this.baseUrl = 'https://api.anthropic.com/v1',
    String selectedModel = 'claude-sonnet-4-20250514',
    http.Client? client,
  })  : _selectedModel = selectedModel,
        _client = client ?? http.Client();

  @override
  String get displayName => 'Anthropic (Claude)';

  @override
  String get baseUrl => _baseUrl;

  @override
  String get defaultModel => _selectedModel;

  @override
  String get id => 'anthropic';

  @override
  bool get requiresApiKey => true;

  @override
  bool get isConfigured => apiKey.trim().isNotEmpty;

  @override
  Future<bool> get isAvailable async {
    if (apiKey.isEmpty) return false;
    try {
      // Anthropic doesn't have a /models endpoint; just check auth
      final response = await _client
          .post(
            Uri.parse(''$baseUrl'/messages'),
            headers: {
              'x-api-key': apiKey,
              'anthropic-version': '2023-06-01',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'model': _selectedModel,
              'max_tokens': 1,
              'messages': [
                {'role': 'user', 'content': 'hi'},
              ],
            }),
          )
          .timeout(const Duration(seconds: 10));
      // Any 2xx or 400 (bad request but auth worked) means the key is valid
      return response.statusCode < 500;
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
      return {'error': 'Anthropic API key is not set.'};
    }

    // Extract system message (Anthropic uses a top-level system param)
    String? systemPrompt;
    final userMessages = <Map<String, dynamic>>[];
    final pendingToolResults = <Map<String, dynamic>>[];

    void flushToolResults() {
      if (pendingToolResults.isEmpty) return;
      userMessages.add({
        'role': 'user',
        'content': List<Map<String, dynamic>>.from(pendingToolResults),
      });
      pendingToolResults.clear();
    }

    for (final msg in messages) {
      final role = msg['role']?.toString();
      if (role == 'system') {
        systemPrompt = msg['content']?.toString();
        continue;
      }

      if (role == 'tool') {
        final toolId = msg['tool_call_id']?.toString() ?? '';
        pendingToolResults.add({
          'type': 'tool_result',
          'tool_use_id': toolId,
          'content': msg['content']?.toString() ?? '',
        });
        continue;
      }

      flushToolResults();

      if (role == 'assistant' && msg['tool_calls'] is List) {
        final content = <Map<String, dynamic>>[];
        final text = msg['content']?.toString() ?? '';
        if (text.isNotEmpty) {
          content.add({'type': 'text', 'text': text});
        }
        for (final raw in (msg['tool_calls'] as List)) {
          if (raw is! Map) continue;
          final fn = raw['function'];
          if (fn is! Map) continue;
          Map<String, dynamic> input = const <String, dynamic>{};
          final args = fn['arguments']?.toString() ?? '{}';
          try {
            final decoded = jsonDecode(args);
            if (decoded is Map<String, dynamic>) input = decoded;
          } catch (_) {}
          content.add({
            'type': 'tool_use',
            'id': raw['id']?.toString() ?? '',
            'name': fn['name']?.toString() ?? '',
            'input': input,
          });
        }
        userMessages.add({'role': 'assistant', 'content': content});
      } else {
        userMessages.add({
          'role': role == 'assistant' ? 'assistant' : 'user',
          'content': msg['content']?.toString() ?? '',
        });
      }
    }
    flushToolResults();

    final body = <String, dynamic>{
      'model': model ?? _selectedModel,
      'max_tokens': 4096,
      'messages': userMessages,
    };

    if (systemPrompt != null) {
      body['system'] = systemPrompt;
    }

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools.map((t) {
        final fn = t['function'] as Map<String, dynamic>;
        return {
          'name': fn['name'],
          'description': fn['description'],
          'input_schema': fn['parameters'],
        };
      }).toList();
    }

    try {
      final response = await _client
          .post(
            Uri.parse(''$baseUrl'/messages'),
            headers: {
              'x-api-key': apiKey,
              'anthropic-version': '2023-06-01',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 60));

      if (response.statusCode == 200) {
        // Convert Anthropic response to OpenAI-compatible format
        return _toOpenAiFormat(jsonDecode(response.body));
      }
      return {
        'error': _extractError(response.body) ??
            'HTTP ${response.statusCode}',
      };
    } catch (e) {
      return {'error': 'Anthropic network error: $e'};
    }
  }

  @override
  Stream<String> chatCompletionStream({
    required List<Map<String, dynamic>> messages,
    String? model,
  }) async* {
    if (apiKey.isEmpty) {
      yield 'Error: Anthropic API key missing.';
      return;
    }

    String? systemPrompt;
    final userMessages = <Map<String, dynamic>>[];
    for (final msg in messages) {
      if (msg['role'] == 'system') {
        systemPrompt = msg['content']?.toString();
      } else {
        userMessages.add(msg);
      }
    }

    final body = <String, dynamic>{
      'model': model ?? _selectedModel,
      'max_tokens': 4096,
      'messages': userMessages,
      'stream': true,
    };
    if (systemPrompt != null) body['system'] = systemPrompt;

    final request = http.Request('POST', Uri.parse(''$baseUrl'/messages'))
      ..headers['x-api-key'] = apiKey
      ..headers['anthropic-version'] = '2023-06-01'
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode(body);

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
            if (json['type'] == 'content_block_delta') {
              final text = json['delta']?['text'];
              if (text != null) yield text.toString();
            }
          } catch (_) {}
        }
      }
    } finally {
      client.close();
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
              'You are an expert code completion engine. Complete the code that follows the caret. Reply with ONLY the completion text — no explanations, no markdown fences.',
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
    // Anthropic doesn't expose a models list endpoint; return known models
    return const [
      'claude-sonnet-4-20250514',
      'claude-3-5-haiku-20241022',
      'claude-3-opus-20240229',
    ];
  }

  void updateSelectedModel(String model) => _selectedModel = model;

  /// Convert Anthropic's Messages API response to OpenAI-compatible format
  /// so the agent loop doesn't need provider-specific handling.
  Map<String, dynamic> _toOpenAiFormat(Map<String, dynamic> anthropic) {
    final content = anthropic['content'] as List? ?? [];
    final textBlocks = content
        .where((b) => b['type'] == 'text')
        .map((b) => b['text']?.toString() ?? '')
        .join();
    final toolUseBlocks = content.where((b) => b['type'] == 'tool_use');

    final toolCalls = toolUseBlocks.map((b) {
      return {
        'id': b['id']?.toString() ?? '',
        'type': 'function',
        'function': {
          'name': b['name']?.toString() ?? '',
          'arguments': jsonEncode(b['input'] ?? {}),
        },
      };
    }).toList();

    return {
      'choices': [
        {
          'message': {
            'role': 'assistant',
            'content': textBlocks,
            if (toolCalls.isNotEmpty) 'tool_calls': toolCalls,
          },
        }
      ],
    };
  }

  String? _extractError(String body) {
    try {
      final decoded = jsonDecode(body);
      final error = decoded['error'];
      if (error is Map<String, dynamic>) return error['message']?.toString();
    } catch (_) {}
    return null;
  }
}
