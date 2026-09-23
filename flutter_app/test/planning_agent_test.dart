import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiide_flutter/core/backend/ai_agents/planning_agent.dart';

void main() {
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