import 'dart:async';

typedef Transition<S, E> = S Function(S state, E event);

class StateMachine<S, E> {
  StateMachine({required S initialState, required Map<Type, Transition<S, E>> transitions})
      : _state = initialState,
        _transitions = Map<Type, Transition<S, E>>.unmodifiable(transitions);

  S _state;
  final Map<Type, Transition<S, E>> _transitions;
  final StreamController<S> _controller = StreamController<S>.broadcast();
  bool _disposed = false;

  S get state => _state;
  Stream<S> get changes => _controller.stream;

  S dispatch(E event) {
    if (_disposed) throw StateError('StateMachine disposed');
    final transition = _transitions[event.runtimeType];
    if (transition == null) {
      throw StateError('No transition registered for ${event.runtimeType}');
    }
    final next = transition(_state, event);
    if (next == _state) return _state;
    _state = next;
    _controller.add(_state);
    return _state;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _controller.close();
  }
}
