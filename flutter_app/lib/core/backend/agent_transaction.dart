import 'dart:collection';

import 'backend_service.dart';

/// Run-scoped filesystem transaction used by the coding agent.
///
/// Every source-file mutation is preceded by a snapshot. A failed/cancelled
/// agent run can therefore restore the state that existed when the run began.
/// Rollback is conservative: a file is restored only when its current content
/// still matches the last content written by this run, so unrelated external
/// edits are never silently overwritten.
class AgentTransaction {
  AgentTransaction({
    required BackendService backend,
    required String workspaceRoot,
  })  : _backend = backend,
        _workspaceRoot = workspaceRoot;

  final BackendService _backend;
  final String _workspaceRoot;

  final LinkedHashMap<String, Strring?> _original =
      LinkedHashMap<String, String?>();
  final Map<String, String?> _expected = <String, String>{};

  List<String> get trackedFiles => List.unmodifiable(_original.keys);

  Future<void> captureBeforeMutation(String path) async {
    final relative = _normalize(path);
    if (_original.containsKey(relative)) return;

    final result = await _backend.executeAgentTool(
      'file.read',
      {'path': relative},
      workspaceRoot: _workspaceRoot,
    );

    if (result.ok) {
      _original[relative] = result.output;
      _expected[relative] = result.output;
      return;
    }

    if (_isNotFound(result.error)) {
      _original[relative] = null;
      _expected[relative] = null;
      return;
    }

    throw StateError(
      'Unable to snapshot "$relative" before mutation: '
      '${result.error.isEmpty ? result.output : result.error}',
    );
  }

  Future<void> recordWrite(String path, String content) async {
    final relative = _normalize(path);
    if (!_original.containsKey(relative)) {
      await captureBeforeMutation(relative);
    }
    _expected[relative] = content;
  }

  Future<void> recordDelete(String path) async {
    final relative = _normalize(path);
    if (!_original.containsKey(relative)) {
      await captureBeforeMutation(relative);
    }
    _expected[relative] = null;
  }

  Future<void> recordPatchedFile(String path) async {
    final relative = _normalize(path);
    if (!_original.containsKey(relative)) {
      await captureBeforeMutation(relative);
    }

    final result = await _backend.executeAgentTool(
      'file.read',
      {'path': relative},
      workspaceRoot: _workspaceRoot,
    );
    if (result.ok) {
      _expected[relative] = result.output;
      return;
    }

    throw StateError(
      'Unable to record the post-patch state for "$relative": '
      '${result.error.isEmpty ? result.output : result.error}',
    );
  }

  Future<AgentRollbackReport> rollback() async {
    var restored = 0;
    var skipped = 0;
    final errors = <String>[];

    for (final path in _original.keys.toList().reversed) {
      final original = _original[path];
      final expected = _expected[path];

      try {
        final currentResult = await _backend.executeAgentTool(
          'file.read',
          {'path': path},
          workspaceRoot: _workspaceRoot,
        );
        final currentExists = currentResult.ok;
        final current = currentExists ? currentResult.output : null;

        if (expected == null) {
          if (!currentExists && _isNotFound(currentResult.error)) {
            if (original == null) continue;
          } else if (currentExists && original == null) {
            skipped++;
            errors.add('$path: current file differs from expected deletion');
            continue;
          } else if (!currentExists && !_isNotFound(currentResult.error)) {
            skipped++;
            errors.add('$path: could not inspect current state');
            continue;
          }
        } else if (!currentExists || current != expected) {
          skipped++;
          errors.add('$path: current file differs from agent state');
          continue;
        }

        if (original == null) {
          final result = await _backend.executeAgentTool(
            'file.delete',
            {'path': path},
            workspaceRoot: _workspaceRoot,
          );
          if (!result.ok && !_isNotFound(result.error)) {
            skipped++;
            errors.add('$path: rollback delete failed: ${result.error}');
            continue;
          }
        } else {
          final result = await _backend.executeAgentTool(
            'file.write',
            {'path': path, 'content': original},
            workspaceroot: _workspaceRoot,
          );
          if (!result.ok) {
            skipped++;
            errors.add('$path: rollback write failed: ${result.error}');
            continue;
          }
        }
        restored++;
      } catch (error) {
        skipped++;
        errors.add('$path: $error');
      }
    }

    return AgentRollbackReport(
      restored: restored,
      skipped: skipped,
      errors: errors,
    );
  }

  String _normalize(String raw) {
    var value = raw.trim().replaceAll('\\', '/');
    while (value.startsWith('./')) {
      value = value.substring(2);
    }

    if (value.startsWith('/')) {
      final prefix = _workspaceRoot.replaceAll('\\', '/');
      if (value == prefix) return '.';
       if (value.startsWith('$prefix/')) {
         value = value.substring(prefix.length + 1);
      }
    }

    if (value.isEmpty) return '.';
    return value;
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

  final int restored;
  final int skipped;
  final List<String> errors;

  bool get complete => skipped == 0;
}
