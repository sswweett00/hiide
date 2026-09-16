import 'dart:async';

enum HealthState { healthy, degraded, unhealthy }

class HealthSnapshot {
  const HealthSnapshot({
    required this.name,
    required this.state,
    required this.checkedAt,
    this.latency,
    this.message,
  });

  final String name;
  final HealthState state;
  final DateTime checkedAt;
  final Duration? latency;
  final String? message;
}

typedef HealthProbe = Future<void> Function();

class HealthMonitor {
  HealthMonitor({this.timeout = const Duration(seconds: 5), this.capacity = 64})
      : assert(timeout > Duration.zero),
        assert(capacity > 0);

  final Duration timeout;
  final int capacity;
  final Map<String, HealthProbe> _probes = <String, HealthProbe>{};
  final Map<String, HealthSnapshot> _latest = <String, HealthSnapshot>{};

  List<HealthSnapshot> get latest => List.unmodifiable(_latest.values);

  void register(String name, HealthProbe probe) {
    if (name.trim().isEmpty) throw ArgumentError.value(name, 'name');
    _probes[name] = probe;
  }

  void unregister(String name) {
    _probes.remove(name);
    _latest.remove(name);
  }

  Future<HealthSnapshot> check(String name) async {
    final probe = _probes[name];
    if (probe == null) throw StateError('Unknown health probe: $name');
    final started = DateTime.now();
    try {
      await probe().timeout(timeout);
      return _record(HealthSnapshot(
        name: name,
        state: HealthState.healthy,
        checkedAt: DateTime.now(),
        latency: DateTime.now().difference(started),
      ));
    } catch (error) {
      return _record(HealthSnapshot(
        name: name,
        state: HealthState.unhealthy,
        checkedAt: DateTime.now(),
        latency: DateTime.now().difference(started),
        message: error.toString(),
      ));
    }
  }

  Future<List<HealthSnapshot>> checkAll() async {
    final results = await Future.wait(_probes.keys.map(check));
    return results;
  }

  HealthSnapshot _record(HealthSnapshot snapshot) {
    _latest[snapshot.name] = snapshot;
    if (_latest.length > capacity) {
      _latest.remove(_latest.keys.first);
    }
    return snapshot;
  }
}
