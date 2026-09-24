import 'package:flutter_test/flutter_test.dart';
import 'package:hiide_flutter/core/backend/ai_providers/ai_provider.dart';
import 'package:hiide_flutter/core/backend/ai_providers/provider_manager.dart';

class _FakeProvider implements AiProvider {
  _FakeProvider({
    required this.id,
    required this.available,
    this.models = const ['model'],
    this.responseError,
    this.streamError,
  });

  @override
  final String id;

  @override
  String get baseUrl => 'https://example.test/v1';

  @override
  final bool available;

  @override
  final List<String> models;
  final String? responseError;
  final String? streamError;
  int chatCalls = 0;
  int modelCalls = 0;

  @override
  String get displayName => id;

  @override
  bool get requiresApiKey => true;

  @override
  bool get isConfigured => true;

  @override
  String get defaultModel => models.first;

  @override
  Future<bool> get isAvailable async => available;

  @override
  Future<Map<String, dynamic>> chatCompletion({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    String? model,
    double temperature = 0.2,
  }) async {
    chatCalls++;
    if (responseError != null) {
      return {'error': responseError!};
    }
    return {
      'provider': id,
      'model': model ?? defaultModel,
    };
  }

  @override
  Stream<String> chatCompletionStream({
    required List<Map<String, dynamic>> messages,
    String? model,
  }) async* {
    if (streamError != null) {
      throw StateError(streamError!);
    }
    yield id;
  }

  @override
  Future<String?> completeCode(String prompt, {String? model}) async {
    return id;
  }

  @override
  Future<List<String>> fetchAvailableModels() async {
    modelCalls++;
    return models;
  }
}

void main() {
  test('keeps the configured provider and selected model', () async {
    final manager = ProviderManager(
      [
        _FakeProvider(id: 'primary', available: true, models: ['p1']),
        _FakeProvider(id: 'fallback', available: true, models: ['f1']),
      ],
      activeProviderId: 'primary',
      selectedModels: const {'primary': 'custom-model'},
    );

    expect(manager.activeProviderId, 'primary');
    expect(manager.activeModel, 'custom-model');

    final result = await manager.chatCompletion(
      messages: const [
        {'role': 'user', 'content': 'hi'}
      ],
    );
    expect(result['provider'], 'primary');
    expect(result['model'], 'custom-model');
  });

  test('falls back when the preferred provider is unavailable', () async {
    final manager = ProviderManager(
      [
        _FakeProvider(id: 'primary', available: false),
        _FakeProvider(id: 'fallback', available: true, models: ['f1']),
      ],
      activeProviderId: 'primary',
      selectedModels: const {},
    );

    final result = await manager.chatCompletion(
      messages: const [
        {'role': 'user', 'content': 'hi'}
      ],
    );

    expect(result['provider'], 'fallback');
    expect(manager.activeProviderId, 'fallback');
    expect(manager.activeModel, 'f1');
  });

  test('returns provider model discovery without changing active provider', () async {
    final manager = ProviderManager(
      [
        _FakeProvider(id: 'primary', available: true, models: ['p1']),
        _FakeProvider(id: 'other', available: true, models: ['x', 'y']),
      ],
      activeProviderId: 'primary',
      selectedModels: const {},
    );

    expect(await manager.fetchModels('other'), ['x', 'y']);
    expect(manager.activeProviderId, 'primary');
  });

  test('coalesces concurrent model discovery requests', () async {
    final provider = _FakeProvider(id: 'primary', available: true, models: ['a', 'b']);
    final manager = ProviderManager(
      [provider],
      activeProviderId: 'primary',
      selectedModels: const {},
    );

    final results = await Future.wait([
      manager.fetchModels('primary'),
      manager.fetchModels('primary'),
      manager.fetchModels('primary'),
    ]);

    expect(results, [
      ['a', 'b'],
      ['a', 'b'],
      ['a', 'b'],
    ]);
    expect(provider.modelCalls, 1);
  });

  test('falls back from a streaming provider error', () async {
    final manager = ProviderManager(
      [
        _FakeProvider(
          id: 'primary',
          available: true,
          streamError: 'stream unavailable',
        ),
        _FakeProvider(id: 'fallback', available: true),
      ],
      activeProviderId: 'primary',
      selectedModels: const {},
    );

    final chunks = await manager.chatCompletionStream(
      messages: const [
        {'role': 'user', 'content': 'hi'}
      ],
    ).toList();

    expect(chunks, ['fallback']);
    expect(manager.activeProviderId, 'fallback');
  });

  test('opens a provider circuit after repeated request failures', () async {
    final primary = _FakeProvider(
      id: 'primary',
      available: true,
      responseError: 'temporary outage',
    );
    final fallback = _FakeProvider(id: 'fallback', available: true);
    final manager = ProviderManager(
      [primary, fallback],
      activeProviderId: 'primary',
      selectedModels: const {},
    );

    for (var i = 0; i < 3; i++) {
      manager.switchTo('primary');
      final result = await manager.chatCompletion(
        messages: const [
          {'role': 'user', 'content': 'retry'}
        ],
      );
      expect(result['provider'], 'fallback');
    }

    manager.switchTo('primary');
    final result = await manager.chatCompletion(
      messages: const [
        {'role': 'user', 'content': 'circuit'}
      ],
    );
    expect(result['provider'], 'fallback');
    expect(primary.chatCalls, 3);
  });

  test('does not leak the primary provider model into fallback provider', () async {
    final manager = ProviderManager(
      [
        _FakeProvider(id: 'primary', available: false, models: ['primary-model']),
        _FakeProvider(id: 'fallback', available: true, models: ['fallback-model']),
      ],
      activeProviderId: 'primary',
      selectedModels: const {'fallback': 'fallback-selected'},
    );

    final result = await manager.chatCompletion(
      messages: const [
        {'role': 'user', 'content': 'hi'}
      ],
      model: 'primary-model',
    );

    expect(result['provider'], 'fallback');
    expect(result['model'], 'fallback-selected');
  });


  test('falls back after an actual provider request error', () async {
    final manager = ProviderManager(
      [
        _FakeProvider(
          id: 'primary',
          available: true,
          models: ['primary-model'],
          responseError: 'temporary outage',
        ),
        _FakeProvider(
          id: 'fallback',
          available: true,
          models: ['fallback-model'],
        ),
      ],
      activeProviderId: 'primary',
      selectedModels: const {},
    );

    final result = await manager.chatCompletion(
      messages: const [
        {'role': 'user', 'content': 'continue the task'}
      ],
      model: 'primary-model',
    );

    expect(result['provider'], 'fallback');
    expect(result['model'], 'fallback-model');
    expect(manager.activeProviderId, 'fallback');
  });

}
