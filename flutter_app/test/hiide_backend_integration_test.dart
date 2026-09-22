// End-to-end test of the Flutter ⇄ Zig bridge.
//
// Spawns the real `hiide-ipc-server` binary (built via `zig build`) and drives
// it through HiideBackendService: handshake, editor load/get/insert/delete/
// search, and workspace grep. The test is skipped automatically when the
// binary is not present (e.g. CI without a Zig toolchain).
//
// Run from the repo root:
//   zig build && cd flutter_app && flutter test test/hiide_backend_integration_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiide_flutter/core/backend/backend_service.dart';
import 'package:hiide_flutter/core/backend/hiide_backend_service.dart';
import 'package:hiide_flutter/core/backend/text_diff.dart';

Future<Process?> _startServer() async {
  const candidates = [
    '../zig-out/bin/hiide-ipc-server', // repo layout (test cwd = flutter_app/)
    'zig-out/bin/hiide-ipc-server', // repo layout (test cwd = repo root)
    'zig-out/bin/hiide-ipc-server.exe',
  ];
  String? binary;
  for (final candidate in candidates) {
    final file = File(candidate);
    if (await file.exists()) {
      binary = candidate;
      break;
    }
  }
  if (binary == null) return null;

  final process =
      await Process.start(binary, [], mode: ProcessStartMode.normal);
  // Drain the server's output so a full pipe never stalls it, and surface
  // crashes (Zig panics print to stderr).
  process.stdout.transform(utf8.decoder).listen((_) {});
  process.stderr.transform(utf8.decoder).listen((line) {
    // ignore: avoid_print
    print('[engine] $line');
  });
  return process;
}

Future<bool> _portOpen(int port) async {
  try {
    final socket = await Socket.connect('127.0.0.1', port,
        timeout: const Duration(seconds: 1));
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  const port = 4879;
  Process? server;
  var integrationAvailable = false;

  setUpAll(() async {
    // Reuse an already-running engine (e.g. dev session) if present.
    if (await _portOpen(port)) {
      integrationAvailable = true;
      return;
    }
    server = await _startServer();
    if (server != null) {
      // Wait for the listener to come up.
      for (var i = 0; i < 50; i++) {
        if (await _portOpen(port)) {
          integrationAvailable = true;
          return;
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  setUp(() {
    if (!integrationAvailable) {
      markTestSkipped('Zig IPC server binary is not available in this Flutter-only test job.');
    }
  });

  tearDownAll(() async {
    server?.kill();
    await server?.exitCode;
  });

  test('zig engine: hello + ping handshake', () async {
    final backend = HiideBackendService(port: port);
    await backend.connect();
    expect(backend.isConnected, isTrue);
    expect(await backend.ping(), 'pong');
    await backend.disconnect();
  });

  test('zig engine: editor load/get/insert/delete/search round trip', () async {
    final backend = HiideBackendService(port: port);
    await backend.connect();

    const original = 'merhaba dünya\nikinci satır';
    final handle = await backend.editorLoad(original);
    expect(await backend.editorGetText(handle), original);
    expect(await backend.editorLineCount(handle), 2);
    // The engine reports the size in UTF-8 BYTES (Dart String.length is
    // UTF-16 code units — they differ for the Turkish characters).
    expect(await backend.editorSize(handle), utf8.encode(original).length);

    await backend.editorInsert(handle, 7, ' ZIG');
    expect(
        await backend.editorGetText(handle), 'merhaba ZIG dünya\nikinci satır');

    await backend.editorDelete(handle, 7, 4);
    expect(await backend.editorGetText(handle), original);

    // Edits after non-ASCII content must be converted from code units to
    // bytes before hitting the engine buffer.
    const before = 'satır sonu';
    const after = 'satır sonu X';
    final edit = toByteEdit(before, computeTextEdit(before, after));
    final h2 = await backend.editorLoad(before);
    await backend.editorInsert(h2, edit.start, edit.inserted);
    expect(await backend.editorGetText(h2), after);
    await backend.editorDestroy(h2);

    final results = await backend.editorSearch(handle, 'dünya');
    expect(results, hasLength(1));
    expect(results.first.line, 1);
    expect(results.first.col, 9); // 1-based byte column of 'dünya'

    await backend.editorDestroy(handle);
    await backend.disconnect();
  });

  test('zig engine: workspace search is recursive and case-insensitive',
      () async {
    final backend = HiideBackendService(port: port);
    await backend.connect();

    // The workspace root here is the flutter_app test dir itself; search for a
    // string that definitely exists in this very file.
    final hits = await backend.workspaceSearch(
      '.',
      'hiide_backend_integration_test',
      maxResults: 10,
    );
    expect(hits, isNotEmpty);
    expect(
      hits.any((h) => h.path.endsWith('hiide_backend_integration_test.dart')),
      isTrue,
      reason:
          'expected a hit in this test file, got: ${hits.map((h) => h.path)}',
    );

    await backend.disconnect();
  });
  test('zig engine: editor.apply_text syncs a minimal native edit', () async {
    final backend = HiideBackendService(port: port);
    await backend.connect();

    const original = 'merhaba dünya\nikinci satır';
    final handle = await backend.editorLoad(original);
    await backend.editorApplyText(handle, 'merhaba güzel dünya\nikinci satır');
    expect(await backend.editorGetText(handle),
        'merhaba güzel dünya\nikinci satır');

    await backend.editorApplyText(handle, 'merhaba dünya');
    expect(await backend.editorGetText(handle), 'merhaba dünya');

    // Empty buffer → full write.
    final h2 = await backend.editorLoad('');
    await backend.editorApplyText(h2, 'fresh');
    expect(await backend.editorGetText(h2), 'fresh');
    await backend.editorDestroy(h2);

    await backend.editorDestroy(handle);
    await backend.disconnect();
  });
  test('zig engine: editor.diff_lines returns gutter regions', () async {
    final backend = HiideBackendService(port: port);
    await backend.connect();

    final handle = await backend.editorLoad('alpha\nbeta\ngamma\n');

    // Identical disk text → no changes.
    expect(
        await backend.editorDiffLines(handle, 'alpha\nbeta\ngamma\n'), isEmpty);

    // Disk has an extra trailing line → deleted at the boundary (line 3).
    final del =
        await backend.editorDiffLines(handle, 'alpha\nbeta\ngamma\ndelta\n');
    expect(del, hasLength(1));
    expect(del.single.line, 3);
    expect(del.single.kind, 'deleted');
    expect(del.single.count, 1);

    // Disk differs in the middle → modified at line 1.
    final mod = await backend.editorDiffLines(handle, 'alpha\nBETA\ngamma\n');
    expect(mod, hasLength(1));
    expect(mod.single.line, 1);
    expect(mod.single.kind, 'modified');
    expect(mod.single.count, 1);

    // Editing the engine buffer updates the diff.
    await backend.editorApplyText(handle, 'alpha\nbeta\n');
    final afterEdit =
        await backend.editorDiffLines(handle, 'alpha\nbeta\ngamma\n');
    expect(afterEdit, hasLength(1));
    expect(afterEdit.single.line, 2);
    expect(afterEdit.single.kind, 'deleted');

    await backend.editorDestroy(handle);
    await backend.disconnect();
  });

  test('zig engine: workspace.tree enumerates sorted relative entries',
      () async {
    final backend = HiideBackendService(port: port);
    await backend.connect();

    final scratch = Directory.systemTemp.createTempSync('hiide_tree_ipc');
    addTearDown(() => scratch.deleteSync(recursive: true));
    File('${scratch.path}/zeta.txt').writeAsStringSync('12345');
    Directory('${scratch.path}/src').createSync();
    File('${scratch.path}/src/a.zig').writeAsStringSync('abcde');

    final entries = await backend.workspaceTree(scratch.path);
    expect(entries, hasLength(3));
    expect(entries[0].name, 'src');
    expect(entries[0].isDirectory, isTrue);
    expect(entries[1].path, 'src/a.zig');
    expect(entries[1].isDirectory, isFalse);
    expect(entries[1].size, 5);
    expect(entries[2].path, 'zeta.txt');
    expect(entries[2].size, 5);

    await backend.disconnect();
  });

  test('zig engine: agent.tool.execute runs framework tools end to end',
      () async {
    final backend = HiideBackendService(port: port);
    await backend.connect();

    // process.run executes a real command and returns its output.
    final run = await backend.executeAgentTool(
      'process.run',
      {'command': 'echo engine-agent-tool-ok'},
      workspaceRoot: '.',
    );
    expect(run.ok, isTrue, reason: run.error);
    expect(run.output, contains('engine-agent-tool-ok'));

    // workspace.search returns JSON hits with workspace-relative paths.
    final search = await backend.executeAgentTool(
      'workspace.search',
      {'query': 'hiide_backend_integration_test'},
      workspaceRoot: '.',
    );
    expect(search.ok, isTrue, reason: search.error);
    expect(search.output, contains('hiide_backend_integration_test.dart'));

    // file.write / file.apply_diff / file.read round trip in a scratch root.
    final scratch = Directory.systemTemp.createTempSync('hiide_agent_ipc');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final root = scratch.path;

    final write = await backend.executeAgentTool(
      'file.write',
      {'path': 'out.txt', 'content': 'ipc-tool-content'},
      workspaceRoot: root,
    );
    expect(write.ok, isTrue, reason: write.error);
    expect(write.output, contains('"size":16'));

    final diff = await backend.executeAgentTool(
      'file.apply_diff',
      {'path': 'out.txt', 'target': 'ipc-tool', 'replacement': 'engine-edited'},
      workspaceRoot: root,
    );
    expect(diff.ok, isTrue, reason: diff.error);

    final read = await backend.executeAgentTool(
      'file.read',
      {'path': 'out.txt'},
      workspaceRoot: root,
    );
    expect(read.ok, isTrue, reason: read.error);
    expect(read.output, contains('engine-edited-content'));

    // A tool-level failure is reported in the result, not as a transport error.
    final missing = await backend.executeAgentTool(
      'file.read',
      {'path': 'nope.txt'},
      workspaceRoot: root,
    );
    expect(missing.ok, isFalse);
    expect(missing.error, contains('file not found'));

    // An unknown tool id is a transport-level error.
    expect(
      backend.executeAgentTool('nope.tool', {}, workspaceRoot: root),
      throwsA(isA<StateError>()),
    );

    await backend.disconnect();
  });

  test('zig engine: watch.subscribe pushes fs.change events', () async {
    final backend = HiideBackendService(port: port);
    await backend.connect();

    final scratch = Directory.systemTemp.createTempSync('hiide_watch_ipc');
    addTearDown(() => scratch.deleteSync(recursive: true));

    await backend.watchWorkspace(scratch.path);
    final changes = <FsChange>[];
    final sub = backend.fsChangeStream.listen(changes.add);

    Future<void> waitFor(bool Function() done) async {
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (!done() && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    // Create a file after subscribing — the engine diff detects it (inotify
    // trigger, with a periodic rescan safety net).
    File('${scratch.path}/new.txt').writeAsStringSync('hello');
    await waitFor(() => changes.any((c) => c.path == 'new.txt'));
    final created = changes.firstWhere((c) => c.path == 'new.txt');
    expect(created.kind, 'created');
    expect(created.isDirectory, isFalse);

    // A content change is reported as `modified`.
    final before = changes.length;
    File('${scratch.path}/new.txt').writeAsStringSync('hello world');
    await waitFor(() =>
        changes.length > before &&
        changes.skip(before).any((c) => c.path == 'new.txt'));
    final modified =
        changes.skip(before).firstWhere((c) => c.path == 'new.txt');
    expect(modified.kind, 'modified');

    // Deleting the file is reported too.
    final beforeDel = changes.length;
    File('${scratch.path}/new.txt').deleteSync();
    await waitFor(() => changes.length > beforeDel);
    final deleted = changes.skip(beforeDel).firstWhere(
          (c) => c.path == 'new.txt',
          orElse: () => const FsChange(
              path: 'new.txt', isDirectory: false, kind: 'missing'),
        );
    expect(deleted.kind, 'deleted');

    await sub.cancel();
    await backend.unwatchWorkspace();
    await backend.disconnect();
  });
}
