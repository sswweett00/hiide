import 'dart:async';

class RetryPolicy {
  final int maxAttempts;
  final Duration baseDelay;
  final Duration maxDelay;

  const RetryPolicy({
    this.maxAttempts = 4,
    this.baseDelay = const Duration(milliseconds: 250),
    this.maxDelay = const Duration(seconds: 5),
  }) : assert(maxAttempts > 0),
       assert(baseDelay >= Duration.zero),
       assert(maxDelay >= Duration.zero);
}

class RetryQueue {
  RetryQueue({this.policy = const RetryPolicy(), this.concurrency = 1})
      : assert(concurrency > 0);

  final RetryPolicy policy;
  final int concurrency;
  final List<_RetryTask> _queue = <_RetryTask>[];
  int _running = 0;
  bool _disposed = false;

  int get pending => _queue.length;
  bool get isDisposed => _disposed;

  Future<void> enqueue(Future<void> Function() task) {
    if (_disposed) {
      return Future<void>.error(StateError('RetryQueue has been disposed'));
    }
    final completer = Completer<void>();
    _queue.add(_RetryTask(task, completer));
    unawaited(_drain());
    return completer.future;
  }

  Future<void> _drain() async {
    while (!_disposed && _running < concurrency && _queue.isNotEmpty) {
      final item = _queue.removeAt(0);
      _running++;
      unawaited(_run(item).whenComplete(() {
        _running--;
        unawaited(_drain());
      }));
    }
  }

  Future<void> _run(_RetryTask item) async {
    Object? lastError;
    StackTrace? lastStack;

    for (var attempt = 1; attempt <= policy.maxAttempts; attempt++) {
      if (_disposed) {
        lastError = StateError('RetryQueue disposed during execution');
        break;
      }
      try {
        await item.task();
        if (!item.completer.isCompleted) item.completer.complete();
        return;
      } catch (error, stack) {
        lastError = error;
        lastStack = stack;
        if (attempt == policy.maxAttempts || _disposed) break;

        final factor = 1 << (attempt - 1);
        final milliseconds = policy.baseDelay.inMilliseconds * factor;
        final bounded = milliseconds.clamp(
          0,
          policy.maxDelay.inMilliseconds,
        );
        await Future<void>.delayed(Duration(milliseconds: bounded));
      }
    }

    if (!item.completer.isCompleted) {
      item.completer.completeError(
        lastError ?? StateError('Retry operation failed'),
        lastStack ?? StackTrace.current,
      );
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final error = StateError('RetryQueue disposed before execution');
    for (final item in _queue) {
      if (!item.completer.isCompleted) item.completer.completeError(error);
    }
    _queue.clear();
    while (_running > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }
}

class _RetryTask {
  _RetryTask(this.task, this.completer);
  final Future<void> Function() task;
  final Completer<void> completer;
}
