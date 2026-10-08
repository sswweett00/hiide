import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hiide_flutter/core/backend/backend_service.dart';

/// In-memory test double for the current backend contract.
class MockBackendService implements BackendService {
  bool _connected = false;
  final _output = StreamController<String>.broadcast();
  final _fsChanges = StreamController<FsChange>.broadcast();

  @override Stream<String> get outputStream => _output.stream;
  @override Stream<FsChange> get fsChangeStream => _fsChanges.stream;
  @override bool get isConnected => _connected;

  @override Future<void> connect() async {
    _connected = true;
    _output.add('Connected to Hiide backend (mock)');
  }
  @override Future<void> disconnect() async {
    _connected = false;
    if (!_output.isClosed) _output.add('Backend disconnected');
  }
  @override Future<String> ping() async => 'pong';

  @override Future<List<WorkspaceFile>> workspaceTree(String root, {int maxEntries = 50000}) async {
    final out = <WorkspaceFile>[];
    final rootDir = Directory(root);
    if (!await rootDir.exists()) return out;
    final absRoot = rootDir.absolute.path;
    Future<void> walk(Directory dir) async {
      if (out.length >= maxEntries) return;
      List<FileSystemEntity> entities;
      try { entities = await dir.list(followLinks: false).toList(); } catch (_) { return; }
      entities.sort((a, b) {
        final ad = a is Directory, bd = b is Directory;
        if (ad != bd) return ad ? -1 : 1;
        return a.path.compareTo(b.path);
      });
      for (final entity in entities) {
        if (out.length >= maxEntries) return;
        final name = entity.path.split(Platform.pathSeparator).last;
        if (_ignored.contains(name)) continue;
        final abs = entity.absolute.path;
        final rel = abs.startsWith('$absRoot${Platform.pathSeparator}')
            ? abs.substring(absRoot.length + 1).replaceAll(Platform.pathSeparator, '/')
            : name;
        if (entity is Directory) {
          out.add(WorkspaceFile(name: name, path: rel, isDirectory: true));
          await walk(entity);
        } else if (entity is File) {
          var size = 0;
          try { size = await entity.length(); } catch (_) {}
          out.add(WorkspaceFile(name: name, path: rel, isDirectory: false, size: size));
        }
      }
    }
    await walk(rootDir);
    return out;
  }

  @override Future<List<WorkspaceSearchResult>> workspaceSearch(String query, {int maxResults = 200}) async {
    final root = _searchRoot;
    if (root == null || query.trim().isEmpty || maxResults <= 0) return const [];
    final results = <WorkspaceSearchResult>[];
    final rootDir = Directory(root);
    if (!await rootDir.exists()) return results;
    final needle = query.toLowerCase();
    Future<void> walk(Directory dir) async {
      if (results.length >= maxResults) return;
      List<FileSystemEntity> entities;
      try { entities = await dir.list(followLinks: false).toList(); } catch (_) { return; }
      for (final entity in entities) {
        if (results.length >= maxResults) return;
        final name = entity.path.split(Platform.pathSeparator).last;
        if (_ignored.contains(name)) continue;
        if (entity is Directory) { await walk(entity); continue; }
        if (entity is! File) continue;
        try {
          if (await entity.length() > 8 * 1024 * 1024) continue;
          final text = await entity.readAsString();
          if (text.contains('\u0000')) continue;
          final rel = entity.absolute.path.startsWith(rootDir.absolute.path + Platform.pathSeparator)
              ? entity.absolute.path.substring(rootDir.absolute.path.length + 1).replaceAll(Platform.pathSeparator, '/')
              : name;
          final lines = text.split('\n');
          for (var i = 0; i < lines.length && results.length < maxResults; i++) {
            final index = lines[i].toLowerCase().indexOf(needle);
            if (index < 0) continue;
            results.add(WorkspaceSearchResult(path: rel, line: i + 1, col: index + 1, text: lines[i].trim()));
          }
        } catch (_) {}
      }
    }
    await walk(rootDir);
    return results;
  }

  String? _searchRoot;
  static const _ignored = <String>{'.git','.hg','.svn','.dart_tool','.idea','.vscode','.zig-cache','zig-out','build','dist','node_modules','target'};

  @override Future<AgentToolResult> executeAgentTool(String toolId, Map<String, dynamic> input, {required String workspaceRoot, Duration? timeout}) async {
    final delay = timeout ?? const Duration(seconds: 60);
    try {
      switch (toolId) {
        case 'file.read':
          final path = _resolve(workspaceRoot, input['path']?.toString() ?? '');
          final file = File(path);
          if (!await file.exists()) return AgentToolResult(ok: false, output: '', error: 'file not found: ' + path);
          if (await file.length() > 10 * 1024 * 1024) return const AgentToolResult(ok: false, output: '', error: 'file exceeds 10 MiB limit');
          return AgentToolResult(ok: true, output: await file.readAsString());
        case 'file.write':
          final path = _resolve(workspaceRoot, input['path']?.toString() ?? '');
          final content = input['content']?.toString() ?? '';
          if (utf8.encode(content).length > 10 * 1024 * 1024) return const AgentToolResult(ok: false, output: '', error: 'file content exceeds 10 MiB limit');
          final file = File(path);
          await file.parent.create(recursive: true);
          final tmp = File(path + '.hiide-test-tmp');
          await tmp.writeAsString(content, flush: true);
          if (await file.exists()) await file.delete();
          await tmp.rename(path);
          return AgentToolResult(ok: true, output: '{"written":true,"size":' + utf8.encode(content).length.toString() + '}');
        case 'file.delete':
          final path = _resolve(workspaceRoot, input['path']?.toString() ?? '');
          final file = File(path);
          final dir = Directory(path);
          if (await file.exists()) { await file.delete(); return const AgentToolResult(ok: true, output: '{"deleted":true}'); }
          if (await dir.exists()) { await dir.delete(recursive: true); return const AgentToolResult(ok: true, output: '{"deleted":true}'); }
          return AgentToolResult(ok: false, output: '', error: 'file or directory not found: ' + path);
        case 'file.mkdir':
          final path = _resolve(workspaceRoot, input['path']?.toString() ?? '');
          await Directory(path).create(recursive: true);
          return const AgentToolResult(ok: true, output: '{"created":true}');
        case 'file.apply_diff':
          final path = _resolve(workspaceRoot, input['path']?.toString() ?? '');
          final target = input['target']?.toString() ?? '';
          final replacement = input['replacement']?.toString() ?? '';
          if (target.isEmpty) return const AgentToolResult(ok: false, output: '', error: 'target text is required');
          final file = File(path);
          if (!await file.exists()) return AgentToolResult(ok: false, output: '', error: 'file not found: ' + path);
          final current = await file.readAsString();
          final first = current.indexOf(target);
          if (first < 0) return AgentToolResult(ok: false, output: '', error: 'target text not found in ' + path);
          if (current.indexOf(target, first + target.length) >= 0) return const AgentToolResult(ok: false, output: '', error: 'target text is not unique');
          final updated = current.replaceRange(first, first + target.length, replacement);
          final tmp = File(path + '.hiide-test-tmp');
          await tmp.writeAsString(updated, flush: true);
          await file.delete();
          await tmp.rename(path);
          return const AgentToolResult(ok: true, output: '{"applied":true}');
        case 'file.list':
          final path = _resolve(workspaceRoot, input['path']?.toString() ?? '.');
          final dir = Directory(path);
          if (!await dir.exists()) return AgentToolResult(ok: false, output: '', error: 'directory not found: ' + path);
          final entries = (await dir.list(followLinks: false).toList()).where((e) => !_ignored.contains(e.path.split(Platform.pathSeparator).last)).map((e) => <String, dynamic>{'name': e.path.split(Platform.pathSeparator).last, 'kind': e is Directory ? 'directory' : 'file'}).toList();
          return AgentToolResult(ok: true, output: jsonEncode(entries));
        case 'process.run':
          if (input['approved'] != true) return const AgentToolResult(ok: false, output: '', error: 'approval_required');
          final command = input['command']?.toString() ?? '';
          if (command.isEmpty) return const AgentToolResult(ok: false, output: '', error: 'no command provided');
          final process = await Process.start('bash', ['-c', command], workingDirectory: _resolve(workspaceRoot, '.'));
          final stdout = process.stdout.transform(utf8.decoder).join();
          final stderr = process.stderr.transform(utf8.decoder).join();
          final code = await process.exitCode.timeout(delay, onTimeout: () { process.kill(ProcessSignal.sigkill); return -1; });
          final out = await stdout;
          final err = await stderr;
          if (code == -1) return AgentToolResult(ok: false, output: '', error: 'command timed out after ' + delay.inSeconds.toString() + 's');
          return AgentToolResult(ok: code == 0, output: out.trimRight(), error: code == 0 ? '' : (err.trimRight().isEmpty ? 'process exited with code ' + code.toString() : err.trimRight()));
        case 'workspace.search':
          final rootBackup = _searchRoot;
          _searchRoot = workspaceRoot;
          final hits = await workspaceSearch(input['query']?.toString() ?? '', maxResults: ((input['max_results'] as num?)?.toInt() ?? 50).clamp(1, 1000).toInt());
          _searchRoot = rootBackup;
          return AgentToolResult(ok: true, output: jsonEncode(hits.map((h) => {'path': h.path, 'line': h.line, 'col': h.col, 'text': h.text}).toList()));
        default:
          return AgentToolResult(ok: false, output: '', error: 'unknown tool: ' + toolId);
      }
    } on TimeoutException {
      return AgentToolResult(ok: false, output: '', error: 'command timed out after ' + delay.inSeconds.toString() + 's');
    } catch (e) {
      return AgentToolResult(ok: false, output: '', error: e.toString());
    }
  }

  String _resolve(String root, String raw) {
    final p = raw.trim();
    if (p.isEmpty || p == '.') return Directory(root).absolute.path;
    final absolute = p.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p);
    if (absolute || p.split(RegExp(r'[/\\]')).contains('..')) throw StateError('path escapes workspace');
    return Directory(root).absolute.path + Platform.pathSeparator + p.replaceAll(RegExp(r'[/\\]'), Platform.pathSeparator);
  }

  @override Future<void> watchWorkspace(String root) async { _searchRoot = root; }
  @override Future<void> unwatchWorkspace() async { _searchRoot = null; }
  @override void dispose() { unawaited(_output.close()); unawaited(_fsChanges.close()); }
}