class CommandRecord {
  final String id;
  final String label;
  final DateTime startedAt;
  final Duration duration;
  final bool success;

  const CommandRecord({
    required this.id,
    required this.label,
    required this.startedAt,
    required this.duration,
    required this.success,
  });
}

/// Most-recent-first command telemetry/history with stable memory usage.
class CommandHistory {
  CommandHistory({this.capacity = 100}) : assert(capacity > 0);

  final int capacity;
  final List<CommandRecord> _items = <CommandRecord>[];

  List<CommandRecord> get items => List<CommandRecord>.unmodifiable(_items);

  void add(CommandRecord record) {
    _items.removeWhere((item) => item.id == record.id);
    _items.insert(0, record);
    if (_items.length > capacity) _items.removeRange(capacity, _items.length);
  }

  void clear() => _items.clear();

  CommandRecord? find(String id) {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }
}
