import 'dart:async';

/// Typed in-process event bus with bounded replay and deterministic disposal.
/// Events are delivered asynchronously so one listener cannot block another.
class AppEventBus<T> {
  AppEventBus({this.replayLimit = 32}) : assert(replayLimit >= 0);

  final int replayLimit;
  final StreamController<T> _controller = StreamController<T>.broadcast(sync: false);
  final List<T> _history = <T>[];
  bool _closed = false;

  Stream<T> get stream => _controller.stream;
  List<T> get history => List<T>.unmodifiable(_history);
  bool get isClosed => _closed;

  void emit(T event) {
    if (_closed) return;
    if (replayLimit > 0) {
      if (_history.length == replayLimit) _history.removeAt(0);
      _history.add(event);
    }
    _controller.add(event);
  }

  StreamSubscription<T> listen(void Function(T) onData) => stream.listen(onData);

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _history.clear();
    await _controller.close();
  }
}
