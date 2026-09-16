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

  Future<T> race<T>(Future<T> future) {
    if (_cancelled) return Future<T>.error(const CancellationException());
    final completer = Completer<T>();
    late StreamSubscription<void> subscription;
    subscription = onCancel.listen((_) {
      if (!completer.isCompleted) {
        completer.completeError(const CancellationException());
      }
    });

    future.then(
      (value) {
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      },
    );

    return completer.future.whenComplete(subscription.cancel);
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
