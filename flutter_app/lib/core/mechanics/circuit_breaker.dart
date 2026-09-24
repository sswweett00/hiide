import 'dart:async';

enum CircuitState { closed, open, halfOpen }

class CircuitOpenException implements Exception {
  const CircuitOpenException(this.retryAt);
  final DateTime retryAt;
  @override
  String toString() => 'Circuit is open until $retryAt';
}

class CircuitBreaker {
  CircuitBreaker({
    this.failureThreshold = 3,
    this.resetTimeout = const Duration(seconds: 10),
  })  : assert(failureThreshold > 0),
        assert(resetTimeout > Duration.zero);

  final int failureThreshold;
  final Duration resetTimeout;
  CircuitState _state = CircuitState.closed;
  int _failures = 0;
  DateTime? _openedAt;
  bool _probeInFlight = false;

  CircuitState get state {
    if (_state == CircuitState.open &&
        _openedAt != null &&
        DateTime.now().difference(_openedAt!) >= resetTimeout) {
      _state = CircuitState.halfOpen;
    }
    return _state;
  }

  Future<T> run<T>(Future<T> Function() action) async {
    final current = state;
    if (current == CircuitState.open) {
      throw CircuitOpenException(_openedAt!.add(resetTimeout));
    }
    if (current == CircuitState.halfOpen) {
      if (_probeInFlight) {
        throw CircuitOpenException(DateTime.now().add(resetTimeout));
      }
      _probeInFlight = true;
    }

    try {
      final result = await action();
      _failures = 0;
      _openedAt = null;
      _state = CircuitState.closed;
      return result;
    } catch (_) {
      _failures++;
      if (_failures >= failureThreshold || current == CircuitState.halfOpen) {
        _state = CircuitState.open;
        _openedAt = DateTime.now();
      }
      rethrow;
    } finally {
      _probeInFlight = false;
    }
  }

  /// Records a successful operation that is not naturally wrapped in [run],
  /// such as a streaming sequence that must yield incrementally.
  void recordSuccess() {
    _failures = 0;
    _openedAt = null;
    _state = CircuitState.closed;
    _probeInFlight = false;
  }

  /// Records a failed operation that cannot be represented by a single Future
  /// callback. This shares the same threshold and half-open semantics as [run].
  void recordFailure() {
    final current = state;
    if (current == CircuitState.open) return;
    _failures++;
    if (_failures >= failureThreshold || current == CircuitState.halfOpen) {
      _state = CircuitState.open;
      _openedAt = DateTime.now();
    }
    _probeInFlight = false;
  }

  void reset() {
    recordSuccess();
  }
}
