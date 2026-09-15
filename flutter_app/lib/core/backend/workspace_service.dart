import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../shared/models/file_tree_item.dart';
import 'backend_service.dart';
import 'web_workspace.dart';

/// Result of the native directory picker: [path] is a validated, normalized
/// absolute path — null when the user cancelled or nothing could be picked.
/// [message] explains why nothing was picked (missing tool, unsupported
/// platform); it is empty for a plain cancel, which is not an error.
typedef NativePickResult = ({String? path, String message});

/// Last path segment, splitting on both `/` and `\` so it works on every
/// platform AND on the web, where `dart:io`'s [Platform] is unavailable.
/// Robust to trailing separators and root paths.
String pathBasename(String path) {
  final parts =
      path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

class WorkspaceService {
  final String rootPath;

  WorkspaceService({required this.rootPath});

  /// Opens the native OS directory picker: zenity → kdialog on Linux, the
  /// classic FolderBrowserDialog on Windows, `choose folder` on macOS. Every
  /// tool is probed first and each call is bounded by a timeout, so a missing
  /// binary never hangs or silently fails — the caller gets a clear message.
  static Future<NativePickResult> pickDirectoryWithNativeDialog() async {
    if (kIsWeb) {
      return (
        path: null,
        message: 'Klasör seçimi yalnızca masaüstünde kullanılabilir.'
      );
    }

    const timeout = Duration(seconds: 20);
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '/';

    final List<(String exe, List<String> args)> candidates;
    if (Platform.isLinux) {
      candidates = [
        (
          'zenity',
          [
            '--file-selection',
            '--directory',
            '--title=Hiide AI IDE - Select Workspace Directory',
          ],
        ),
        ('kdialog', ['--getexistingdirectory', home]),
      ];
    } else if (Platform.isWindows) {
      candidates = [
        (
          'powershell',
          [
            '-Command',
            'Add-Type -AssemblyName System.Windows.Forms; '
                '\$f = New-Object System.Windows.Forms.FolderBrowserDialog; '
                'if (\$f.ShowDialog() -eq "OK") { \$f.SelectedPath }',
          ],
        ),
      ];
    } else if (Platform.isMacOS) {
      candidates = [
        (
          'osascript',
          [
            '-e',
            'POSIX path of (choose folder with prompt "Select Workspace Folder")',
          ],
        ),
      ];
    } else {
      return (
        path: null,
        message: 'Sistem klasör seçici bu platformda desteklenmiyor '
            '(${Platform.operatingSystem}).',
      );
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
      // Non-zero exit (e.g. cancel) or invalid output → try the next tool.
    }

    if (missing.isNotEmpty) {
      return (
        path: null,
        message: 'Sistem klasör seçici bulunamadı: ${missing.join(', ')}. '
            'Bunun yerine dahili dosya yöneticisini kullanın.',
      );
    }
    // Every available tool ran but produced no selection → plain cancel.
    return (path: null, message: '');
  }

  /// Whether [exe] is resolvable on PATH (`where` on Windows, `which` else).
  static bool _isOnPath(String exe) {
    try {
      final result = Platform.isWindows
          ? Process.runSync('where', [exe])
          : Process.runSync('which', [exe]);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Runs a picker binary, killing it and returning a failure result when it
  /// does not exit within [timeout] (e.g. the binary is not installed or the
  /// OS dialog hangs). Never throws.
  static Future<ProcessResult> _runPicker(
    String exe,
    List<String> args,
    Duration timeout,
  ) async {
    try {
      final process = await Process.start(exe, args);
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();
      final code = await process.exitCode.timeout(timeout, onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      });
      return ProcessResult(
          process.pid, code, await stdoutFuture, await stderrFuture);
    } catch (e) {
      return ProcessResult(-1, -1, '', e.toString());
    }
  }

  /// Trims picker output, normalizes it and rejects paths that are not
  /// existing directories.
  static String? _validateSelection(dynamic raw) {
    final selected = raw.toString().trim();
    if (selected.isEmpty) return null;
    final normalized = normalizePath(selected);
    try {
      if (Directory(normalized).existsSync()) return normalized;
    } catch (_) {}
    return null;
  }

  /// Strips trailing path separators while keeping root paths intact (`/`,
  /// `C:\`), so concatenations like `'$root/${change.path}'` never double up.
  static String normalizePath(String path) {
    final trimmed = path.trim();
    if (trimmed == '/' || RegExp(r'^[A-Za-z]:[\\/]$').hasMatch(trimmed)) {
      return trimmed;
    }
    final normalized = trimmed.replaceAll(RegExp(r'[\\/]+$'), '');
    return normalized.isEmpty ? trimmed : normalized;
  }

  /// Locates the workspace's README (common casings) and returns its path and
  /// content, or null when the folder has none. Used to land the IDE on the
  /// project after a folder is opened. Pure I/O — failures return null.
  /// On web this resolves against the picked folder instead of the disk.
  Future<({String path, String content})?> findWelcomeFile(String root) async {
    if (kIsWeb) {
      final ws = webWorkspaceStore.workspace;
      if (ws == null || ws.rootPath != root) return null;
      return ws.findWelcomeFile();
    }
    for (final name in const [
      'README.md',
      'Readme.md',
      'readme.md',
      'README.txt',
    ]) {
      final candidate = '$root/$name';
      try {
        final file = File(candidate);
        if (!await file.exists()) continue;
        final content = await file.readAsString();
        return (path: candidate, content: content);
      } catch (_) {}
    }
    return null;
  }

  /// Reads directory contents recursively or single-level to construct a real [FileTreeItem] tree.
  ///
  /// When [engine] is provided and reachable, the tree is enumerated by the
  /// native Zig engine (`workspace.tree` — one pass, sorted, junk-filtered)
  /// and rebuilt into [FileTreeItem]s here; otherwise a Dart walk is used
  /// (offline / web fallback).
  Future<List<FileTreeItem>> loadTree({
    String? relativeOrAbsPath,
    BackendService? engine,
  }) async {
    if (kIsWeb) {
      // A browser-picked folder renders its real tree; before any pick the
      // tree is empty so the Explorer shows the "pick a folder" state
      // instead of fake placeholder files.
      final ws = webWorkspaceStore.workspace;
      if (ws != null && ws.rootPath == rootPath) return buildWebFileTree(ws);
      return [];
    }
    final targetPath = relativeOrAbsPath ?? rootPath;
    final dir = Directory(targetPath);
    if (!await dir.exists()) return [];

    if (engine != null) {
      try {
        final entries = await engine.workspaceTree(targetPath);
        return _buildTreeFromEntries(entries, targetPath);
      } catch (e) {
        debugPrint('Engine tree failed ($e); falling back to Dart walk');
      }
    }
    return _loadTreeDart(targetPath);
  }

  /// Builds the nested [FileTreeItem] hierarchy from the engine's flat,
  /// sorted (directory-first, parent-before-child) entry list.
  List<FileTreeItem> _buildTreeFromEntries(
      List<WorkspaceFile> entries, String root) {
    final children = <String, List<FileTreeItem>>{};
    final topLevel = <FileTreeItem>[];
    for (final e in entries.reversed) {
      final slash = e.path.lastIndexOf('/');
      final parentRel = slash == -1 ? '' : e.path.substring(0, slash);
      final name = e.path.substring(slash + 1);
      final item = FileTreeItem(
        name: name,
        path: '$root/${e.path}',
        isFile: !e.isDirectory,
        icon: e.isDirectory ? Icons.folder : _getIconForFile(name),
        children: children[e.path]?.reversed.toList() ?? const [],
      );
      if (parentRel.isEmpty) {
        topLevel.add(item);
      } else {
        (children[parentRel] ??= []).add(item);
      }
    }
    return topLevel.reversed.toList();
  }

  Future<List<FileTreeItem>> _loadTreeDart(String targetPath) async {
    final dir = Directory(targetPath);
    if (!await dir.exists()) return [];

    final List<FileTreeItem> items = [];

    try {
      final List<FileSystemEntity> entities =
          await dir.list(followLinks: false).toList();
      entities.sort((a, b) {
        final aIsDir = a is Directory;
        final bIsDir = b is Directory;
        if (aIsDir != bIsDir) return aIsDir ? -1 : 1;
        return a.path.compareTo(b.path);
      });

      for (final entity in entities) {
        final name = pathBasename(entity.path);
        if (name.startsWith('.git') ||
            name == '.zig-cache' ||
            name == 'build') {
          continue;
        }

        if (entity is Directory) {
          items.add(FileTreeItem(
            name: name,
            path: entity.path,
            isFile: false,
            icon: Icons.folder,
            children: await _loadTreeDart(entity.path),
          ));
        } else if (entity is File) {
          items.add(FileTreeItem(
            name: name,
            path: entity.path,
            isFile: true,
            icon: _getIconForFile(name),
          ));
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
    final file = File(filePath);
    if (await file.exists()) {
      return await file.readAsString();
    }
    throw Exception('File not found: $filePath');
  }

  Future<void> writeFile(String filePath, String content) async {
    if (kIsWeb) {
      // The picked folder cannot be written to disk from the browser; the
      // write is kept in the session overlay so Save behaves as expected.
      final ws = webWorkspaceStore.workspace;
      final rel = ws?.relOf(filePath);
      if (ws != null && rel != null) ws.writeText(rel, content);
      return;
    }
    final file = File(filePath);
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  Future<bool> applyDiff(
      String filePath, String target, String replacement) async {
    if (kIsWeb) {
      final ws = webWorkspaceStore.workspace;
      final rel = ws?.relOf(filePath);
      if (ws == null || rel == null) return false;
      final content = await ws.readText(rel);
      if (!content.contains(target)) return false;
      ws.writeText(rel, content.replaceFirst(target, replacement));
      return true;
    }
    final file = File(filePath);
    if (!await file.exists()) return false;
    final content = await file.readAsString();
    if (!content.contains(target)) return false;
    final newContent = content.replaceFirst(target, replacement);
    await file.writeAsString(newContent);
    return true;
  }

  Future<void> createFile(String filePath, {String content = ''}) async {
    if (kIsWeb) {
      final ws = webWorkspaceStore.workspace;
      final rel = ws?.relOf(filePath) ?? filePath;
      if (ws != null) ws.writeText(rel, content);
      return;
    }
    final file = File(filePath);
    await file.parent.create(recursive: true);
    if (!await file.exists()) {
      await file.writeAsString(content);
    }
  }

  Future<void> createDirectory(String dirPath) async {
    if (kIsWeb) return;
    final dir = Directory(dirPath);
    await dir.create(recursive: true);
  }

  Future<void> deleteEntity(String path) async {
    if (kIsWeb) return;
    final file = File(path);
    final dir = Directory(path);
    if (await file.exists()) {
      await file.delete();
    } else if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  Future<void> renameEntity(String oldPath, String newPath) async {
    if (kIsWeb) return;
    final file = File(oldPath);
    final dir = Directory(oldPath);
    if (await file.exists()) {
      await file.parent.create(recursive: true);
      await file.rename(newPath);
    } else if (await dir.exists()) {
      await dir.rename(newPath);
    }
  }

  String _mockWebContent(String filePath) {
    final name = filePath.split('/').last;
    return '// $name\n// Mock preview content.\n';
  }

  IconData _getIconForFile(String fileName) {
    if (fileName.endsWith('.dart')) return Icons.flutter_dash;
    if (fileName.endsWith('.zig')) return Icons.bolt;
    if (fileName.endsWith('.rs')) return Icons.settings_applications;
    if (fileName.endsWith('.yaml') ||
        fileName.endsWith('.yml') ||
        fileName.endsWith('.json')) {
      return Icons.settings;
    }
    if (fileName.endsWith('.md')) return Icons.description;
    if (fileName.endsWith('.sh') || fileName.endsWith('.bash'))
      return Icons.terminal;
    return Icons.insert_drive_file_outlined;
  }
}
