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
    tracker.detect(
      path: 'lib/main.dart',
      diskContent: 'disk',
      editorContent: 'local',
    );
    expect(tracker.has('lib/main.dart'), isTrue);

    tracker.detect(
      path: 'lib/main.dart',
      diskContent: 'same',
      editorContent: 'same',
    );
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
    final coordinator = SaveCoordinator(
      delay: const Duration(milliseconds: 1),
      maxWait: const Duration(milliseconds: 10),
    );
    var saves = 0;
    coordinator.schedule(() async => saves++);
    coordinator.schedule(() async => saves++);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await coordinator.dispose();
    expect(saves, 1);
  });

  test('retry queue propagates terminal failures', () async {
    final queue = RetryQueue(
      policy: const RetryPolicy(
        maxAttempts: 3,
        baseDelay: Duration(milliseconds: 1),
        maxDelay: Duration(milliseconds: 2),
      ),
    );
    var attempts = 0;
    await expectLater(
      queue.enqueue(() async {
        attempts++;
        throw StateError('retry');
      }),
      throwsStateError,
    );
    expect(attempts, 3);
    await queue.dispose();
  });

  test('retry queue completes successfully after transient failures', () async {
    final queue = RetryQueue(
      policy: const RetryPolicy(
        maxAttempts: 3,
        baseDelay: Duration(milliseconds: 1),
        maxDelay: Duration(milliseconds: 2),
      ),
    );
    var attempts = 0;
    await queue.enqueue(() async {
      attempts++;
      if (attempts < 3) throw StateError('transient');
    });
    expect(attempts, 3);
    await queue.dispose();
  });
}
