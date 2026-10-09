import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiide_flutter/core/mechanics/agent_context.dart';

void main() {
  test('keeps assistant tool calls paired with their tool results', () {
    const compact = AgentContextCompactor(
      maxMessages: 6,
      maxCharacters: 120000,
    );

    final messages = [
      {'role': 'system', 'content': 'system'},
      {'role': 'user', 'content': 'first'},
      {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'c1',
            'type': 'function',
            'function': {'name': 'read_file', 'arguments': '{"path":"a"}'},
          }
        ],
      },
      {'role': 'tool', 'tool_call_id': 'c1', 'content': 'old result'},
      {'role': 'user', 'content': 'second'},
      {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'c2',
            'type': 'function',
            'function': {'name': 'read_file', 'arguments': '{"path":"b"}'},
          }
        ],
      },
      {'role': 'tool', 'tool_call_id': 'c2', 'content': 'new result'},
    ];

    final result = compact.compact(messages);
    expect(result.first['role'], 'system');
    expect(result.any((m) => m['tool_call_id'] == 'c2'), isTrue);

    final assistantIndex = result.indexWhere(
      (m) => m['role'] == 'assistant' && m['tool_calls'] != null,
    );
    final toolIndex = result.indexWhere((m) => m['tool_call_id'] == 'c2');
    expect(assistantIndex, greaterThanOrEqualTo(0));
    expect(toolIndex, greaterThan(assistantIndex));
  });

  test('trims oversized message content to the context budget without mutating history',
      () {
    const compact = AgentContextCompactor(
      maxMessages: 8,
      maxCharacters: 4096,
    );
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': 'system prompt'},
      {'role': 'user', 'content': 'current task: ' + ('important ' * 5000)},
    ];

    final result = compact.compact(messages);
    expect(utf8.encode(jsonEncode(result)).length, lessThanOrEqualTo(4096));
    expect(result.last['content'], contains('current task:'));
    expect((messages.last['content'] as String).length, greaterThan(4096));
  });

  test('drops stale complete segments before current work', () {
    const compact = AgentContextCompactor(
      maxMessages: 5,
      maxCharacters: 120000,
    );

    final messages = [
      {'role': 'system', 'content': 'system'},
      {'role': 'user', 'content': 'old-1'},
      {'role': 'assistant', 'content': 'answer-1'},
      {'role': 'user', 'content': 'old-2'},
      {'role': 'assistant', 'content': 'answer-2'},
      {'role': 'user', 'content': 'current'},
      {'role': 'assistant', 'content': 'current-answer'},
    ];

    final result = compact.compact(messages);
    final contents = result.map((m) => m['content']).toList();
    expect(contents, contains('current'));
    expect(contents, isNot(contains('old-1')));
  });
}
