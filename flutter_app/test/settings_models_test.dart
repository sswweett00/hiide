// Verifies the Settings AI Model dropdown transitions from the curated
// default list to the models Groq actually serves once an API key is saved:
//   1. default list while no key is configured (no network call),
//   2. after Save, the live /models response fills the dropdown (filtered to
//      usable ids) and the status line reports the live count,
//   3. a persisted model that vanished from the live list is auto-corrected
//      to the first live model and persisted.
// No real network — the Groq service is overridden with a scripted client.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hiide_flutter/core/backend/groq_ai_service.dart';
import 'package:hiide_flutter/core/backend/settings_service.dart';
import 'package:hiide_flutter/features/settings/settings_screen.dart';
import 'package:hiide_flutter/shared/providers/editor_providers.dart';

/// Scripted /models response: includes a model that is NOT in the curated
/// list (proves the live list is used), a curated-only model that is NOT on
/// the API (proves it disappears), and groq/compound-mini (must be filtered).
final _liveBody = '{"data":['
    '{"id":"llama-3.3-70b-versatile"},'
    '{"id":"openai/gpt-oss-120b"},'
    '{"id":"llama-4-scout-17b-16e-instruct"},'
    '{"id":"groq/compound-mini"}]}';

/// Mirrors production: the service re-reads the persisted key, so saving a
/// key and invalidating the provider produces a client with the new key.
List<Override> _overrides() {
  final mockClient = MockClient((request) async {
    expect(request.url.path, '/openai/v1/models');
    return http.Response(_liveBody, 200);
  });
  return [
    groqAiServiceProvider.overrideWith((ref) async {
      final key = await settingsService.getApiKey();
      return GroqAiService(apiKey: key, client: mockClient);
    }),
  ];
}

Future<void> _pumpSettings(WidgetTester tester) async {
  await tester.pumpWidget(ProviderScope(
    overrides: _overrides(),
    child: const MaterialApp(home: SettingsScreen(standalone: true)),
  ));
  await tester.pumpAndSettle();
}

/// Opens the AI Model dropdown (the first DropdownButton in the tree) and
/// closes it afterwards, leaving the UI in a settled state.
Future<void> _openModelMenu(WidgetTester tester) async {
  await tester.tap(find.byType(DropdownButton<String>).first);
  await tester.pumpAndSettle();
}

Future<void> _closeModelMenu(WidgetTester tester) async {
  await tester.tapAt(const Offset(5, 5));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('dropdown fills with live models after saving an API key',
      (tester) async {
    settingsService.resetForTesting();
    SharedPreferences.setMockInitialValues({});
    await _pumpSettings(tester);

    // Default (curated) list while no key is configured.
    await _openModelMenu(tester);
    expect(find.text('llama-4-scout-17b-16e-instruct'), findsNothing,
        reason: 'live-only model must not appear before the key is saved');
    expect(find.text('openai/gpt-oss-20b'), findsOneWidget,
        reason: 'curated-only model is present in the default list');
    await _closeModelMenu(tester);

    // Save an API key → live /models fetch → dropdown swaps to the live list.
    await tester.enterText(find.byType(TextField).first, 'gsk_live');
    await tester.pump(); // let onChanged → setState enable the Save button
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('API key saved!'), findsOneWidget,
        reason: 'save flow ran');
    expect(find.text('3 models from the Groq API'), findsOneWidget,
        reason: 'status line reports the live model count');

    await _openModelMenu(tester);
    expect(find.text('llama-4-scout-17b-16e-instruct'), findsOneWidget,
        reason: 'live-only model now appears');
    expect(find.text('openai/gpt-oss-20b'), findsNothing,
        reason: 'curated-only model vanished from the live list');
    expect(find.text('groq/compound-mini'), findsNothing,
        reason: 'non-tool-calling model is filtered out');
    await _closeModelMenu(tester);
  });

  testWidgets('stale persisted model is corrected to the first live model',
      (tester) async {
    settingsService.resetForTesting();
    SharedPreferences.setMockInitialValues(
        {'groq_model': 'openai/gpt-oss-20b'});
    await _pumpSettings(tester);

    // Before the key is saved the curated list contains the stored model.
    DropdownButton<String> modelDropdown() =>
        tester.widget<DropdownButton<String>>(
            find.byType(DropdownButton<String>).first);
    expect(modelDropdown().value, 'openai/gpt-oss-20b');

    await tester.enterText(find.byType(TextField).first, 'gsk_live');
    await tester.pump(); // let onChanged → setState enable the Save button
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // The stored model is gone from the live list → corrected + persisted.
    expect(modelDropdown().value, 'llama-3.3-70b-versatile');
    expect(await settingsService.getModel(), 'llama-3.3-70b-versatile');
  });
}
