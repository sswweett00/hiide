import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backpressure_queue.dart';
import 'cancellation_token.dart';
import 'circuit_breaker.dart';
import 'command_history.dart';
import 'conflict_tracker.dart';
import 'error_taxonomy.dart';
import 'event_bus.dart';
import 'health_monitor.dart';
import 'ide_runtime.dart';
import 'idempotency_store.dart';
import 'notification_center.dart';
import 'performance_monitor.dart';
import 'rate_limiter.dart';
import 'recovery_journal.dart';
import 'resource_lease.dart';
import 'retry_queue.dart';
import 'save_coordinator.dart';
import 'state_machine.dart';
import 'ttl_cache.dart';
import 'worker_pool.dart';
import 'workspace_session.dart';

export 'backpressure_queue.dart';
export 'cancellation_token.dart';
export 'circuit_breaker.dart';
export 'command_history.dart';
export 'conflict_tracker.dart';
export 'error_taxonomy.dart';
export 'event_bus.dart';
export 'health_monitor.dart';
export 'ide_runtime.dart';
export 'idempotency_store.dart';
export 'notification_center.dart';
export 'performance_monitor.dart';
export 'rate_limiter.dart';
export 'recovery_journal.dart';
export 'resource_lease.dart';
export 'retry_queue.dart';
export 'save_coordinator.dart';
export 'state_machine.dart';
export 'ttl_cache.dart';
export 'worker_pool.dart';
export 'workspace_session.dart';

final appEventBusProvider = Provider<AppEventBus<Object>>((ref) {
  final bus = AppEventBus<Object>();
  ref.onDispose(bus.close);
  return bus;
});

final commandHistoryProvider = Provider<CommandHistory>((ref) =>
    CommandHistory(capacity: 100));

final saveCoordinatorProvider = Provider<SaveCoordinator>((ref) {
  final coordinator = SaveCoordinator();
  ref.onDispose(coordinator.dispose);
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

final recoveryJournalProvider = Provider<RecoveryJournal>((ref) =>
    RecoveryJournal());
final performanceMonitorProvider = Provider<PerformanceMonitor>((ref) =>
    PerformanceMonitor());

final notificationCenterProvider = Provider<NotificationCenter>((ref) {
  final center = NotificationCenter();
  ref.onDispose(center.clear);
  return center;
});

final workspaceSessionStoreProvider = Provider<WorkspaceSessionStore>((ref) =>
    WorkspaceSessionStore());

final cancellationTokenProvider = Provider<CancellationToken>((ref) {
  final token = CancellationToken();
  ref.onDispose(token.dispose);
  return token;
});

final idempotencyStoreProvider = Provider<IdempotencyStore<Object?>>((ref) {
  final store = IdempotencyStore<Object?>();
  ref.onDispose(store.clear);
  return store;
});

final circuitBreakerProvider = Provider<CircuitBreaker>((ref) =>
    CircuitBreaker());

final cacheProvider = Provider<TtlCache<String, Object?>>((ref) {
  final cache = TtlCache<String, Object?>();
  ref.onDispose(cache.clear);
  return cache;
});

final rateLimiterProvider = Provider<SlidingWindowRateLimiter>((ref) =>
    SlidingWindowRateLimiter(
      maxEvents: 20,
      window: const Duration(seconds: 1),
    ));

final resourceLeaseProvider = Provider<ResourceLeaseManager>((ref) {
  final manager = ResourceLeaseManager();
  ref.onDispose(manager.clear);
  return manager;
});

final workerPoolProvider = Provider<WorkerPool>((ref) {
  final pool = WorkerPool();
  ref.onDispose(pool.dispose);
  return pool;
});

final healthMonitorProvider = Provider<HealthMonitor>((ref) => HealthMonitor());

final backpressureQueueProvider = Provider<BackpressureQueue<Object?>>((ref) {
  final queue = BackpressureQueue<Object?>();
  ref.onDispose(queue.close);
  return queue;
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
