import 'dart:async';

import 'mechanics.dart';

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

  Future<bool> saveFile({
    required String path,
    required String content,
    required Future<void> Function() write,
  }) async {
    if (_disposed) return false;

    final started = DateTime.now();
    var success = false;

    try {
      await recovery.put(path, content);
      await performance.measureAsync('file.save', () => retries.enqueue(write));
      success = true;
      await recovery.remove(path);
      conflicts.resolve(path);
      notifications.dismiss('save:$path');
      events.emit(IdeSavedEvent(path));
    } catch (error) {
      notifications.publish(
        id: 'save:$path',
        title: 'Save failed',
        message: '$path could not be saved. Your recovery copy was kept.',
        level: AppNotificationLevel.error,
        persistent: true,
      );
      events.emit(IdeSaveFailedEvent(path, error.toString()));
    }

    commands.add(CommandRecord(
      id: 'save:$path:${started.microsecondsSinceEpoch}',
      label: 'Save ${path.split('/').last}',
      startedAt: started,
      duration: DateTime.now().difference(started),
      success: success,
    ));

    return success;
  }

  void reconcileExternalChange({
    required String path,
    required String diskContent,
    required String editorContent,
  }) {
    if (_disposed) return;
    conflicts.detect(
      path: path,
      diskContent: diskContent,
      editorContent: editorContent,
    );
    if (!conflicts.has(path)) {
      notifications.dismiss('conflict:$path');
      return;
    }
    notifications.publish(
      id: 'conflict:$path',
      title: 'External change detected',
      message: '$path changed on disk while you have local edits.',
      level: AppNotificationLevel.warning,
      persistent: true,
    );
    events.emit(IdeConflictEvent(path));
  }

  void rememberWorkspace(WorkspaceSession snapshot) {
    if (_disposed) return;
    session.set(snapshot);
    events.emit(IdeWorkspaceChangedEvent(snapshot.root));
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
