import 'dart:async';

class BackpressureQueueFullException implements Exception {
  const BackpressureQueueFullException();
  @override
  String toString() => 'Backpressure queue is full';
}

class BackpressureQueue<T> {
  BackpressureQueue({this.capacity = 128}) : assert(capacity > 0);

  final int capacity;
  final List<T> _items = <T>[];
  final List<Completer<T>> _waiters = <Completer<T>>[];
  bool _closed = false;

  int get length => _items.length;
  bool get isClosed => _closed;

  bool tryAdd(T item) {
    if (_closed) return false;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(item);
      return true;
    }
    if (_items.length >= capacity) return false;
    _items.add(item);
    return true;
  }

  void add(T item) {
    if (!tryAdd(item)) {
      if (_closed) throw StateError('BackpressureQueue is closed');
      throw const BackpressureQueueFullException();
    }
  }

  Future<T> take({Duration? timeout}) async {
    if (_items.isNotEmpty) return _items.removeAt(0);
    if (_closed) throw StateError('BackpressureQueue is closed');
    final completer = Completer<T>();
    _waiters.add(completer);
    if (timeout == null) return completer.future;
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _waiters.remove(completer);
      rethrow;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    final error = StateError('BackpressureQueue closed');
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
    _waiters.clear();
    _items.clear();
  }
}
