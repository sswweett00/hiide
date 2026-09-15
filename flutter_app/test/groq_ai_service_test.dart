// Verifies the Groq connectivity probe (checkConnection) against a scripted
// HTTP client: healthy key, invalid key, empty key, and network failure.
// No real network access — the http client is injected.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hiide_flutter/core/backend/groq_ai_service.dart';

void main() {
  test('checkConnection reports ok for a valid key', () async {
    final service = GroqAiService(
      apiKey: 'gsk_test',
      client: MockClient((request) async {
        expect(request.url.path, '/openai/v1/models');
        expect(request.headers['Authorization'], 'Bearer gsk_test');
        return http.Response('{"data":[]}', 200);
      }),
    );

    final result = await service.checkConnection();
    expect(result.ok, isTrue);
    expect(result.message, contains('Connected'));
  });

  test('checkConnection surfaces the API error message on 401', () async {
    final service = GroqAiService(
      apiKey: 'gsk_bad',
      client: MockClient((request) async {
        return http.Response(
          '{"error":{"message":"Invalid API Key"}}',
          401,
        );
      }),
    );

    final result = await service.checkConnection();
    expect(result.ok, isFalse);
    expect(result.message, contains('Invalid API Key'));
  });

  test('checkConnection reports a missing key without any network call',
      () async {
    var networkCalls = 0;
    final service = GroqAiService(
      apiKey: '',
      client: MockClient((request) async {
        networkCalls++;
        return http.Response('{"data":[]}', 200);
      }),
    );

    final result = await service.checkConnection();
    expect(result.ok, isFalse);
    expect(result.message, contains('API key'));
    expect(networkCalls, 0);
  });

  test('checkConnection reports a network failure instead of throwing',
      () async {
    final service = GroqAiService(
      apiKey: 'gsk_test',
      client: MockClient((request) async {
        throw http.ClientException('Connection refused');
      }),
    );

    final result = await service.checkConnection();
    expect(result.ok, isFalse);
    expect(result.message, contains('Connection refused'));
  });

  test('chatCompletion extracts the API error message from the body', () async {
    final service = GroqAiService(
      apiKey: 'gsk_test',
      client: MockClient((request) async {
        return http.Response(
          '{"error":{"message":"Rate limit exceeded"}}',
          429,
        );
      }),
    );

    final result = await service.chatCompletion(
      messages: [
        {'role': 'user', 'content': 'hi'},
      ],
    );
    expect(result['error'], contains('Rate limit exceeded'));
  });

  group('fetchModelIds', () {
    test('returns the ids served by the API', () async {
      final service = GroqAiService(
        apiKey: 'gsk_test',
        client: MockClient((request) async {
          expect(request.url.path, '/openai/v1/models');
          expect(request.headers['Authorization'], 'Bearer gsk_test');
          return http.Response(
            '{"data":[{"id":"llama-3.3-70b-versatile"},'
            '{"id":"openai/gpt-oss-120b"},{"id":"groq/compound-mini"}]}',
            200,
          );
        }),
      );

      expect(await service.fetchModelIds(), [
        'llama-3.3-70b-versatile',
        'openai/gpt-oss-120b',
        'groq/compound-mini',
      ]);
    });

    test('throws GroqApiException with the API message on 401', () async {
      final service = GroqAiService(
        apiKey: 'gsk_bad',
        client: MockClient((request) async {
          return http.Response(
            '{"error":{"message":"Invalid API Key"}}',
            401,
          );
        }),
      );

      expect(
        service.fetchModelIds(),
        throwsA(isA<GroqApiException>()
            .having((e) => e.message, 'message', contains('Invalid API Key'))),
      );
    });

    test('wraps a network failure in GroqApiException', () async {
      final service = GroqAiService(
        apiKey: 'gsk_test',
        client: MockClient((request) async {
          throw http.ClientException('Connection refused');
        }),
      );

      expect(
        service.fetchModelIds(),
        throwsA(isA<GroqApiException>()),
      );
    });

    test('rejects a missing key without any network call', () async {
      var networkCalls = 0;
      final service = GroqAiService(
        apiKey: '',
        client: MockClient((request) async {
          networkCalls++;
          return http.Response('{"data":[]}', 200);
        }),
      );

      expect(
        service.fetchModelIds(),
        throwsA(isA<GroqApiException>()),
      );
      expect(networkCalls, 0);
    });
  });
}
