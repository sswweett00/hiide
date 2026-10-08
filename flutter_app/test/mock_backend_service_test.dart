import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/mock_backend_service.dart';

void main() {
  test('mock backend supports agent filesystem operations', () async {
    final backend = MockBackendService();
    addTearDown(backend.dispose);
    final root = Directory.systemTemp.createTempSync('hiide_mock_backend');
    addTearDown(() => root.deleteSync(recursive: true));

    final write = await backend.executeAgentTool(
      'file.write',
      {'path': 'src/main.zig', 'content': 'pub fn main() void {}'},
      workspaceRoot: root.path,
    );
    expect(write.ok, isTrue);
    expect(File(root.path + '/src/main.zig').existsSync(), isTrue);

    final read = await backend.executeAgentTool(
      'file.read',
      {'path': 'src/main.zig'},
      workspaceRoot: root.path,
    );
    expect(read.output, contains('pub fn main'));

    final edit = await backend.executeAgentTool(
      'file.apply_diff',
      {'path': 'src/main.zig', 'target': 'main', 'replacement': 'entry'},
      workspaceRoot: root.path,
    );
    expect(edit.ok, isTrue);
    expect(File(root.path + '/src/main.zig').readAsStringSync(), contains('entry'));

    final traversal = await backend.executeAgentTool(
      'file.read',
      {'path': '../outside.txt'},
      workspaceRoot: root.path,
    );
    expect(traversal.ok, isFalse);
    expect(traversal.error, contains('path escapes workspace'));
  });

  test('mock workspace search uses the watched workspace root', () async {
    final backend = MockBackendService();
    addTearDown(backend.dispose);
    final root = Directory.systemTemp.createTempSync('hiide_search');
    addTearDown(() => root.deleteSync(recursive: true));
    File(root.path + '/target.txt').writeAsStringSync('UniqueNeedle\n');
    await backend.watchWorkspace(root.path);
    final hits = await backend.workspaceSearch('UniqueNeedle');
    expect(hits, hasLength(1));
    expect(hits.single.path, 'target.txt');
  });
}