import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hiide_flutter/core/backend/agent_task_store.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  test('persists task lifecycle, artifacts, timeline and transcript', () async {
    final store = await AgentTaskStore.load();
    final task = store.create(
      objective: 'Implement the authentication flow',
      workspace: '/workspace/demo',
      mode: 'code',
    );

    expect(store.byId(task.id)?.status, AgentTaskStatus.queued);

    store.update(task.id, status: AgentTaskStatus.executing);
    store.addEvent(
      task.id,
      kind: 'execution',
      title: 'Agent started',
      detail: 'Inspecting workspace',
    );
    store.addArtifact(
      task.id,
      AgentArtifact(
        id: 'artifact-1',
        type: AgentArtifactType.report,
        title: 'Execution report',
        content: 'Changed auth.dart',
        createdAt: DateTime.now(),
      ),
    );
    store.replaceTranscript(task.id, const [
      {'role': 'user', 'content': 'Implement auth'},
      {'role': 'assistant', 'content': 'I will inspect the workspace.'},
    ]);
    store.update(
      task.id,
      status: AgentTaskStatus.succeeded,
      summary: 'Authentication flow implemented',
      changedFiles: const ['lib/auth.dart'],
      verificationCommands: const ['flutter test'],
      toolCalls: 3,
    );
    await store.flush();

    final restored = await AgentTaskStore.load();
    final saved = restored.byId(task.id);

    expect(saved, isNotNull);
    expect(saved!.status, AgentTaskStatus.succeeded);
    expect(saved.summary, 'Authentication flow implemented');
    expect(saved.changedFiles, contains('lib/auth.dart'));
    expect(saved.verificationCommands, contains('flutter test'));
    expect(saved.toolCalls, 3);
    expect(saved.artifacts.single.content, 'Changed auth.dart');
    expect(saved.timeline.single.title, 'Agent started');
    expect(saved.transcript.length, 2);
  });

  test('bounds deeply nested tool-call transcript payloads', () async {
    final store = await AgentTaskStore.load();
    final task = store.create(
      objective: 'Persist a large tool call safely',
      workspace: '/workspace/demo',
      mode: 'code',
    );

    final huge = 'x' * 20000;
    store.replaceTranscript(task.id, [
      {
        'role': 'assistant',
        'tool_calls': [
          {
            'id': 'call-1',
            'type': 'function',
            'function': {
              'name': 'write_file',
              'arguments': huge,
            },
          },
        ],
      },
    ]);
    await store.flush();

    final restored = await AgentTaskStore.load();
    final saved = restored.byId(task.id)!;
    final args = ((saved.transcript.single['tool_calls'] as List).single
        as Map)['function'] as Map;
    expect((args['arguments'] as String).length, lessThanOrEqualTo(4025));
  });

  test('redacts secrets from persisted task content', () async {
    final store = await AgentTaskStore.load();
    final task = store.create(
      objective: 'Use api_key=super-task-secret to configure the provider',
      workspace: '/workspace/demo',
      mode: 'code',
    );

    store.addEvent(
      task.id,
      kind: 'tool.start',
      title: 'run_command',
      detail: 'curl -H "Authorization: Bearer super-command-secret"',
    );
    store.addArtifact(
      task.id,
      const AgentArtifact(
        id: 'secret-artifact',
        type: AgentArtifactType.note,
        title: 'password=artifact-title-secret',
        content: 'password=artifact-content-secret',
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    store.replaceTranscript(task.id, const [
      {
        'role': 'user',
        'content': 'secret=transcript-secret',
      },
    ]);
    store.update(
      task.id,
      error: 'api_key=error-secret',
      summary: 'secret=summary-secret',
    );
    await store.flush();

    final restored = await AgentTaskStore.load();
    final saved = restored.byId(task.id)!;

    expect(saved.objective, contains('[REDACTED]'));
    expect(saved.timeline.single.detail, contains('[REDACTED]'));
    expect(saved.artifacts.single.title, contains('[REDACTED]'));
    expect(saved.artifacts.single.content, contains('[REDACTED]'));
    expect(saved.transcript.single['content'], contains('[REDACTED]'));
    expect(saved.error, contains('[REDACTED]'));
    expect(saved.summary, contains('[REDACTED]'));

    final persisted = (await SharedPreferences.getInstance())
        .getString('hiide.agent_tasks.v1');
    expect(persisted, isNot(contains('super-task-secret')));
    expect(persisted, isNot(contains('super-command-secret')));
    expect(persisted, isNot(contains('transcript-secret')));
    expect(persisted, isNot(contains('error-secret')));
  });

  test('marks interrupted non-terminal tasks canceled after restart', () async {
    final store = await AgentTaskStore.load();
    final task = store.create(
      objective: 'Long running task',
      workspace: '/workspace/demo',
      mode: 'code',
    );
    store.update(task.id, status: AgentTaskStatus.executing);
    await store.flush();

    final restored = await AgentTaskStore.load();
    final recovered = restored.byId(task.id);

    expect(recovered, isNotNull);
    expect(recovered!.status, AgentTaskStatus.canceled);
    expect(recovered.error, contains('Application restarted'));
    expect(recovered.summary, 'Interrupted by application restart.');
  });

  test('treats succeeded-with-warnings as terminal and explicit', () {
    expect(AgentTaskStatus.succeededWithWarnings.terminal, isTrue);
    expect(
      AgentTaskStatus.succeededWithWarnings.label,
      'Succeeded with warnings',
    );
  });

  test('keeps terminal tasks intact during recovery', () async {
    final store = await AgentTaskStore.load();
    final task = store.create(
      objective: 'Completed task',
      workspace: '/workspace/demo',
      mode: 'plan',
    );
    store.update(
      task.id,
      status: AgentTaskStatus.succeeded,
      summary: 'Plan complete',
    );
    await store.flush();

    final restored = await AgentTaskStore.load();
    expect(restored.byId(task.id)!.status, AgentTaskStatus.succeeded);
    expect(restored.byId(task.id)!.summary, 'Plan complete');
  });
}
