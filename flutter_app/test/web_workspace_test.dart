import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiide_flutter/core/backend/web_workspace.dart';

WebFileEntry _entry(String path, String content) {
  final name = path.split('/').last;
  return WebFileEntry(
    path: path,
    name: name,
    read: () async => content,
  );
}

void main() {
  group('WebWorkspace', () {
    test('rootPath is a stable virtual path under /web/', () {
      final ws = WebWorkspace(name: 'my-project', files: const []);
      expect(ws.rootPath, '/web/my-project');
    });

    test('relOf maps virtual absolute paths back to relative ones', () {
      final ws = WebWorkspace(name: 'app', files: const []);
      expect(ws.relOf('/web/app/lib/main.dart'), 'lib/main.dart');
      expect(ws.relOf('/web/app/README.md'), 'README.md');
      expect(ws.relOf('/web/app'), isNull); // the root itself is not a file
      expect(ws.relOf('/web/other/lib/x.dart'), isNull); // foreign root
    });

    test('readText prefers the overlay over the picked content', () async {
      final ws = WebWorkspace(
        name: 'app',
        files: [
          _entry('lib/main.dart', 'original'),
        ],
      );
      expect(await ws.readText('lib/main.dart'), 'original');

      ws.writeText('lib/main.dart', 'saved');
      expect(await ws.readText('lib/main.dart'), 'saved');
    });

    test('readText throws for unknown files', () {
      final ws = WebWorkspace(name: 'app', files: const []);
      expect(() => ws.readText('nope.txt'), throwsException);
    });

    test('findWelcomeFile resolves the root README from picked files',
        () async {
      final ws = WebWorkspace(
        name: 'app',
        files: [
          _entry('README.md', '# Hello'),
          _entry('lib/main.dart', 'void main() {}'),
        ],
      );
      final found = await ws.findWelcomeFile();
      expect(found, isNotNull);
      expect(found!.path, '/web/app/README.md');
      expect(found.content, '# Hello');
    });

    test('findWelcomeFile prefers README.md over README.txt', () async {
      final ws = WebWorkspace(
        name: 'app',
        files: [
          _entry('README.txt', 'txt'),
          _entry('README.md', 'md'),
        ],
      );
      final found = await ws.findWelcomeFile();
      expect(found!.content, 'md');
    });

    test('findWelcomeFile is null when the folder has no README', () async {
      final ws = WebWorkspace(
        name: 'app',
        files: [
          _entry('lib/main.dart', 'void main() {}'),
        ],
      );
      expect(await ws.findWelcomeFile(), isNull);
    });

    test('adoptWebWorkspace registers the pick as the active workspace', () {
      webWorkspaceStore.workspace = null;
      final ws = adoptWebWorkspace(
        WebWorkspace(name: 'app', files: [_entry('lib/main.dart', 'x')]),
      );
      expect(webWorkspaceStore.workspace, same(ws));
      // A later pick replaces the previous workspace.
      final ws2 =
          adoptWebWorkspace(WebWorkspace(name: 'other', files: const []));
      expect(webWorkspaceStore.workspace, same(ws2));
    });
  });

  group('buildWebFileTree', () {
    test('nests files by relative path with a virtual root prefix', () {
      final ws = WebWorkspace(
        name: 'app',
        files: [
          _entry('pubspec.yaml', 'name: app'),
          _entry('lib/main.dart', 'void main() {}'),
          _entry('lib/core/foo.dart', 'foo'),
          _entry('README.md', '# App'),
        ],
      );
      final tree = buildWebFileTree(ws);

      // Directories first, then files, case-insensitive: lib, pubspec, README
      expect(tree, hasLength(3));
      expect(tree[0].isFile, isFalse);
      expect(tree[0].name, 'lib');
      expect(tree[0].path, '/web/app/lib');
      expect(tree[1].isFile, isTrue);
      expect(tree[1].name, 'pubspec.yaml');
      expect(tree[2].isFile, isTrue);
      expect(tree[2].name, 'README.md');
      expect(tree[2].path, '/web/app/README.md');

      final lib = tree[0];
      expect(lib.children, hasLength(2));
      expect(lib.children[0].name, 'core');
      expect(lib.children[0].isFile, isFalse);
      expect(lib.children[1].name, 'main.dart');
      expect(lib.children[1].path, '/web/app/lib/main.dart');

      expect(lib.children[0].children.single.name, 'foo.dart');
      expect(
        lib.children[0].children.single.path,
        '/web/app/lib/core/foo.dart',
      );
    });

    test('empty workspace yields an empty tree', () {
      final ws = WebWorkspace(name: 'app', files: const []);
      expect(buildWebFileTree(ws), isEmpty);
    });

    test('file icons are assigned by extension', () {
      final ws = WebWorkspace(
        name: 'app',
        files: [
          _entry('main.dart', ''),
          _entry('main.zig', ''),
          _entry('notes.md', ''),
        ],
      );
      final tree = buildWebFileTree(ws);
      final byName = {for (final item in tree) item.name: item.icon};
      expect(byName['main.dart'], Icons.flutter_dash);
      expect(byName['main.zig'], Icons.bolt);
      expect(byName['notes.md'], Icons.description);
    });
  });
}
