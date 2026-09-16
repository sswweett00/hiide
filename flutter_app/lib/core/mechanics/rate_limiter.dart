import 'dart:async';

class RateLimitException implements Exception {
  const RateLimitException(this.retryAfter);
  final Duration retryAfter;
  @override
  String toString() => 'Rate limit exceeded; retry after $retryAfter';
}

class SlidingWindowRateLimiter {
  SlidingWindowRateLimiter({
    required this.maxEvents,
    required this.window,
  })  : assert(maxEvents > 0),
        assert(window > Duration.zero);

  final int maxEvents;
  final Duration window;
  final List<DateTime> _events = <DateTime>[];

  bool tryAcquire() {
    _prune();
    if (_events.length >= maxEvents) return false;
    _events.add(DateTime.now());
    return true;
  }

  Duration get retryAfter {
    _prune();
    if (_events.isEmpty) return Duration.zero;
    return window - DateTime.now().difference(_events.first);
  }

  Future<void> acquire({Duration? maxWait}) async {
    final deadline = maxWait == null ? null : DateTime.now().add(maxWait);
    while (!tryAcquire()) {
      final delay = retryAfter;
      if (deadline != null && DateTime.now().add(delay).isAfter(deadline)) {
        throw RateLimitException(delay);
      }
      await Future<void>.delayed(delay);
    }
  }

  void reset() => _events.clear();

  void _prune() {
    final cutoff = DateTime.now().subtract(window);
    _events.removeWhere((event) => !event.isAfter(cutoff));
  }
}
