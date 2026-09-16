import 'dart:async';

class RetryPolicy {
  final int maxAttempts;
  final Duration baseDelay;
  final Duration maxDelay;

  const RetryPolicy({
    this.maxAttempts = 4,
    this.baseDelay = const Duration(milliseconds: 250),
    this.maxDelay = const Duration(seconds: 5),
  });
}

class RetryQueue {
  RetryQueue({this.policy = const RetryPolicy(), this.concurrency = 1})
      : assert(concurrency > 0);

  final RetryPolicy policy;
  final int concurrency;
  final List<Future<void> Function()> _queue = <Future<void> Function()>[];
  int _running = 0;
  bool _disposed = false;

  int get pending => _queue.length;

  void enqueue(Future<void> Function() task) {
    if (_disposed) return;
    _queue.add(task);
    _drain();
  }

  Future<void> _drain() async {
    while (!_disposed && _running < concurrency && _queue.isNotEmpty) {
      final task = _queue.removeAt(0);
      _running++;
      unawaited(_run(task).whenComplete(() {
        _running--;
        _drain();
      }));
    }
  }

  Future<void> _run(Future<void> Function() task) async {
    Object? lastError;
    for (var attempt = 1; attempt <= policy.maxAttempts; attempt++) {
      try {
        await task();
        return;
      } catch (error) {
        lastError = error;
        if (attempt == policy.maxAttempts || _disposed) break;
        final factor = 1 << (attempt - 1);
        final delay = Duration(
          milliseconds: (policy.baseDelay.inMilliseconds * factor)
              .clamp(0, policy.maxDelay.inMilliseconds),
        );
        await Future<void>.delayed(delay);
      }
    }
    // The queue intentionally swallows failures after bounded retries. The
    // caller owns user-facing error reporting and can enqueue its own event.
    if (lastError != null) return;
  }

  Future<void> dispose() async {
    _disposed = true;
    _queue.clear();
  }
}
