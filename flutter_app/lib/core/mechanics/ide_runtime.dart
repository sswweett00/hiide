import 'dart:async';

import 'mechanics.dart';

/// Coordinates the production lifecycle of editor/workspace operations.
///
/// The coordinator is intentionally UI-agnostic: screens can call the same
/// methods and observe the event/notification stores without duplicating
/// retry, recovery, conflict, or performance policy.
class IdeRuntime {
  IdeRuntime({
    required this.events,
    required this.commands,
    required this.saves,
    required this.conflicts,
    required this.retries,
    required this.recovery,
    required this.performance,
    required this.notifications,
    required this.session,
  });

  final AppEventBus<Object> events;
  final CommandHistory commands;
  final SaveCoordinator saves;
  final ConflictTracker conflicts;
  final RetryQueue retries;
  final RecoveryJournal recovery;
  final PerformanceMonitor performance;
  final NotificationCenter notifications;
  final WorkspaceSessionStore session;

  bool _disposed = false;

  /// Saves content with one bounded retry envelope and journals the latest
  /// content before the write starts. Successful writes clear the recovery
  /// record; failures remain recoverable and are surfaced to the notification
  /// center without throwing away the user's latest buffer.
  Future<bool> saveFile({
    required String path,
    required String content,
    required Future<void> Function() write,
  }) async {
    if (_disposed) return false;

    recovery.put(path, content);
    final started = DateTime.now();
    var success = false;
    Object? failure;

    try {
      await performance.measureAsync('file.save', () async {
        final completer = Completer<void>();
        retries.enqueue(() async {
          try {
            await write();
            if (!completer.isCompleted) completer.complete();
          } catch (error, stack) {
            failure = error;
            if (retries.policy.maxAttempts <= 0 && !completer.isCompleted) {
              completer.completeError(error, stack);
            }
            rethrow;
          }
        });
        await completer.future;
      });
      success = true;
      recovery.remove(path);
      conflicts.clear(path);
      notifications.dismiss('save:$path');
    } catch (error) {
      failure = error;
    }

    commands.add(CommandRecord(
      id: 'save:$path:${started.microsecondsSinceEpoch}',
      label: 'Save ${path.split('/').last}',
      startedAt: started,
      duration: DateTime.now().difference(started),
      success: success,
    ));

    if (success) {
      events.emit(IdeRuntimeEvent.saved(path));
      return true;
    }

    final message = failure?.toString() ?? 'Unknown save error';
    notifications.publish(
      id: 'save:$path',
      title: 'Save failed',
      message: '$path could not be saved. Your recovery copy was kept.',
      level: NotificationLevel.error,
      persistent: true,
    );
    events.emit(IdeRuntimeEvent.saveFailed(path, message));
    return false;
  }

  /// Records an external disk change against the current editor buffer.
  /// Identical states are ignored; divergent states create one conflict.
  void reconcileExternalChange({
    required String path,
    required String diskContent,
    required String editorContent,
  }) {
    if (_disposed) return;
    final conflict = conflicts.detect(
      path: path,
      diskContent: diskContent,
      editorContent: editorContent,
    );
    if (conflict == null) {
      notifications.dismiss('conflict:$path');
      return;
    }
    notifications.publish(
      id: 'conflict:$path',
      title: 'External change detected',
      message: '$path changed on disk while you have local edits.',
      level: NotificationLevel.warning,
      persistent: true,
    );
    events.emit(IdeRuntimeEvent.conflict(path));
  }

  void rememberWorkspace(WorkspaceSession snapshot) {
    if (_disposed) return;
    session.set(snapshot);
    events.emit(IdeRuntimeEvent.workspaceChanged(snapshot.root));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await saves.dispose(flushPending: false);
    await retries.dispose();
  }
}

sealed class IdeRuntimeEvent {
  const IdeRuntimeEvent();

  const factory IdeRuntimeEvent.saved(String path) = IdeSavedEvent;
  const factory IdeRuntimeEvent.saveFailed(String path, String message) =
      IdeSaveFailedEvent;
  const factory IdeRuntimeEvent.conflict(String path) = IdeConflictEvent;
  const factory IdeRuntimeEvent.workspaceChanged(String root) =
      IdeWorkspaceChangedEvent;
}

final class IdeSavedEvent extends IdeRuntimeEvent {
  const IdeSavedEvent(this.path);
  final String path;
}

final class IdeSaveFailedEvent extends IdeRuntimeEvent {
  const IdeSaveFailedEvent(this.path, this.message);
  final String path;
  final String message;
}

final class IdeConflictEvent extends IdeRuntimeEvent {
  const IdeConflictEvent(this.path);
  final String path;
}

final class IdeWorkspaceChangedEvent extends IdeRuntimeEvent {
  const IdeWorkspaceChangedEvent(this.root);
  final String root;
}
