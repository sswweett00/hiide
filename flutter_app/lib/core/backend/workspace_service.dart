import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../shared/models/file_tree_item.dart';
import 'backend_service.dart';
import 'web_workspace.dart';

typedef NativePickResult = ({String? path, String message});

String pathBasename(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

class WorkspaceService {
  WorkspaceService({required this.rootPath});

  static const int maxReadBytes = 5 * 1024 * 1024;
  static const int maxTreeEntries = 50000;
  static const int maxTreeDepth = 64;
  static const int maxDiffOccurrences = 2;

  final String rootPath;

  static Future<NativePickResult> pickDirectoryWithNativeDialog() async {
    if (kIsWeb) return (path: null, message: 'Klasör seçimi yalnızca masaüstünde kullanılabilir.');
    const timeout = Duration(seconds: 20);
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '/';
    final List<(String exe, List<String> args)> candidates;
    if (Platform.isLinux) {
      candidates = [
        ('zenity', ['--file-selection', '--directory', '--title=Hiide AI IDE - Select Workspace Directory']),
        ('kdialog', ['--getexistingdirectory', home]),
      ];
    } else if (Platform.isWindows) {
      candidates = [('powershell', ['-Command', 'Add-Type -AssemblyName System.Windows.Forms; \$f = New-Object System.Windows.Forms.FolderBrowserDialog; if (\$f.ShowDialog() -eq "OK") { \$f.SelectedPath }'])];
    } else if (Platform.isMacOS) {
      candidates = [('osascript', ['-e', 'POSIX path of (choose folder with prompt "Select Workspace Folder")'])];
    } else {
      return (path: null, message: 'Sistem klasör seçici bu platformda desteklenmiyor (${Platform.operatingSystem}).');
    }

    final missing = <String>[];
    for (final (exe, args) in candidates) {
      if (!_isOnPath(exe)) {
        missing.add(exe);
        continue;
      }
      final result = await _runPicker(exe, args, timeout);
      if (result.exitCode == 0) {
        final selected = _validateSelection(result.stdout);
        if (selected != null) return (path: selected, message: '');
      }
    }
    if (missing.isNotEmpty) {
      return (path: null, message: 'Sistem klasör seçici bulunamadı: ${missing.join(', ')}. Bunun yerine dahili dosya yöneticisini kullanın.');
    }
    return (path: null, message: '');
  }

  static bool _isOnPath(String exe) {
    try {
      final result = Platform.isWindows ? Process.runSync('where', [exe]) : Process.runSync('which', [exe]);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<ProcessResult> _runPicker(String exe, List<String> args, Duration timeout) async {
    Process? process;
    try {
      process = await Process.start(exe, args);
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();
      final code = await process.exitCode.timeout(timeout, onTimeout: () {
        try { process!.kill(ProcessSignal.sigkill); } catch (_) {}
        return -1;
      });
      return ProcessResult(process.pid, code, await stdoutFuture, await stderrFuture);
    } catch (e) {
      return ProcessResult(process?.pid ?? -1, -1, '', e.toString());
    }
  }

  static String? _validateSelection(dynamic raw) {
    final selected = raw.toString().trim();
    if (selected.isEmpty) return null;
    final normalized = normalizePath(selected);
    try {
      if (Directory(normalized).existsSync()) return normalized;
    } catch (_) {}
    return null;
  }

  static String normalizePath(String path) {
    final trimmed = path.trim();
    if (trimmed == '/' || RegExp(r'^[A-Za-z]:[\\/]$').hasMatch(trimmed)) return trimmed;
    final normalized = trimmed.replaceAll(RegExp(r'[\\/]+$'), '');
    return normalized.isEmpty ? trimmed : normalized;
  }

  String _normalizedRoot() => normalizePath(Directory(rootPath).absolute.path);

  String _resolveWorkspacePath(String path) {
    final root = _normalizedRoot();
    final candidate = path.trim().isEmpty ? root : normalizePath(Directory(path).absolute.path);
    final separator = Platform.pathSeparator;
    final rootPrefix = root.endsWith(separator) ? root : '$root$separator';
    if (candidate != root && !candidate.startsWith(rootPrefix)) {
      throw FileSystemException('Path escapes workspace root', path);
    }
    return candidate;
  }

  bool _isIgnoredName(String name) {
    if (name == '.git' || name == '.dart_tool' || name == '.idea' || name == '.vscode') return true;
    if (name == '.zig-cache' || name == 'zig-out' || name == 'build' || name == 'dist' || name == 'node_modules' || name == 'target') return true;
    return false;
  }

  Future<({String path, String content})?> findWelcomeFile(String root) async {
    if (kIsWeb) {
      final ws = webWorkspaceStore.workspace;
      if (ws == null || ws.rootPath != root) return null;
      return ws.findWelcomeFile();
    }
    final safeRoot = _resolveWorkspacePath(root);
    for (final name in const ['README.md', 'Readme.md', 'readme.md', 'README.txt']) {
      try {
        final candidate = _resolveWorkspacePath('$safeRoot/$name');
        final file = File(candidate);
        if (!await file.exists()) continue;
        final size = await file.length();
        if (size > maxReadBytes) continue;
        return (path: candidate, content: await file.readAsString());
      } catch (_) {}
    }
    return null;
  }

  Future<List<FileTreeItem>> loadTree({String? relativeOrAbsPath, BackendService? engine}) async {
    if (kIsWeb) {
      final ws = webWorkspaceStore.workspace;
      if (ws != null && ws.rootPath == rootPath) return buildWebFileTree(ws);
      return [];
    }
    final targetPath = _resolveWorkspacePath(relativeOrAbsPath ?? rootPath);
    final dir = Directory(targetPath);
    if (!await dir.exists()) return [];
    if (engine != null) {
      try {
        final entries = await engine.workspaceTree(targetPath, maxEntries: maxTreeEntries);
        return _buildTreeFromEntries(entries, targetPath);
      } catch (e) {
        debugPrint('Engine tree failed ($e); falling back to Dart walk');
      }
    }
    return _loadTreeDart(targetPath, depth: 0, counter: <int>[0]);
  }

  List<FileTreeItem> _buildTreeFromEntries(List<WorkspaceFile> entries, String root) {
    final children = <String, List<FileTreeItem>>{};
    final topLevel = <FileTreeItem>[];
    for (final e in entries.reversed.take(maxTreeEntries)) {
      final clean = e.path.replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '');
      if (clean.isEmpty) continue;
      final segments = clean.split('/');
      if (segments.any(_isIgnoredName)) continue;
      final slash = clean.lastIndexOf('/');
      final parentRel = slash == -1 ? '' : clean.substring(0, slash);
      final name = clean.substring(slash + 1);
      final item = FileTreeItem(
        name: name,
        path: '$root/$clean',
        isFile: !e.isDirectory,
        icon: e.isDirectory ? Icons.folder : _getIconForFile(name),
        children: children[clean]?.reversed.toList() ?? const [],
      );
      if (parentRel.isEmpty) {
        topLevel.add(item);
      } else {
        (children[parentRel] ??= []).add(item);
      }
    }
    return topLevel.reversed.toList();
  }

  Future<List<FileTreeItem>> _loadTreeDart(String targetPath, {required int depth, required List<int> counter}) async {
    if (depth > maxTreeDepth || counter[0] >= maxTreeEntries) return [];
    final dir = Directory(targetPath);
    if (!await dir.exists()) return [];
    final items = <FileTreeItem>[];
    try {
      final entities = await dir.list(followLinks: false).toList();
      entities.sort((a, b) {
        final aDir = a is Directory;
        final bDir = b is Directory;
        if (aDir != bDir) return aDir ? -1 : 1;
        return pathBasename(a.path).toLowerCase().compareTo(pathBasename(b.path).toLowerCase());
      });
      for (final entity in entities) {
        if (counter[0] >= maxTreeEntries) break;
        final name = pathBasename(entity.path);
        if (_isIgnoredName(name)) continue;
        counter[0]++;
        if (entity is Directory) {
          items.add(FileTreeItem(name: name, path: entity.path, isFile: false, icon: Icons.folder, children: await _loadTreeDart(entity.path, depth: depth + 1, counter: counter)));
        } else if (entity is File) {
          items.add(FileTreeItem(name: name, path: entity.path, isFile: true, icon: _getIconForFile(name)));
        }
      }
    } catch (e) {
      debugPrint('Error listing directory $targetPath: $e');
    }
    return items;
  }

  Future<String> readFile(String filePath) async {
    if (kIsWeb) {
      final ws = webWorkspaceStore.workspace;
      final rel = ws?.relOf(filePath);
      if (ws != null && rel != null) return ws.readText(rel);
      return _mockWebContent(filePath);
    }
    final safePath = _resolveWorkspacePath(filePath);
    final file = File(safePath);
    if (!await file.exists()) throw Exception('File not found: $safePath');
    final size = await file.length();
    if (size > maxReadBytes) throw FileSystemException('File exceeds ${maxReadBytes} byte read limit', safePath);
    return file.readAsString();
  }

  Future<void> writeFile(String filePath, String content) async {
    if (kIsWeb) {
      final ws = webWorkspaceStore.workspace;
      final rel = ws?.relOf(filePath);
      if (ws != null && rel != null) ws.writeText(rel, content);
      return;
    }
    final safePath = _resolveWorkspacePath(filePath);
    final file = File(safePath);
    await file.parent.create(recursive: true);
    final temp = File('$safePath.hiide-tmp-${DateTime.now().microsecondsSinceEpoch}');
    await temp.writeAsString(content, flush: true);
    try {
      if (await file.exists()) await file.delete();
      await temp.rename(safePath);
    } catch (_) {
      try { if (await temp.exists()) await temp.delete(); } catch (_) {}
      rethrow;
    }
  }

  Future<bool> applyDiff(String filePath, String target, String replacement) async {
    if (target.isEmpty) return false;
    if (kIsWeb) {
      final ws = webWorkspaceStore.workspace;
      final rel = ws?.relOf(filePath);
      if (ws == null || rel == null) return false;
      final content = await ws.readText(rel);
      final first = content.indexOf(target);
      if (first < 0 || content.indexOf(target, first + target.length) >= 0) return false;
      ws.writeText(rel, content.replaceRange(first, first + target.length, replacement));
      return true;
    }
    final safePath = _resolveWorkspacePath(filePath);
    final content = await readFile(safePath);
    final first = content.indexOf(target);
    if (first < 0 || content.indexOf(target, first + target.length) >= 0) return false;
    final newContent = content.replaceRange(first, first + target.length, replacement);
    await writeFile(safePath, newContent);
    return true;
  }

  Future<void> createFile(String filePath, {String content = ''}) async {
    if (kIsWeb) {
      final ws = webWorkspaceStore.workspace;
      final rel = ws?.relOf(filePath) ?? filePath;
      if (ws != null) ws.writeText(rel, content);
      return;
    }
    final safePath = _resolveWorkspacePath(filePath);
    final file = File(safePath);
    await file.parent.create(recursive: true);
    if (!await file.exists()) await file.writeAsString(content, flush: true);
  }

  Future<void> createDirectory(String dirPath) async {
    if (kIsWeb) return;
    await Directory(_resolveWorkspacePath(dirPath)).create(recursive: true);
  }

  Future<void> deleteEntity(String path) async {
    if (kIsWeb) return;
    final safePath = _resolveWorkspacePath(path);
    final file = File(safePath);
    final dir = Directory(safePath);
    if (await file.exists()) {
      await file.delete();
    } else if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  Future<void> renameEntity(String oldPath, String newPath) async {
    if (kIsWeb) return;
    final safeOld = _resolveWorkspacePath(oldPath);
    final safeNew = _resolveWorkspacePath(newPath);
    final file = File(safeOld);
    final dir = Directory(safeOld);
    if (await file.exists()) {
      await file.parent.create(recursive: true);
      await file.rename(safeNew);
    } else if (await dir.exists()) {
      await dir.rename(safeNew);
    }
  }

  String _mockWebContent(String filePath) => '// ${pathBasename(filePath)}\n// Mock preview content.\n';

  IconData _getIconForFile(String fileName) {
    final name = fileName.toLowerCase();
    if (name.endsWith('.dart')) return Icons.flutter_dash;
    if (name.endsWith('.zig')) return Icons.bolt;
    if (name.endsWith('.rs')) return Icons.settings_applications;
    if (name.endsWith('.yaml') || name.endsWith('.yml') || name.endsWith('.json')) return Icons.settings;
    if (name.endsWith('.md')) return Icons.description;
    if (name.endsWith('.sh') || name.endsWith('.bash')) return Icons.terminal;
    return Icons.insert_drive_file_outlined;
  }
}
