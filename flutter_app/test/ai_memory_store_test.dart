import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hiide_flutter/core/backend/ai_memory/memory_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('serializes concurrent conversation writes without losing entries',
      () async {
    final store = AiMemoryStore();

    await Future.wait([
      store.storeConversationSummary(
        workspaceRoot: '/workspace/demo',
        summary: 'first summary',
        topics: const ['auth'],
      ),
      store.storeConversationSummary(
        workspaceRoot: '/workspace/demo',
        summary: 'second summary',
        topics: const ['provider'],
      ),
    ]);

    final values = await store.searchConversations('/workspace/demo', const []);
    final summaries =
        values.map((entry) => entry['summary']).whereType<String>().toSet();
    expect(summaries, containsAll(<String>{'first summary', 'second summary'}));
  });

  test('buildContext stays bounded for oversized memory records', () async {
    final store = AiMemoryStore();

    await store.storeProjectContext(
      workspaceRoot: '/workspace/demo',
      key: 'large',
      value: 'x' * 100000,
    );

    await store.storeConversationSummary(
      workspaceRoot: '/workspace/demo',
      summary: 'important auth decision',
      topics: const ['auth'],
    );

    final context = await store.buildContext(
      workspaceRoot: '/workspace/demo',
      keywords: const ['auth'],
      maxChars: 1200,
    );

    expect(context.length, lessThanOrEqualTo(1200 + 20));
    expect(context, contains('auth'));
  });
}
