import 'package:flutter_test/flutter_test.dart';

import 'package:hiide_flutter/core/mechanics/mechanics.dart';

void main() {
  test('command history stays bounded and most recent first', () {
    final history = CommandHistory(capacity: 2);
    final now = DateTime(2026, 1, 1);
    for (final id in ['a', 'b', 'c']) {
      history.add(CommandRecord(
        id: id,
        label: id.toUpperCase(),
        startedAt: now,
        duration: Duration.zero,
        success: true,
      ));
    }
    expect(history.items.map((e) => e.id), ['c', 'b']);
  });

  test('conflict tracker clears identical disk/editor state', () {
    final tracker = ConflictTracker();
    tracker.detect(path: 'lib/main.dart', diskContent: 'disk', editorContent: 'local');
    expect(tracker.has('lib/main.dart'), isTrue);
    tracker.detect(path: 'lib/main.dart', diskContent: 'same', editorContent: 'same');
    expect(tracker.has('lib/main.dart'), isFalse);
  });

  test('performance monitor records success and failure', () async {
    final monitor = PerformanceMonitor();
    expect(monitor.measure('sync', () => 42), 42);
    await expectLater(
      monitor.measureAsync('async-failure', () async => throw StateError('x')),
      throwsStateError,
    );
    expect(monitor.statsFor('sync')?.count, 1);
    expect(monitor.statsFor('async-failure')?.failures, 1);
  });

  test('notification center deduplicates ids', () {
    final center = NotificationCenter(capacity: 2);
    center.publish(id: 'x', title: 'Old', message: '1');
    center.publish(id: 'x', title: 'New', message: '2', persistent: true);
    center.publish(id: 'y', title: 'Y', message: '3');
    expect(center.items.length, 2);
    expect(center.items.first.title, 'Y');
    expect(center.items.last.message, '2');
    expect(center.unreadCount, 1);
  });

  test('save coordinator coalesces rapid schedules', () async {
    final coordinator = SaveCoordinator(delay: const Duration(milliseconds: 1), maxWait: const Duration(milliseconds: 10));
    var saves = 0;
    coordinator.schedule(() async => saves++);
    coordinator.schedule(() async => saves++);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await coordinator.dispose();
    expect(saves, 1);
  });

  test('retry queue propagates terminal failures', () async {
    final queue = RetryQueue(policy: const RetryPolicy(maxAttempts: 3, baseDelay: Duration(milliseconds: 1), maxDelay: Duration(milliseconds: 2)));
    var attempts = 0;
    await expectLater(queue.enqueue(() async { attempts++; throw StateError('retry'); }), throwsStateError);
    expect(attempts, 3);
    await queue.dispose();
  });

  test('retry queue completes successfully after transient failures', () async {
    final queue = RetryQueue(policy: const RetryPolicy(maxAttempts: 3, baseDelay: Duration(milliseconds: 1), maxDelay: Duration(milliseconds: 2)));
    var attempts = 0;
    await queue.enqueue(() async {
      attempts++;
      if (attempts < 3) throw StateError('transient');
    });
    expect(attempts, 3);
    await queue.dispose();
  });

  test('cancellation token cancels a raced operation', () async {
    final token = CancellationToken();
    final operation = token.race(Future<void>.delayed(const Duration(seconds: 1)));
    token.cancel();
    await expectLater(operation, throwsA(isA<CancellationException>()));
    await token.dispose();
  });

  test('idempotency store shares concurrent work', () async {
    final store = IdempotencyStore<int>(capacity: 4, ttl: const Duration(seconds: 1));
    var executions = 0;
    final first = store.run('same', () async {
      executions++;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return 7;
    });
    final second = store.run('same', () async {
      executions++;
      return 9;
    });
    expect(await first, 7);
    expect(await second, 7);
    expect(executions, 1);
  });

  test('circuit breaker opens after threshold and resets after a success', () async {
    final breaker = CircuitBreaker(failureThreshold: 2, resetTimeout: const Duration(milliseconds: 10));
    await expectLater(breaker.run(() async => throw StateError('x')), throwsStateError);
    await expectLater(breaker.run(() async => throw StateError('x')), throwsStateError);
    expect(breaker.state, CircuitState.open);
    await Future<void>.delayed(const Duration(milliseconds: 12));
    expect(await breaker.run(() async => 42), 42);
    expect(breaker.state, CircuitState.closed);
  });

  test('ttl cache expires entries and stays bounded', () async {
    final cache = TtlCache<String, int>(capacity: 2, ttl: const Duration(milliseconds: 5));
    cache.set('a', 1);
    cache.set('b', 2);
    cache.set('c', 3);
    expect(cache.get('a'), isNull);
    expect(cache.get('c'), 3);
    await Future<void>.delayed(const Duration(milliseconds: 8));
    expect(cache.get('c'), isNull);
  });

  test('rate limiter rejects excess events within a window', () async {
    final limiter = SlidingWindowRateLimiter(maxEvents: 2, window: const Duration(milliseconds: 20));
    expect(limiter.tryAcquire(), isTrue);
    expect(limiter.tryAcquire(), isTrue);
    expect(limiter.tryAcquire(), isFalse);
    expect(limiter.retryAfter, greaterThan(Duration.zero));
  });

  test('resource lease prevents duplicate ownership and supports renewal', () {
    final manager = ResourceLeaseManager(defaultTtl: const Duration(milliseconds: 20));
    final first = manager.acquire('editor:file.dart');
    expect(manager.isHeld('editor:file.dart'), isTrue);
    expect(() => manager.acquire('editor:file.dart'), throwsA(isA<LeaseUnavailableException>()));
    expect(first.renew(), isTrue);
    first.release();
    expect(manager.isHeld('editor:file.dart'), isFalse);
  });

  test('worker pool enforces concurrency and completes work', () async {
    final pool = WorkerPool(concurrency: 1, maxQueue: 2);
    final order = <int>[];
    final a = pool.submit(() async {
      order.add(1);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      return 1;
    });
    final b = pool.submit(() async {
      order.add(2);
      return 2;
    });
    expect(await a, 1);
    expect(await b, 2);
    expect(order, [1, 2]);
    await pool.dispose();
  });

  test('state machine emits valid transitions', () async {
    final machine = StateMachine<String, String>(
      initialState: 'idle',
      transitions: {
        String: (state, event) => event,
      },
    );
    final states = <String>[];
    final subscription = machine.changes.listen(states.add);
    machine.dispatch('working');
    machine.dispatch('done');
    await Future<void>.delayed(Duration.zero);
    expect(states, ['working', 'done']);
    await subscription.cancel();
    await machine.dispose();
  });

  test('health monitor records probe failure and success', () async {
    final monitor = HealthMonitor(timeout: const Duration(milliseconds: 20));
    monitor.register('engine', () async {});
    monitor.register('provider', () async => throw StateError('down'));
    final snapshots = await monitor.checkAll();
    expect(snapshots.firstWhere((s) => s.name == 'engine').state, HealthState.healthy);
    expect(snapshots.firstWhere((s) => s.name == 'provider').state, HealthState.unhealthy);
  });

  test('error taxonomy maps retryable infrastructure failures', () {
    final failure = HiideFailure.from(const RateLimitException(Duration(seconds: 1)));
    expect(failure.code, FailureCode.rateLimited);
    expect(failure.retryable, isTrue);
  });

  test('backpressure queue is bounded and drains in FIFO order', () async {
    final queue = BackpressureQueue<int>(capacity: 2);
    queue.add(1);
    queue.add(2);
    expect(queue.tryAdd(3), isFalse);
    expect(await queue.take(), 1);
    expect(await queue.take(), 2);
    queue.close();
  });
}
