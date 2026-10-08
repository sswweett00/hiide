import 'package:flutter_test/flutter_test.dart';
import 'package:hiide_flutter/core/backend/agent_profile.dart';

void main() {
  test('build agent can mutate and delegate', () {
    expect(AgentProfile.build.allowedTools, contains('write_file'));
    expect(AgentProfile.build.allowedTools, contains('apply_diff'));
    expect(AgentProfile.build.allowedTools, contains('delegate_agent'));
    expect(AgentProfile.build.allowedTools, contains('run_command'));
  });

  test('read-only specialists cannot mutate', () {
    for (final profile in [
      AgentProfile.explore,
      AgentProfile.reviewer,
      AgentProfile.security,
      AgentProfile.researcher,
    ]) {
      expect(profile.allowedTools, isNot(contains('write_file')));
      expect(profile.allowedTools, isNot(contains('apply_diff')));
      expect(profile.allowedTools, isNot(contains('delete_file')));
      expect(profile.parallelSafe, isTrue);
    }
  });

  test('tester may verify but cannot edit', () {
    expect(AgentProfile.tester.allowedTools, contains('run_command'));
    expect(AgentProfile.tester.allowedTools, isNot(contains('write_file')));
    expect(AgentProfile.tester.allowedTools, isNot(contains('apply_diff')));
  });
}