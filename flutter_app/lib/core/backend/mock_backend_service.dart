import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'backend_service.dart';
import 'line_diff.dart';

/// Offline fallback backend used when the Zig engine is not running.
/// Implements the same contract as [HiideBackendService] with an in-memory
/// buffer so the IDE remains fully usable without the engine.
class MockBackendService implements BackendService {
  bool _connected = false;
  final _controller = StreamController<String>.broadcast();
  final Map<int, String> _buffers = {};
  int _nextHandle = 1;

  @override
  Stream<String> get outputStream => _controller.stream;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async {
    await Future.delayed(const Duration(milliseconds: 500));
    _connected = true;
    _controller.add('Connected to Hiide backend (mock)');
  }

  @override
  Future<String> ping() async {
    await Future.delayed(const Duration(milliseconds: 50));
    return 'pong';
  }

  @override
  Future<int> editorLoad(String text) async {
    await Future.delayed(const Duration(milliseconds: 100));
    final handle = _nextHandle++;
    _buffers[handle] = text;
    return handle;
  }

  @override
  Future<String> editorGetText(int handle) async {
    await Future.delayed(const Duration(milliseconds: 50));
    return _buffers[handle] ?? '// Mock file content for handle $handle\n';
  }

  @override
  Future<int> editorInsert(int handle, int pos, String text) async {
    await Future.delayed(const Duration(milliseconds: 50));
    final content = _buffers[handle];
    if (content == null || pos > content.length) return 0;
    _buffers[handle] =
        content.substring(0, pos) + text + content.substring(pos);
    return _buffers[handle]!.length;
  }

  @override
  Future<int> editorDelete(int handle, int pos, int len) async {
    await Future.delayed(const Duration(milliseconds: 50));
    final content = _buffers[handle];
    if (content == null || pos + len > content.length) return 0;
    _buffers[handle] = content.substring(0, pos) + content.substring(pos + len);
    return _buffers[handle]!.length;
  }

  @override
  Future<void> editorUndo(int handle) async {
    await Future.delayed(const Duration(milliseconds: 50));
    // Mock: no-op.
  }

  @override
  Future<void> editorRedo(int handle) async {
    await Future.delayed(const Duration(milliseconds: 50));
    // Mock: no-op.
  }

  @override
  Future<int> editorLineCount(int handle) async {
    await Future.delayed(const Duration(milliseconds: 50));
    final content = _buffers[handle];
    if (content == null || content.isEmpty) return 0;
    return content.split('\n').length;
  }

  @override
  Future<int> editorSize(int handle) async {
    await Future.delayed(const Duration(milliseconds: 50));
    return _buffers[handle]?.length ?? 0;
  }

  @override
  Future<List<EditorSearchResult>> editorSearch(
      int handle, String query) async {
    await Future.delayed(const Duration(milliseconds: 50));
    final content = _buffers[handle] ?? '';
    final lowered = query.toLowerCase();
    final results = <EditorSearchResult>[];
    final lines = content.split('\n');
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final col = line.toLowerCase().indexOf(lowered);
      if (col != -1) {
        results.add(EditorSearchResult(line: i + 1, col: col + 1, text: query));
      }
    }
    return results;
  }

  @override
  Future<String> editorHighlight(int handle, String lang) async {
    await Future.delayed(const Duration(milliseconds: 50));
    final content = _buffers[handle] ?? '';
    return '<span class="tok-keyword">$content</span>';
  }

  @override
  Future<void> editorDestroy(int handle) async {
    await Future.delayed(const Duration(milliseconds: 50));
    _buffers.remove(handle);
  }

  @override
  Future<void> editorApplyText(int handle, String text) async {
    await Future.delayed(const Duration(milliseconds: 50));
    _buffers[handle] = text;
  }

  @override
  Future<List<EditorDiffRegion>> editorDiffLines(
      int handle, String diskText) async {
    await Future.delayed(const Duration(milliseconds: 50));
    return computeLineDiff(diskText, _buffers[handle] ?? '');
  }

  @override
  Future<List<WorkspaceFile>> workspaceTree(
    String root, {
    int maxEntries = 50000,
  }) async {
    await Future.delayed(const Duration(milliseconds: 50));
    final out = <WorkspaceFile>[];
    final rootDir = Directory(root);
    if (!await rootDir.exists()) return out;
    final absRoot = rootDir.absolute.path;

    Future<void> walk(Directory dir) async {
      if (out.length >= maxEntries) return;
      try {
        final entities = await dir.list(followLinks: false).toList();
        entities.sort((a, b) {
          final aDir = a is Directory;
          final bDir = b is Directory;
          if (aDir != bDir) return aDir ? -1 : 1;
          return a.path.compareTo(b.path);
        });
        for (final entity in entities) {
          if (out.length >= maxEntries) return;
          final name = entity.path.split(Platform.pathSeparator).last;
          if (name.startsWith('.git') ||
              name == '.zig-cache' ||
              name == 'build' ||
              name == 'node_modules') {
            continue;
          }
          final abs = entity.absolute.path;
          final rel = abs.startsWith('$absRoot/')
              ? abs.substring(absRoot.length + 1)
              : name;
          if (entity is Directory) {
            out.add(WorkspaceFile(name: name, path: rel, isDirectory: true));
            await walk(entity);
          } else if (entity is File) {
            var size = 0;
            try {
              size = await entity.length();
            } catch (_) {}
            out.add(WorkspaceFile(
                name: name, path: rel, isDirectory: false, size: size));
          }
        }
      } catch (_) {}
    }

    await walk(rootDir);
    return out;
  }

  @override
  Future<List<WorkspaceSearchResult>> workspaceSearch(
    String root,
    String query, {
    int maxResults = 200,
  }) async {
    await Future.delayed(const Duration(milliseconds: 50));
    // Mock: no real filesystem scan.
    return [];
  }

  @override
  Future<AgentToolResult> executeAgentTool(
    String toolId,
    Map<String, dynamic> input, {
    String? workspaceRoot,
    Duration? timeout,
  }) async {
    final root = workspaceRoot ?? Directory.current.path;
    final delay = timeout ?? const Duration(seconds: 60);
    try {
      switch (toolId) {
        case 'file.read':
          final path = _resolve(root, input['path']?.toString() ?? '');
          final file = File(path);
          if (!await file.exists()) {
            return AgentToolResult(
                ok: false, output: '', error: 'file not found: $path');
          }
          return AgentToolResult(ok: true, output: await file.readAsString());

        case 'file.write':
          final path = _resolve(root, input['path']?.toString() ?? '');
          final content = input['content']?.toString() ?? '';
          await File(path).parent.create(recursive: true);
          await File(path).writeAsString(content);
          return AgentToolResult(
              ok: true, output: '{"written":true,"size":${content.length}}');

        case 'file.delete':
          final path = _resolve(root, input['path']?.toString() ?? '');
          final file = File(path);
          final dir = Directory(path);
          if (await file.exists()) {
            await file.delete();
            return const AgentToolResult(ok: true, output: '{"deleted":true}');
          } else if (await dir.exists()) {
            await dir.delete(recursive: true);
            return const AgentToolResult(ok: true, output: '{"deleted":true}');
          }
          return AgentToolResult(
              ok: false, output: '', error: 'file or directory not found: $path');

        case 'file.mkdir':
          final path = _resolve(root, input['path']?.toString() ?? '');
          await Directory(path).create(recursive: true);
          return const AgentToolResult(ok: true, output: '{"created":true}');

        case 'file.apply_diff':
          final path = _resolve(root, input['path']?.toString() ?? '');
          final target = input['target']?.toString() ?? '';
          final replacement = input['replacement']?.toString() ?? '';
          final file = File(path);
          if (!await file.exists()) {
            return AgentToolResult(
                ok: false, output: '', error: 'file not found: $path');
          }
          final content = await file.readAsString();
          if (!content.contains(target)) {
            return AgentToolResult(
              ok: false,
              output: '',
              error:
                  'target text not found in $path; read the file first and retry with the exact text',
            );
          }
          await file.writeAsString(content.replaceFirst(target, replacement));
          return const AgentToolResult(ok: true, output: '{"applied":true}');

        case 'file.list':
          final path = _resolve(root, input['path']?.toString() ?? '.');
          final dir = Directory(path);
          if (!await dir.exists()) {
            return AgentToolResult(
                ok: false, output: '', error: 'directory not found: $path');
          }
          final entities = await dir.list(followLinks: false).toList();
          final entries = entities.map((e) {
            final name = e.path.split(Platform.pathSeparator).last;
            return {
              'name': name,
              'kind': e is Directory ? 'directory' : 'file',
            };
          }).toList();
          return AgentToolResult(ok: true, output: jsonEncode(entries));

        case 'process.run':
          final command = input['command']?.toString() ?? '';
          if (command.isEmpty) {
            return const AgentToolResult(
                ok: false, output: '', error: 'no command provided');
          }
          final result = await Process.run(
            'bash',
            ['-c', command],
            workingDirectory: root,
            runInShell: false,
          ).timeout(delay);
          final stdout = result.stdout.toString().trimRight();
          final stderr = result.stderr.toString().trimRight();
          final combined = [
            if (stdout.isNotEmpty) stdout,
            if (stderr.isNotEmpty) stderr,
          ].join('\n');
          final isSuccess = result.exitCode == 0;
          return AgentToolResult(
            ok: isSuccess,
            output: isSuccess
                ? (combined.isEmpty ? '(command completed with no output)' : combined)
                : stdout,
            error: isSuccess
                ? ''
                : (stderr.isNotEmpty
                    ? stderr
                    : 'process exited with code ${result.exitCode}'),
          );

        case 'workspace.search':
          // Engine-less fallback: empty result — the caller falls back to a
          // local scan, matching the engine-offline behavior.
          return const AgentToolResult(ok: true, output: '');

        default:
          return AgentToolResult(
              ok: false, output: '', error: 'unknown tool: $toolId');
      }
    } on TimeoutException {
      return AgentToolResult(
          ok: false,
          output: '',
          error: 'command timed out after ${delay.inSeconds}s');
    } catch (e) {
      return AgentToolResult(ok: false, output: '', error: '$e');
    }
  }

  String _resolve(String root, String raw) {
    var p = raw.trim();
    if (p.isEmpty) return root;
    final isAbsolute =
        p.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p);
    return isAbsolute ? p : '$root/$p';
  }

  /// Engine-less mode has no native watcher; a no-op stream keeps the
  /// contract (tree provider / tab reload listen and simply never fire).
  @override
  Stream<FsChange> get fsChangeStream => const Stream<FsChange>.empty();

  @override
  Future<void> watchWorkspace(String root) async {
    // No-op: nothing to watch without the engine.
  }

  @override
  Future<void> unwatchWorkspace() async {
    // No-op.
  }

  @override
  Future<void> disconnect() async {
    await Future.delayed(const Duration(milliseconds: 200));
    _connected = false;
    _buffers.clear();
    _controller.add('Backend disconnected');
  }

  @override
  void dispose() {
    _controller.close();
  }
}
