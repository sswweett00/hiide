import 'dart:async';

class CancellationToken {
  bool _cancelled = false;
  final StreamController<void> _controller = StreamController<void>.broadcast();

  bool get isCancelled => _cancelled;
  Stream<void> get onCancel => _controller.stream;

  void throwIfCancelled() {
    if (_cancelled) throw const CancellationException();
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    if (!_controller.isClosed) _controller.add(null);
  }

  Future<T> race<T>(Future<T> future) async {
    if (_cancelled) throw const CancellationException();
    final cancellation = onCancel.first.then<T>((_) => throw const CancellationException());
    try {
      return await Future.any<T>(<Future<T>>[future, cancellation]);
    } finally {
      await cancellation.catchError((_) {});
    }
  }

  Future<void> dispose() async {
    cancel();
    await _controller.close();
  }
}

class CancellationException implements Exception {
  const CancellationException();
  @override
  String toString() => 'Operation cancelled';
}
