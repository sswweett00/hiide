// Verifies the engine-backed file tree path and its Dart fallback.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiide_flutter/core/backend/workspace_service.dart';

import 'support/mock_backend_service.dart';

void main() {
  late Directory tempDir;
  late MockBackendService backend;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hiide_tree_test');
    backend = MockBackendService();
    await backend.connect();
  });

  tearDown(() async {
    backend.dispose();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('loadTree rebuilds the hierarchy from engine entries', () async {
    File('${tempDir.path}/root.txt').writeAsStringSync('x');
    Directory('${tempDir.path}/src').createSync();
    File('${tempDir.path}/src/main.zig').writeAsStringSync('pub fn main() void {}');
    File('${tempDir.path}/src/util.dart').writeAsStringSync('void util() {}');
    Directory('${tempDir.path}/.git').createSync();
    File('${tempDir.path}/.git/secret').writeAsStringSync('hidden');

    final service = WorkspaceService(rootPath: tempDir.path);
    final tree = await service.loadTree(engine: backend);

    expect(tree, hasLength(2));
    final src = tree.firstWhere((item) => item.name == 'src');
    expect(src.isFile, isFalse);
    expect(src.children, hasLength(2));
    expect(src.children.map((c) => c.name), containsAll(['main.zig', 'util.dart']));
    expect(src.children.firstWhere((c) => c.name == 'main.zig').path, '${tempDir.path}/src/main.zig');
  });

  test('loadTree uses the Dart walk when no engine is available', () async {
    File('${tempDir.path}/fallback.txt').writeAsStringSync('x');
    final service = WorkspaceService(rootPath: tempDir.path);
    final tree = await service.loadTree();
    expect(tree.map((item) => item.name), contains('fallback.txt'));
  });
}