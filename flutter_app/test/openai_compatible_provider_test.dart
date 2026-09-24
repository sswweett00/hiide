import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiide_flutter/core/backend/ai_providers/openai_compatible_provider.dart';
import 'package:http/http.dart' as http;

class _FakeClient extends http.BaseClient {
  _FakeClient(this.handler);

  final Future<http.Response> Function(http.BaseRequest request) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await handler(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(response.body)),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}

void main() {
  test('sends OpenAI-compatible tool calls with auth and model', () async {
    late String path;
    late Map<String, String> headers;
    late Map<String, dynamic> body;

    final client = _FakeClient((request) async {
      path = request.url.path;
      headers = request.headers;
      final rawRequest = request as http.Request;
      body = jsonDecode(rawRequest.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {
                'role': 'assistant',
                'content': 'ok',
              }
            }
          ]
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    });

    final provider = OpenAiCompatibleProvider(
      id: 'custom',
      displayName: 'Custom',
      baseUrl: 'https://example.test/v1/',
      apiKey: 'secret',
      defaultModel: 'model-a',
      client: client,
    );

    final result = await provider.chatCompletion(
      messages: const [
        {'role': 'user', 'content': 'hello'}
      ],
      tools: const [
        {
          'type': 'function',
          'function': {
            'name': 'read_file',
            'description': 'Read a file',
            'parameters': {
              'type': 'object',
              'properties': {'path': {'type': 'string'}},
              'required': ['path'],
            },
          },
        }
      ],
    );

    expect(path, '/v1/chat/completions');
    expect(headers['authorization'], 'Bearer secret');
    expect(body['model'], 'model-a');
    expect(body['tool_choice'], 'auto');
    expect((body['tools'] as List).length, 1);
    expect(result['choices'], isA<List>());
  });

  test('supports non-Bearer authentication headers', () async {
    late Map<String, String> headers;
    final client = _FakeClient((request) async {
      headers = request.headers;
      return http.Response(
        jsonEncode({
          'choices': [
            {'message': {'role': 'assistant', 'content': 'ok'}},
          ],
        }),
        200,
      );
    });

    final provider = OpenAiCompatibleProvider(
      id: 'custom',
      displayName: 'Custom',
      baseUrl: 'https://example.test/v1',
      apiKey: 'secret',
      defaultModel: 'model-a',
      apiKeyHeader: 'x-api-key',
      apiKeyPrefix: '',
      client: client,
    );

    await provider.chatCompletion(
      messages: const [
        {'role': 'user', 'content': 'hello'}
      ],
    );

    expect(headers['x-api-key'], 'secret');
    expect(headers.containsKey('authorization'), isFalse);
  });

  test('supports keyless OpenAI-compatible endpoints', () async {
    var called = false;
    final client = _FakeClient((request) async {
      called = true;
      expect(request.headers.containsKey('authorization'), isFalse);
      return http.Response(
        jsonEncode({
          'choices': [
            {'message': {'role': 'assistant', 'content': 'local'}},
          ],
        }),
        200,
      );
    });

    final provider = OpenAiCompatibleProvider(
      id: 'local',
      displayName: 'Local',
      baseUrl: 'http://127.0.0.1:8000/v1',
      apiKey: '',
      defaultModel: 'local-model',
      requiresApiKey: false,
      client: client,
    );

    final result = await provider.chatCompletion(
      messages: const [
        {'role': 'user', 'content': 'hello'}
      ],
    );

    expect(called, isTrue);
    expect(result['choices'], isA<List>());
  });

  test('discovers models from standard /models response', () async {
    final client = _FakeClient((request) async {
      expect(request.url.path, '/v1/models');
      return http.Response(
        jsonEncode({
          'data': [
            {'id': 'b'},
            {'id': 'a'},
            {'id': 'a'},
          ],
        }),
        200,
      );
    });

    final provider = OpenAiCompatibleProvider(
      id: 'custom',
      displayName: 'Custom',
      baseUrl: 'https://example.test/v1',
      apiKey: 'secret',
      defaultModel: 'model-a',
      client: client,
    );

    expect(await provider.fetchAvailableModels(), ['a', 'b']);
  });

  test('rejects missing api key before network access', () async {
    var called = false;
    final client = _FakeClient((request) async {
      called = true;
      return http.Response('{}', 200);
    });

    final provider = OpenAiCompatibleProvider(
      id: 'custom',
      displayName: 'Custom',
      baseUrl: 'https://example.test/v1',
      apiKey: '',
      defaultModel: 'model-a',
      client: client,
    );

    final response = await provider.chatCompletion(
      messages: const [
        {'role': 'user', 'content': 'hello'}
      ],
    );

    expect(called, isFalse);
    expect(response['error'], contains('API key is not set'));
  });
}
