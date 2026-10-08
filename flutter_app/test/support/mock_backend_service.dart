import 'dart:async';
import 'dart:io';

import 'package:hiide_flutter/core/backend/backend_service.dart';

/// In-memory backend test double. This file is test-only and must never be used by the production application.
class MockBackendService implements BackendService {
  bool _connected = false;
  final _controller = StreamController<String>.broadcast();
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
    final needle = query.toLowerCase();
    if (needle.isEmpty || maxResults <= 0) return const [];
    final results = <WorkspaceSearchResult>[];
    final rootDir = Directory(root);
    if (!await rootDir.exists()) return const [];

    const ignored = {
      '.git', '.hg', '.svn', 'node_modules', '.dart_tool',
      '.zig-cache', 'zig-out', 'build', 'dist', 'target',
      '.idea', '.vscode',
    };
    final absRoot = rootDir.absolute.path;

    Future<void> walk(Directory dir) async {
      if (results.length >= maxResults) return;
      List<FileSystemEntity> entities;
      try {
        entities = await dir.list(followLinks: false).toList();
      } catch (_) {
        return;
      }
      for (final entity in entities) {
        if (results.length >= maxResults) return;
        final name = entity.path.split(Platform.pathSeparator).last;
        if (ignored.contains(name)) continue;
        if (entity is Directory) {
          await walk(entity);
          continue;
        }
        if (entity is! File) continue;

        try {
          if (await entity.length() > 8 * 1024 * 1024) continue;
          final content = await entity.readAsString();
          if (content.contains('\u0000')) continue;
          final rel = entity.path.startsWith('$absRoot/')
              ? entity.path.substring(absRoot.length + 1)
              : name;
          final lines = content.split('\n');
          for (var i = 0; i < lines.length; i++) {
            final line = lines[i];
            final col = line.toLowerCase().indexOf(needle);
            if (col < 0) continue;
            results.add(WorkspaceSearchResult(
              path: rel,
              line: i + 1,
              col: col + 1,
              text: line.trim(),
            ));
            if (results.length >= maxResults) return;
          }
        } catch (_) {}
      }
    }

    await walk(rootDir);
    return results;
  }

  @override
  Future<AgentToolResult> executeAgentTool(
    String toolId,
    Map<String, dynamic> input, {
    required String workspaceRoot,
    Duration? timeout,
  }) async {
    final root = workspaceRoot;
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
          final size = await file.length();
          if (size > 10 * 1024 * 1024) {
            return const AgentToolResult(
                ok: false, output: '', error: 'file exceeds 10 MiB limit');
          }
          return AgentToolResult(ok: true, output: await file.readAsString());

        case 'file.write':
          final path = _resolve(root, input['path']?.toString() ?? '');
          final content = input['content']?.toString() ?? '';
          if (content.length > 10 * 1024 * 1024) {
            return const AgentToolResult(
                ok: false, output: '', error: 'file content exceeds 10 MiB limit');
          }
          await File(path).parent.create(recursive: true);
          await File(path).writeAsString(content);
          return AgentToolResult(
            ok: true,
            output:
                '{"written":true,"size":${utf8.encode(content).length}}',
          );

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
          if (input['approved'] != true) {
            return const AgentToolResult(
              ok: false,
              output: '',
              error: 'approval_required',
            );
          }
          final command = input['command']?.toString() ?? '';
          if (command.isEmpty) {
            return const AgentToolResult(
                ok: false, output: '', error: 'no command provided');
          }
          final process = await Process.start(
            'bash',
            ['-c', command],
            workingDirectory: root,
            runInShell: false,
          );
          final stdoutFuture = process.stdout.transform(utf8.decoder).join();
          final stderrFuture = process.stderr.transform(utf8.decoder).join();
          try {
            final exitCode = await process.exitCode.timeout(delay);
            final stdout = await stdoutFuture;
            final stderr = await stderrFuture;
            final combined = [
              if (stdout.trimRight().isNotEmpty) stdout.trimRight(),
              if (stderr.trimRight().isNotEmpty) stderr.trimRight(),
            ].join('\n');
            final isSuccess = exitCode == 0;
            return AgentToolResult(
              ok: isSuccess,
              output: isSuccess
                  ? (combined.isEmpty ? '(command completed with no output)' : combined)
                  : stdout.trimRight(),
              error: isSuccess
                  ? ''
                  : (stderr.trimRight().isNotEmpty
                      ? stderr.trimRight()
                      : 'process exited with code ' + exitCode.toString()),
            );
          } on TimeoutException {
            process.kill(ProcessSignal.sigkill);
            await process.exitCode;
            return AgentToolResult(
              ok: false,
              output: '',
              error: 'command timed out after ' + delay.inSeconds.toString() + 's',
            );
          }

        case 'workspace.search':
          final query = input['query']?.toString() ?? '';
          final maxResults = (input['max_results'] as num?)?.toInt() ?? 50;
          final hits = await workspaceSearch(
            root,
            query,
            maxResults: maxResults.clamp(1, 10000).toInt(),
          );
          final payload = hits
              .map((hit) => {
                    'path': hit.path,
                    'line': hit.line,
                    'col': hit.col,
                    'text': hit.text,
                  })
              .toList();
          return AgentToolResult(ok: true, output: jsonEncode(payload));

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

  int _byteOffsetToCodeUnitIndex(String text, int byteOffset) {
    if (byteOffset < 0) {
      throw RangeError.index(byteOffset, text);
    }
    var bytes = 0;
    var codeUnits = 0;
    for (final rune in text.runes) {
      final chunk = String.fromCharCode(rune);
      final chunkBytes = utf8.encode(chunk).length;
      if (byteOffset == bytes) return codeUnits;
      if (byteOffset < bytes + chunkBytes) {
        throw RangeError('byte offset splits a UTF-8 code point');
      }
      bytes += chunkBytes;
      codeUnits += rune > 0xFFFF ? 2 : 1;
    }
    if (byteOffset == bytes) return codeUnits;
    throw RangeError('byte offset $byteOffset exceeds $bytes bytes');
  }

  String _resolve(String root, String raw) {
    final p = raw.trim();
    if (p.isEmpty) return root;
    final isAbsolute =
        p.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p);
    if (isAbsolute) {
      throw StateError('absolute paths are not allowed in the workspace sandbox');
    }
    final segments = p.split(RegExp(r'[/\\]'));
    if (segments.any((segment) => segment == '..')) {
      throw StateError('path escapes workspace');
    }
    return root + '/' + p.replaceAll('\\', '/');
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
