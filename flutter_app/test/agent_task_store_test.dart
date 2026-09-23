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
