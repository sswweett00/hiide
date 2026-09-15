// Verifies the engine-backed file tree path: WorkspaceService.loadTree
// rebuilds the hierarchy from the backend's flat entry list, falls back to
// the Dart walk when the engine is unavailable, and EditorSession syncs via a
// single editor.applyText call.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiide_flutter/core/backend/editor_session.dart';
import 'package:hiide_flutter/core/backend/mock_backend_service.dart';
import 'package:hiide_flutter/core/backend/workspace_service.dart';

void main() {
  late Directory tempDir;
  late MockBackendService backend;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('hiide_tree_test');
    backend = MockBackendService();
    await backend.connect();
  });

  tearDown(() {
    backend.dispose();
    tempDir.deleteSync(recursive: true);
  });

  test('loadTree rebuilds the hierarchy from engine entries', () async {
    File('${tempDir.path}/root.txt').writeAsStringSync('x');
    Directory('${tempDir.path}/src').createSync();
    File('${tempDir.path}/src/main.zig')
        .writeAsStringSync('pub fn main() void {}');
    File('${tempDir.path}/src/util.dart').writeAsStringSync('void util() {}');
    Directory('${tempDir.path}/.git').createSync();
    File('${tempDir.path}/.git/secret').writeAsStringSync('hidden');

    final service = WorkspaceService(rootPath: tempDir.path);
    final tree = await service.loadTree(engine: backend);

    expect(tree, hasLength(2)); // root.txt + src (no .git)
    final src = tree.firstWhere((i) => i.name == 'src');
    expect(src.isFile, isFalse);
    expect(src.children, hasLength(2));
    expect(src.children.map((c) => c.name),
        containsAll(['main.zig', 'util.dart']));
    // Item paths are absolute so opening files keeps working.
    expect(
      src.children.firstWhere((c) => c.name == 'main.zig').path,
      '${tempDir.path}/src/main.zig',
    );
  });

  test('loadTree uses the Dart walk when no engine is available', () async {
    File('${tempDir.path}/fallback.txt').writeAsStringSync('x');

    final service = WorkspaceService(rootPath: tempDir.path);
    final tree = await service.loadTree(); // engine == null
    expect(tree.map((i) => i.name), contains('fallback.txt'));
  });

  test('EditorSession syncs via editor.applyText in one round trip', () async {
    final session = EditorSession(
      tabId: 't1',
      backend: backend,
      content: 'merhaba dünya',
    );
    await session.init();
    final handle = session.engineHandle;
    expect(handle, isNotNull);

    session.syncChange('merhaba güzel dünya');
    await session.syncToEngine();
    expect(await session.engineText(), 'merhaba güzel dünya');

    // Deletion through the same path.
    session.syncChange('merhaba');
    await session.syncToEngine();
    expect(await session.engineText(), 'merhaba');

    await session.dispose();
  });
}
