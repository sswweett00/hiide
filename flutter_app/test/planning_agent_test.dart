import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiide_flutter/core/backend/ai_agents/planning_agent.dart';
import 'package:hiide_flutter/core/backend/ai_chat_client.dart';
import 'package:hiide_flutter/core/backend/mock_backend_service.dart';


class _FakePlanAi implements AiChatClient {
  _FakePlanAi(this.responses);

  final List<Map<String, dynamic>> responses;
  int calls = 0;

  @override
  Future<Map<String, dynamic>> chatCompletion({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    String? model,
    double temperature = 0.2,
  }) async {
    final index = calls < responses.length ? calls : responses.length - 1;
    calls++;
    return responses[index];
  }

  @override
  Stream<String> chatCompletionStream({
    required List<Map<String, dynamic>> messages,
    String? model,
  }) async* {}
}

Map<String, dynamic> _planResponse() => {
      'choices': [
        {
          'message': {
            'role': 'assistant',
            'content': jsonEncode({
              'title': 'Stable plan',
              'summary': 'A recoverable plan.',
              'goal': 'Complete the requested work.',
              'assumptions': [],
              'scope': ['flutter_app/lib'],
              'constraints': ['Preserve compatibility.'],
              'risks': ['Regression.'],
              'acceptance_criteria': ['Tests pass.'],
              'validation': ['flutter test'],
              'rollback': ['Revert the changes.'],
              'steps': [
                {
                  'id': 'S1',
                  'title': 'Inspect',
                  'description': 'Inspect the relevant implementation.',
                  'rationale': 'Establish facts.',
                  'agent': 'researcher',
                  'files': ['flutter_app/lib'],
                  'depends_on': [],
                  'verification': ['Review findings.'],
                  'risk': 'Missed dependency.'
                }
              ]
            }),
          }
        }
      ]
    };

void main() {

  test('recovers from transient planning provider errors', () async {
    final ai = _FakePlanAi([
      {'error': 'HTTP 503 temporarily unavailable'},
      _planResponse(),
    ]);
    final backend = MockBackendService();

    final planner = PlanningAgent(
      ai: ai,
      backend: backend,
      workspaceRoot: '/tmp',
    );

    final events = await planner.run('create a safe plan').toList();
    backend.dispose();

    expect(events.whereType<PlanErrorEvent>(), isEmpty);
    expect(events.any((event) => event is PlanCreatedEvent), isTrue);
    expect(events.last, isA<PlanDoneEvent>());
    expect(ai.calls, 2);
  });

  test('feeds malformed planning tool arguments back as structured errors', () async {
    final ai = _FakePlanAi([
      {
        'choices': [
          {
            'message': {
              'role': 'assistant',
              'content': '',
              'tool_calls': [
                {
                  'id': 'plan_tool_1',
                  'type': 'function',
                  'function': {
                    'name': 'read_file',
                    'arguments': '{broken-json',
                  }
                }
              ]
            }
          }
        ]
      },
      _planResponse(),
    ]);
    final backend = MockBackendService();

    final planner = PlanningAgent(
      ai: ai,
      backend: backend,
      workspaceRoot: '/tmp',
    );

    final events = await planner.run('create a plan').toList();
    backend.dispose();

    expect(events.whereType<PlanErrorEvent>(), isEmpty);
    expect(events.any((event) => event is PlanCreatedEvent), isTrue);
    expect(events.last, isA<PlanDoneEvent>());
    expect(ai.calls, 2);
  });

  test('accepts a detailed dependency-safe plan', () {
    final plan = PlanningAgent.parseDocument(jsonEncode({
      'title': 'Feature delivery',
      'summary': 'Deliver the feature safely.',
      'goal': 'Requested behavior works without regressions.',
      'assumptions': ['Existing public APIs remain compatible.'],
      'scope': ['src/core', 'flutter_app/lib'],
      'constraints': ['Do not modify unrelated files.'],
      'risks': ['Shared API regression.'],
      'acceptance_criteria': ['Feature works end to end.'],
      'validation': ['zig build test', 'flutter test'],
      'rollback': ['Revert the implementation commit.'],
      'steps': [
        {'id': 'S1', 'title': 'Inspect', 'description': 'Inspect the current implementation.',
         'rationale': 'Establish facts.', 'agent': 'researcher', 'files': ['src/core'],
         'depends_on': [], 'verification': ['Review findings.'], 'risk': 'Missed dependency.'},
        {'id': 'S2', 'title': 'Implement', 'description': 'Apply the requested change.',
         'rationale': 'Deliver behavior.', 'agent': 'coder', 'files': ['flutter_app/lib'],
         'depends_on': ['S1'], 'verification': ['Run tests.'], 'risk': 'Regression.'}
      ],
    }));

    expect(plan.steps.length, 2);
    expect(plan.steps[1].dependsOn, ['S1']);
    expect(plan.toMarkdown(), contains('## Acceptance criteria'));
    expect(plan.toMarkdown(), contains('## Rollback'));
  });

  test('rejects dependency cycles', () {
    expect(
      () => PlanningAgent.parseDocument(jsonEncode({
        'summary': 'cycle',
        'acceptance_criteria': ['x'],
        'validation': ['y'],
        'steps': [
          {'id': 'A', 'title': 'A', 'description': 'A', 'depends_on': ['B']},
          {'id': 'B', 'title': 'B', 'description': 'B', 'depends_on': ['A']},
        ],
      })),
      throwsFormatException,
    );
  });

  test('rejects unknown dependencies', () {
    expect(
      () => PlanningAgent.parseDocument(jsonEncode({
        'summary': 'unknown',
        'acceptance_criteria': ['x'],
        'validation': ['y'],
        'steps': [
          {'id': 'A', 'title': 'A', 'description': 'A', 'depends_on': ['missing']},
        ],
      })),
      throwsFormatException,
    );
  });
}