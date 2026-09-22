import 'dart:async';

class IdempotencyStore<T> {
  IdempotencyStore({this.capacity = 256, this.ttl = const Duration(minutes: 10)})
      : assert(capacity > 0),
        assert(ttl > Duration.zero);

  final int capacity;
  final Duration ttl;
  final Map<String, _IdempotentEntry<T>> _entries = <String, _IdempotentEntry<T>>{};

  int get length => _entries.length;

  Future<T> run(String key, Future<T> Function() action) {
    final now = DateTime.now();
    final existing = _entries[key];
    if (existing != null && now.isBefore(existing.expiresAt)) return existing.future;
    _entries.remove(key);

    final future = action();
    _entries[key] = _IdempotentEntry<T>(future, now.add(ttl));
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }

    future.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        _entries.remove(key);
      },
    );
    return future;
  }

  void remove(String key) => _entries.remove(key);
  void clear() => _entries.clear();
}

class _IdempotentEntry<T> {
  _IdempotentEntry(this.future, this.expiresAt);
  final Future<T> future;
  final DateTime expiresAt;
}
