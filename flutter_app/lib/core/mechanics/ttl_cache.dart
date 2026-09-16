class TtlCache<K, V> {
  TtlCache({this.capacity = 256, this.ttl = const Duration(minutes: 5)})
      : assert(capacity > 0),
        assert(ttl > Duration.zero);

  final int capacity;
  final Duration ttl;
  final Map<K, _CacheEntry<V>> _entries = <K, _CacheEntry<V>>{};

  V? get(K key) {
    final entry = _entries[key];
    if (entry == null) return null;
    if (!DateTime.now().isBefore(entry.expiresAt)) {
      _entries.remove(key);
      return null;
    }
    entry.lastAccess = DateTime.now();
    return entry.value;
  }

  bool containsKey(K key) => get(key) != null;

  void set(K key, V value, {Duration? lifetime}) {
    _entries[key] = _CacheEntry<V>(
      value,
      DateTime.now().add(lifetime ?? ttl),
    );
    _evict();
  }

  V? getOrSet(K key, V Function() create) {
    final existing = get(key);
    if (existing != null) return existing;
    final value = create();
    set(key, value);
    return value;
  }

  void remove(K key) => _entries.remove(key);
  void clear() => _entries.clear();

  void _evict() {
    while (_entries.length > capacity) {
      final oldest = _entries.entries.reduce(
        (a, b) => a.value.lastAccess.isBefore(b.value.lastAccess) ? a : b,
      );
      _entries.remove(oldest.key);
    }
  }
}

class _CacheEntry<V> {
  _CacheEntry(this.value, this.expiresAt) : lastAccess = DateTime.now();
  final V value;
  final DateTime expiresAt;
  DateTime lastAccess;
}
