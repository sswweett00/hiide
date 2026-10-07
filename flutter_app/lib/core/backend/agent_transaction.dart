import 'dart:collection';
import 'dart:convert';

import 'backend_service.dart';

/// Run-scoped filesystem transaction for agent-authored workspace mutations.
///
/// A snapshot is captured before each successful mutation. Rollback is
/// conservative: a file is restored only when its current content still
/// matches the state the agent last wrote. This prevents rollback from
/// overwriting edits made by the user or another process after the agent step.
class AgentTransaction {
  AgentTransaction({
    required BackendService backend,
    required String workspaceRoot,
  })  : _backend = backend,
        _workspaceRoot = workspaceRoot;

  static const int _maxSnapshotFiles = 4096;
  static const int _maxSnapshotBytes = 64 * 1024 * 1024;

  final BackendService _backend;
  final String _workspaceRoot;

  final LinkedHashMap<String, String?> _originalFiles =
      LinkedHashMap<String, String?>();
  final LinkedHashSet<String> _originalDirectories =
      LinkedHashSet<String>();
  final LinkedHashSet<String> _expectedDirectories =
      LinkedHashSet<String>();
  final LinkedHashMap<String, String?> _expectedFiles =
      LinkedHashMap<String, String?>();

  bool _closed = false;

  bool get hasChanges =>
      _originalFiles.isNotEmpty ||
      _originalDirectories.isNotEmpty ||
      _expectedDirectories.isNotEmpty;

  List<String> get trackedFiles =>
      List.unmodifiable(_originalFiles.keys.toList());

  Future<void> captureBeforeMutation(String path) async {
    _ensureOpen();
    final relative = _normalize(path);
    if (_isTracked(relative)) return;

    final read = await _backend.executeAgentTool(
      'file.read',
      {'path': relative},
      workspaceRoot: _workspaceRoot,
    );

    if (read.ok) {
      _originalFiles[relative] = read.output;
      _expectedFiles[relative] = read.output;
      return;
    }

    final entries = await _backend.workspaceTree(
      _workspaceRoot,
      maxEntries: 50000,
    );
    WorkspaceFile? exact;
    for (final entry in entries) {
      if (entry.path == relative) {
        exact = entry;
        break;
      }
    }

    if (exact == null) return;

    if (!exact.isDirectory) {
      throw StateError(
        'Unable to snapshot "${relative}" before mutation: ${read.error}',
      );
    }

    final prefix = relative == '.' ? '' : '${relative}/';
    var fileCount = 0;
    var totalBytes = 0;

    for (final entry in entries) {
      final inside = relative == '.'
          ? true
          : entry.path == relative || entry.path.startsWith(prefix);
      if (!inside) continue;

      if (entry.isDirectory) {
        _originalDirectories.add(entry.path);
        continue;
      }

      fileCount++;
      totalBytes += entry.size;
      if (fileCount > _maxSnapshotFiles ||
          totalBytes > _maxSnapshotBytes) {
        throw StateError(
          'Refusing to mutate "${relative}": rollback snapshot exceeds '
          'the ${_maxSnapshotFiles}-file / ${_maxSnapshotBytes}-byte safety limit.',
        );
      }

      final fileRead = await _backend.executeAgentTool(
        'file.read',
        {'path': entry.path},
        workspaceRoot: _workspaceRoot,
      );
      if (!fileRead.ok) {
        throw StateError(
          'Unable to snapshot "${entry.path}" before directory mutation: '
          '${fileRead.error}',
        );
      }

      _originalFiles[entry.path] = fileRead.output;
      _expectedFiles[entry.path] = fileRead.output;
    }

    _originalDirectories.add(relative);
  }

  Future<void> recordWrite(String path, String content) async {
    _ensureOpen();
    final relative = _normalize(path);
    await _captureParentDirectories(relative);
    await captureBeforeMutation(relative);

    if (!_originalFiles.containsKey(relative)) {
      _originalFiles[relative] = null;
    }

    _expectedFiles[relative] = content;
    _expectedDirectories.remove(relative);

    for (final parent in _parentPaths(relative)) {
      if (!_originalDirectories.contains(parent)) {
        _expectedDirectories.add(parent);
      }
    }
  }

  Future<void> recordDelete(String path) async {
    _ensureOpen();
    final relative = _normalize(path);
    await captureBeforeMutation(relative);

    if (_originalFiles.containsKey(relative)) {
      _expectedFiles[relative] = null;
      return;
    }

    if (_originalDirectories.contains(relative)) {
      _expectedDirectories.remove(relative);
      final prefix = relative == '.' ? '' : '${relative}/';
      for (final pathKey in _originalFiles.keys) {
        if (relative == '.' || pathKey.startsWith(prefix)) {
          _expectedFiles[pathKey] = null;
        }
      }
    }
  }

  Future<void> recordDirectoryCreate(String path) async {
    _ensureOpen();
    final relative = _normalize(path);
    await captureBeforeMutation(relative);

    if (_originalFiles.containsKey(relative)) {
      throw StateError(
        'Cannot treat "${relative}" as a directory; it is a file.',
      );
    }
    _expectedDirectories.add(relative);
  }

  Future<void> recordPatchedFile(String path) async {
    _ensureOpen();
    final relative = _normalize(path);
    await captureBeforeMutation(relative);

    if (_originalDirectories.contains(relative)) {
      throw StateError('Cannot patch directory "${relative}".');
    }

    final result = await _backend.executeAgentTool(
      'file.read',
      {'path': relative},
      workspaceRoot: _workspaceRoot,
    );
    if (!result.ok) {
      throw StateError(
        'Unable to record the post-patch state for "${relative}": '
        '${result.error}',
      );
    }
    _expectedFiles[relative] = result.output;
  }

  void commit() {
    _closed = true;
    _originalFiles.clear();
    _originalDirectories.clear();
    _expectedDirectories.clear();
    _expectedFiles.clear();
  }

  Future<AgentRollbackReport> rollback() async {
    if (_closed) return const AgentRollbackReport.empty();

    if (!hasChanges) {
      _closed = true;
      return const AgentRollbackReport.empty();
    }

    _closed = true;
    var restored = 0;
    var skipped = 0;
    final errors = <String>[];

    List<WorkspaceFile> currentEntries;
    try {
      currentEntries = await _backend.workspaceTree(
        _workspaceRoot,
        maxEntries: 50000,
      );
    } catch (error) {
      return AgentRollbackReport(
        restored: 0,
        skipped: _originalFiles.length + _expectedDirectories.length,
        errors: ['Unable to inspect current workspace state: \$error'],
      );
    }

    final currentFiles = <String>{};
    final currentDirectories = <String>{};
    for (final entry in currentEntries) {
      (entry.isDirectory ? currentDirectories : currentFiles).add(entry.path);
    }

    final directories = _originalDirectories.toList()
      ..sort((a, b) => _depth(a).compareTo(_depth(b)));
    for (final path in directories) {
      if (currentDirectories.contains(path)) continue;
      if (currentFiles.contains(path)) {
        skipped++;
        errors.add('\$path: a file occupies the original directory path');
        continue;
      }

      final result = await _backend.executeAgentTool(
        'file.mkdir',
        {'path': path},
        workspaceRoot: _workspaceRoot,
      );
      if (result.ok) {
        restored++;
        currentDirectories.add(path);
      } else {
        skipped++;
        errors.add(
          '\$path: rollback directory restore failed: ${result.error}',
        );
      }
    }

    for (final path in _originalFiles.keys.toList().reversed) {
      final original = _originalFiles[path];
      final expected = _expectedFiles[path];

      final currentResult = await _backend.executeAgentTool(
        'file.read',
        {'path': path},
        workspaceRoot: _workspaceRoot,
      );
      final currentExists = currentResult.ok;
      final current = currentExists ? currentResult.output : null;

      try {
        if (original == null) {
          if (expected == null) {
            if (!currentExists) continue;
            skipped++;
            errors.add('\$path: current file exists unexpectedly');
            continue;
          }

          if (!currentExists || current != expected) {
            skipped++;
            errors.add('\$path: current file differs from agent state');
            continue;
          }

          final deleted = await _backend.executeAgentTool(
            'file.delete',
            {'path': path},
            workspaceRoot: _workspaceRoot,
          );
          if (!deleted.ok) {
            skipped++;
            errors.add('\$path: rollback delete failed: ${deleted.error}');
            continue;
          }
          restored++;
          currentFiles.remove(path);
          continue;
        }

        if (expected == null) {
          if (currentExists && current != expected) {
            skipped++;
            errors.add('\$path: current file differs from expected deletion');
            continue;
          }
          if (!currentExists) {
            final write = await _backend.executeAgentTool(
              'file.write',
              {'path': path, 'content': original},
              workspaceRoot: _workspaceRoot,
            );
            if (!write.ok) {
              skipped++;
              errors.add('\$path: rollback write failed: ${write.error}');
              continue;
            }
            restored++;
            continue;
          }
        } else {
          if (!currentExists || current != expected) {
            skipped++;
            errors.add('\$path: current file differs from agent state');
            continue;
          }
          final write = await _backend.executeAgentTool(
            'file.write',
            {'path': path, 'content': original},
            workspaceRoot: _workspaceRoot,
          );
          if (!write.ok) {
            skipped++;
            errors.add('\$path: rollback write failed: ${write.error}');
            continue;
          }
          restored++;
        }
      } catch (error) {
        skipped++;
        errors.add('\$path: \$error');
      }
    }

    final createdDirs = _expectedDirectories.toList()
      ..sort((a, b) => _depth(b).compareTo(_depth(a)));
    for (final path in createdDirs) {
      if (path == '.') continue;

      final entries = await _backend.executeAgentTool(
        'file.list',
        {'path': path},
        workspaceRoot: _workspaceRoot,
      );
      if (!entries.ok) {
        if (_isNotFound(entries.error)) continue;
        skipped++;
        errors.add(
          '\$path: unable to inspect created directory: ${entries.error}',
        );
        continue;
      }

      if (!_isEmptyDirectoryJson(entries.output)) {
        skipped++;
        errors.add('\$path: created directory is no longer empty');
        continue;
      }

      final deleted = await _backend.executeAgentTool(
        'file.delete',
        {'path': path},
        workspaceRoot: _workspaceRoot,
      );
      if (deleted.ok) {
        restored++;
      } else {
        skipped++;
        errors.add(
          '\$path: rollback directory delete failed: ${deleted.error}',
        );
      }
    }

    return AgentRollbackReport(
      restored: restored,
      skipped: skipped,
      errors: List.unmodifiable(errors),
    );
  }

  Future<void> _captureParentDirectories(String relative) async {
    for (final parent in _parentPaths(relative)) {
      await captureBeforeMutation(parent);
    }
  }

  List<String> _parentPaths(String relative) {
    final slash = relative.lastIndexOf('/');
    if (slash <= 0) return const [];

    final parents = <String>[];
    var current = relative.substring(0, slash);
    while (current.isNotEmpty && current != '.') {
      parents.add(current);
      final nextSlash = current.lastIndexOf('/');
      if (nextSlash <= 0) break;
      current = current.substring(0, nextSlash);
    }
    parents.sort((a, b) => _depth(a).compareTo(_depth(b)));
    return parents;
  }

  bool _isTracked(String relative) {
    return _originalFiles.containsKey(relative) ||
        _originalDirectories.contains(relative) ||
        _expectedDirectories.contains(relative);
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('Agent transaction is already closed.');
    }
  }

  String _normalize(String raw) {
    var value = raw.trim().replaceAll('\\', '/');
    while (value.startsWith('./')) {
      value = value.substring(2);
    }
    if (value.isEmpty) return '.';
    return value;
  }

  static int _depth(String path) => path == '.'
      ? 0
      : path.split('/').where((segment) => segment.isNotEmpty).length;

  static bool _isEmptyDirectoryJson(String value) {
    try {
      final decoded = jsonDecode(value);
      return decoded is List && decoded.isEmpty;
    } catch (_) {
      return false;
    }
  }

  static bool _isNotFound(String error) {
    final lower = error.toLowerCase();
    return lower.contains('file not found') ||
        lower.contains('not found inside workspace') ||
        lower.contains('does not exist') ||
        lower.contains('no such file');
  }
}

class AgentRollbackReport {
  const AgentRollbackReport({
    required this.restored,
    required this.skipped,
    required this.errors,
  });

  const AgentRollbackReport.empty()
      : restored = 0,
        skipped = 0,
        errors = const [];

  final int restored;
  final int skipped;
  final List<String> errors;

  bool get complete => skipped == 0;
  bool get hasChanges => restored > 0 || skipped > 0;
}
