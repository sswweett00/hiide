import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:hiide_flutter/core/backend/agent_transaction.dart';
import 'package:hiide_flutter/core/backend/mock_backend_service.dart';

void main() {
  late Directory workspace;
  late MockBackendService backend;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('hiide_agent_tx_');
    backend = MockBackendService();
  });

  tearDown(() {
    workspace.deleteSync(recursive: true);
  });

  Future<void> write(String path, String content) async {
    final result = await backend.executeAgentTool(
      'file.write',
      {'path': path, 'content': content},
      workspaceRoot: workspace.path,
    );
    expect(result.ok, isTrue, reason: result.error);
  }

  test('rolls back a created file after an unsuccessful run', () async {
    final tx = AgentTransaction(
      backend: backend,
      workspaceRoot: workspace.path,
    );

    await tx.captureBeforeMutation('new.txt');
    await write('new.txt', 'agent content');
    await tx.recordWrite('new.txt', 'agent content');

    final report = await tx.rollback();

    expect(report.complete, isTrue, reason: report.errors.join('\n'));
    expect(File(workspace.path + '/new.txt').existsSync(), isFalse);
  });

  test('restores an overwritten file', () async {
    await write('main.zig', 'const value = 1;');

    final tx = AgentTransaction(
      backend: backend,
      workspaceRoot: workspace.path,
    );

    await tx.captureBeforeMutation('main.zig');
    await write('main.zig', 'const value = 2;');
    await tx.recordWrite('main.zig', 'const value = 2;');

    final report = await tx.rollback();

    expect(report.complete, isTrue, reason: report.errors.join('\n'));
    expect(
      File(workspace.path + '/main.zig').readAsStringSync(),
      'const value = 1;',
    );
  });

  test('never overwrites an external edit made after the agent mutation',
      () async {
    await write('main.zig', 'original');

    final tx = AgentTransaction(
      backend: backend,
      workspaceRoot: workspace.path,
    );

    await tx.captureBeforeMutation('main.zig');
    await write('main.zig', 'agent');
    await tx.recordWrite('main.zig', 'agent');

    File(workspace.path + '/main.zig').writeAsStringSync('external edit');

    final report = await tx.rollback();

    expect(report.complete, isFalse);
    expect(report.skipped, greaterThan(0));
    expect(
      File(workspace.path + '/main.zig').readAsStringSync(),
      'external edit',
    );
  });

  test('restores a deleted directory tree', () async {
    await write('src/main.zig', 'main');
    await write('src/lib.zig', 'lib');

    final tx = AgentTransaction(
      backend: backend,
      workspaceRoot: workspace.path,
    );

    await tx.captureBeforeMutation('src');
    final deleted = await backend.executeAgentTool(
      'file.delete',
      {'path': 'src'},
      workspaceRoot: workspace.path,
    );
    expect(deleted.ok, isTrue, reason: deleted.error);
    await tx.recordDelete('src');

    final report = await tx.rollback();

    expect(report.complete, isTrue, reason: report.errors.join('\n'));
    expect(File(workspace.path + '/src/main.zig').readAsStringSync(), 'main');
    expect(File(workspace.path + '/src/lib.zig').readAsStringSync(), 'lib');
  });
}
