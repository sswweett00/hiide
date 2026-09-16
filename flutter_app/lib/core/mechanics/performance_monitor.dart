import 'dart:math' as math;

class PerformanceSample {
  final String operation;
  final Duration duration;
  final bool success;
  final DateTime timestamp;

  const PerformanceSample({
    required this.operation,
    required this.duration,
    required this.success,
    required this.timestamp,
  });
}

class PerformanceStats {
  final int count;
  final int failures;
  final Duration min;
  final Duration max;
  final Duration average;

  const PerformanceStats({
    required this.count,
    required this.failures,
    required this.min,
    required this.max,
    required this.average,
  });
}

/// Keeps only recent samples and aggregates them by operation for lightweight
/// latency/error observability inside the IDE.
class PerformanceMonitor {
  PerformanceMonitor({this.capacity = 256}) : assert(capacity > 0);
  final int capacity;
  final List<PerformanceSample> _samples = <PerformanceSample>[];

  List<PerformanceSample> get samples =>
      List<PerformanceSample>.unmodifiable(_samples);

  T measure<T>(String operation, T Function() action) {
    final started = DateTime.now();
    try {
      final result = action();
      _record(operation, DateTime.now().difference(started), true);
      return result;
    } catch (_) {
      _record(operation, DateTime.now().difference(started), false);
      rethrow;
    }
  }

  Future<T> measureAsync<T>(String operation, Future<T> Function() action) async {
    final started = DateTime.now();
    try {
      final result = await action();
      _record(operation, DateTime.now().difference(started), true);
      return result;
    } catch (_) {
      _record(operation, DateTime.now().difference(started), false);
      rethrow;
    }
  }

  PerformanceStats? statsFor(String operation) {
    final values = _samples.where((s) => s.operation == operation).toList();
    if (values.isEmpty) return null;
    final durations = values.map((s) => s.duration.inMicroseconds).toList();
    final total = durations.fold<int>(0, (sum, value) => sum + value);
    return PerformanceStats(
      count: values.length,
      failures: values.where((s) => !s.success).length,
      min: Duration(microseconds: durations.reduce(math.min)),
      max: Duration(microseconds: durations.reduce(math.max)),
      average: Duration(microseconds: total ~/ durations.length),
    );
  }

  void clear() => _samples.clear();

  void _record(String operation, Duration duration, bool success) {
    if (_samples.length == capacity) _samples.removeAt(0);
    _samples.add(PerformanceSample(
      operation: operation,
      duration: duration,
      success: success,
      timestamp: DateTime.now(),
    ));
  }
}
