import 'package:flutter_test/flutter_test.dart';

import '../lib/core/mechanics/agent_guard.dart';

void main() {
  group('AgentRunGuard', () {
    test('canonicalizes map key order for duplicate detection', () {
      final guard = AgentRunGuard(
        budget: const AgentRunBudget(maxRepeatedToolCalls: 1),
      );

      expect(
        guard.reserveTool('read_file', {'path': 'lib/a.dart', 'line': 1}),
        isNull,
      );
      expect(
        guard.reserveTool('read_file', {'line': 1, 'path': 'lib/a.dart'}),
        contains('Repeated tool call blocked'),
      );
      expect(guard.toolCalls, 2);
    });

    test('blocks repeated identical calls after the configured threshold', () {
      final guard = AgentRunGuard(
        budget: const AgentRunBudget(maxRepeatedToolCalls: 2),
      );

      expect(guard.reserveTool('search_workspace', {'query': 'Provider'}), isNull);
      expect(guard.reserveTool('search_workspace', {'query': 'Provider'}), isNull);
      expect(
        guard.reserveTool('search_workspace', {'query': 'Provider'}),
        contains('Repeated tool call blocked'),
      );
    });

    test('enforces a monotonic hard tool-call budget', () {
      final guard = AgentRunGuard(
        budget: const AgentRunBudget(maxToolCalls: 2),
      );

      expect(guard.reserveTool('read_file', {'path': 'a'}), isNull);
      expect(guard.reserveTool('read_file', {'path': 'b'}), isNull);

      final error = guard.reserveTool('read_file', {'path': 'c'});
      expect(error, contains('tool-call budget exceeded'));
      expect(guard.toolCalls, 3);
      expect(guard.failureReason, contains('tool-call budget exceeded'));
    });

    test('keeps iterables deterministic in fingerprints', () {
      final guard = AgentRunGuard(
        budget: const AgentRunBudget(maxRepeatedToolCalls: 1),
      );

      expect(
        guard.reserveTool('read_file', {
          'parts': ['a', 'b'],
        }),
        isNull,
      );
      expect(
        guard.reserveTool('read_file', {
          'parts': ['a', 'b'],
        }),
        contains('Repeated tool call blocked'),
      );
    });

    test('checkRunBudget reports the hard tool limit before the next action', () {
      final guard = AgentRunGuard(
        budget: const AgentRunBudget(maxToolCalls: 1),
      );

      expect(guard.reserveTool('read_file', {'path': 'a'}), isNull);
      expect(
        guard.checkRunBudget(iterations: 1),
        contains('tool-call budget exceeded'),
      );
    });
  });
}
