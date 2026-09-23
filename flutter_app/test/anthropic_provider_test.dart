import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiide_flutter/core/backend/ai_providers/anthropic_provider.dart';
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
  test('maps canonical agent tool history to Anthropic content blocks',
      () async {
    late Map<String, dynamic> body;

    final client = _FakeClient((request) async {
      body = jsonDecode((request as http.Request).body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'content': [
            {
              'type': 'text',
              'text': 'done',
            },
          ],
        }),
        200,
      );
    });

    final provider = AnthropicProvider(
      apiKey: 'secret',
      client: client,
    );

    await provider.chatCompletion(
      messages: const [
        {'role': 'system', 'content': 'Be concise.'},
        {'role': 'user', 'content': 'Read app.dart.'},
        {
          'role': 'assistant',
          'content': 'I will inspect it.',
          'tool_calls': [
            {
              'id': 'tool-1',
              'type': 'function',
              'function': {
                'name': 'read_file',
                'arguments': '{"path":"app.dart"}',
              },
            },
          ],
        },
        {
          'role': 'tool',
          'tool_call_id': 'tool-1',
          'content': 'file contents',
        },
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
            },
          },
        }
      ],
    );

    expect(body['system'], 'Be concise.');
    final messages = body['messages'] as List;
    expect(messages.length, 3);

    final assistant = messages[1] as Map;
    final assistantContent = assistant['content'] as List;
    expect(assistantContent[0]['type'], 'text');
    expect(assistantContent[1]['type'], 'tool_use');
    expect(assistantContent[1]['id'], 'tool-1');
    expect(assistantContent[1]['name'], 'read_file');
    expect(assistantContent[1]['input'], {'path': 'app.dart'});

    final toolResult = messages[2] as Map;
    expect(toolResult['role'], 'user');
    final blocks = toolResult['content'] as List;
    expect(blocks.single['type'], 'tool_result');
    expect(blocks.single['tool_use_id'], 'tool-1');
    expect(blocks.single['content'], 'file contents');
  });

  test('converts Anthropic tool_use response to canonical tool_calls',
      () async {
    final client = _FakeClient((request) async {
      return http.Response(
        jsonEncode({
          'content': [
            {
              'type': 'text',
              'text': 'Inspecting.',
            },
            {
              'type': 'tool_use',
              'id': 'tool-2',
              'name': 'list_directory',
              'input': {'path': '.'},
            },
          ],
        }),
        200,
      );
    });

    final provider = AnthropicProvider(
      apiKey: 'secret',
      client: client,
    );

    final response = await provider.chatCompletion(
      messages: const [
        {'role': 'user', 'content': 'List the directory.'}
      ],
    );

    final message =
        (response['choices'] as List).first['message'] as Map<String, dynamic>;
    final calls = message['tool_calls'] as List;
    expect(calls.single['id'], 'tool-2');
    expect(calls.single['function']['name'], 'list_directory');
    expect(jsonDecode(calls.single['function']['arguments'] as String),
        {'path': '.'});
  });
}
