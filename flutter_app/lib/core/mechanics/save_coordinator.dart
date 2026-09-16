import 'dart:async';

/// Coalesces rapid editor changes into one save operation and serializes saves.
class SaveCoordinator {
  SaveCoordinator({
    this.delay = const Duration(milliseconds: 700),
    this.maxWait = const Duration(seconds: 4),
  });

  final Duration delay;
  final Duration maxWait;
  Timer? _debounce;
  Timer? _maxWaitTimer;
  Future<void> Function()? _pendingSave;
  Future<void> _serial = Future<void>.value();
  bool _disposed = false;

  bool get hasPendingSave => _pendingSave != null;

  void schedule(Future<void> Function() save) {
    if (_disposed) return;
    _pendingSave = save;
    _debounce?.cancel();
    _debounce = Timer(delay, flush);
    _maxWaitTimer ??= Timer(maxWait, flush);
  }

  Future<void> flush() async {
    _debounce?.cancel();
    _maxWaitTimer?.cancel();
    _debounce = null;
    _maxWaitTimer = null;
    final save = _pendingSave;
    _pendingSave = null;
    if (save == null || _disposed) return;

    final current = _serial.then((_) => save());
    _serial = current.catchError((_) {});
    await current;
  }

  Future<void> dispose({bool flushPending = false}) async {
    if (_disposed) return;
    if (flushPending) await flush().catchError((_) {});
    _disposed = true;
    _debounce?.cancel();
    _maxWaitTimer?.cancel();
    _debounce = null;
    _maxWaitTimer = null;
    _pendingSave = null;
    await _serial.catchError((_) {});
  }
}
