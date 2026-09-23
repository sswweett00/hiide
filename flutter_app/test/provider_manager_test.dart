import 'package:flutter_test/flutter_test.dart';
import 'package:hiide_flutter/core/backend/ai_providers/ai_provider.dart';
import 'package:hiide_flutter/core/backend/ai_providers/provider_manager.dart';

class _FakeProvider implements AiProvider {
  _FakeProvider({
    required this.id,
    required this.available,
    this.models = const ['model'],
  });

  @override
  final String id;

  @override
  final bool available;

  @override
  final List<String> models;

  @override
  String get displayName => id;

  @override
  bool get requiresApiKey => true;

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
    yield id;
  }

  @override
  Future<String?> completeCode(String prompt, {String? model}) async {
    return id;
  }

  @override
  Future<List<String>> fetchAvailableModels() async => models;
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
}
