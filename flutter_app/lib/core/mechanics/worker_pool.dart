import 'dart:async';

class WorkerPoolFullException implements Exception {
  const WorkerPoolFullException();
  @override
  String toString() => 'Worker pool queue is full';
}

class WorkerPool {
  WorkerPool({this.concurrency = 4, this.maxQueue = 128})
      : assert(concurrency > 0),
        assert(maxQueue > 0);

  final int concurrency;
  final int maxQueue;
  final List<_WorkItem<dynamic>> _queue = <_WorkItem<dynamic>>[];
  int _head = 0;
  int _running = 0;
  bool _disposed = false;

  int get pending => _queue.length - _head;
  int get running => _running;
  bool get isDisposed => _disposed;

  Future<T> submit<T>(Future<T> Function() task) {
    if (_disposed) return Future<T>.error(StateError('WorkerPool disposed'));
    if (pending >= maxQueue) return Future<T>.error(const WorkerPoolFullException());
    final completer = Completer<T>();
    _queue.add(_WorkItem<T>(task, completer));
    unawaited(_drain());
    return completer.future;
  }

  Future<void> _drain() async {
    while (!_disposed && _running < concurrency && _head < _queue.length) {
      final item = _queue[_head++];
      _running++;
      unawaited(_run(item).whenComplete(() {
        _running--;
        unawaited(_drain());
      }));
    }
    if (_head > 32 && _head * 2 > _queue.length) {
      _queue.removeRange(0, _head);
      _head = 0;
    }
  }

  Future<void> _run<T>(_WorkItem<T> item) async {
    try {
      final value = await item.task();
      if (!item.completer.isCompleted) item.completer.complete(value);
    } catch (error, stack) {
      if (!item.completer.isCompleted) item.completer.completeError(error, stack);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final error = StateError('WorkerPool disposed before execution');
    for (var i = _head; i < _queue.length; i++) {
      final item = _queue[i];
      if (!item.completer.isCompleted) item.completer.completeError(error);
    }
    _queue.clear();
    _head = 0;
    while (_running > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }
}

class _WorkItem<T> {
  _WorkItem(this.task, this.completer);
  final Future<T> Function() task;
  final Completer<T> completer;
}
