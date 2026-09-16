import 'package:flutter_riverpod/flutter_riverpod.dart';

export 'command_history.dart';
export 'conflict_tracker.dart';
export 'event_bus.dart';
export 'ide_runtime.dart';
export 'notification_center.dart';
export 'performance_monitor.dart';
export 'recovery_journal.dart';
export 'retry_queue.dart';
export 'save_coordinator.dart';
export 'workspace_session.dart';

final appEventBusProvider = Provider<AppEventBus<Object>>((ref) {
  final bus = AppEventBus<Object>();
  ref.onDispose(bus.close);
  return bus;
});

final commandHistoryProvider = Provider<CommandHistory>((ref) {
  return CommandHistory(capacity: 100);
});

final saveCoordinatorProvider = Provider<SaveCoordinator>((ref) {
  final coordinator = SaveCoordinator();
  ref.onDispose(() => coordinator.dispose());
  return coordinator;
});

final conflictTrackerProvider = Provider<ConflictTracker>((ref) {
  final tracker = ConflictTracker();
  ref.onDispose(tracker.clear);
  return tracker;
});

final retryQueueProvider = Provider<RetryQueue>((ref) {
  final queue = RetryQueue();
  ref.onDispose(queue.dispose);
  return queue;
});

final recoveryJournalProvider = Provider<RecoveryJournal>((ref) => RecoveryJournal());
final performanceMonitorProvider = Provider<PerformanceMonitor>((ref) => PerformanceMonitor());

final notificationCenterProvider = Provider<NotificationCenter>((ref) {
  final center = NotificationCenter();
  ref.onDispose(center.clear);
  return center;
});

final workspaceSessionStoreProvider = Provider<WorkspaceSessionStore>((ref) {
  return WorkspaceSessionStore();
});

final ideRuntimeProvider = Provider<IdeRuntime>((ref) {
  final runtime = IdeRuntime(
    events: ref.read(appEventBusProvider),
    commands: ref.read(commandHistoryProvider),
    saves: ref.read(saveCoordinatorProvider),
    conflicts: ref.read(conflictTrackerProvider),
    retries: ref.read(retryQueueProvider),
    recovery: ref.read(recoveryJournalProvider),
    performance: ref.read(performanceMonitorProvider),
    notifications: ref.read(notificationCenterProvider),
    session: ref.read(workspaceSessionStoreProvider),
  );
  ref.onDispose(runtime.dispose);
  return runtime;
});
