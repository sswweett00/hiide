import 'package:flutter_test/flutter_test.dart';
import 'package:hiide_flutter/core/backend/agent_mode.dart';

void main() {
  test('agent modes expose stable labels and behavior', () {
    expect(AgentMode.plan.label, 'Plan');
    expect(AgentMode.code.label, 'Code');
    expect(AgentMode.plan.description, contains('dosya'));
    expect(AgentMode.code.description, contains('test'));
  });
}
