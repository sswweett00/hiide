enum AppNotificationLevel { info, success, warning, error }

class AppNotification {
  final String id;
  final String title;
  final String message;
  final AppNotificationLevel level;
  final DateTime createdAt;
  final bool persistent;

  const AppNotification({
    required this.id,
    required this.title,
    required this.message,
    required this.level,
    required this.createdAt,
    this.persistent = false,
  });
}

/// In-memory notification center with deduplication and bounded retention.
class NotificationCenter {
  NotificationCenter({this.capacity = 100}) : assert(capacity > 0);
  final int capacity;
  final List<AppNotification> _items = <AppNotification>[];

  List<AppNotification> get items => List<AppNotification>.unmodifiable(_items);
  int get unreadCount => _items.where((item) => item.persistent).length;

  void publish({
    required String id,
    required String title,
    required String message,
    AppNotificationLevel level = AppNotificationLevel.info,
    bool persistent = false,
  }) {
    _items.removeWhere((item) => item.id == id);
    _items.insert(0, AppNotification(
      id: id,
      title: title,
      message: message,
      level: level,
      createdAt: DateTime.now(),
      persistent: persistent,
    ));
    if (_items.length > capacity) _items.removeRange(capacity, _items.length);
  }

  void dismiss(String id) => _items.removeWhere((item) => item.id == id);
  void clear() => _items.clear();
}
