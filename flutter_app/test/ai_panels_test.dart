// Verifies the AI-native chrome: the chat sidebar shows a welcome panel with
// suggested prompts on first run, and the status bar reflects live AI state.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hiide_flutter/core/backend/groq_ai_service.dart';
import 'package:hiide_flutter/core/backend/mock_backend_service.dart';
import 'package:hiide_flutter/core/providers/backend_provider.dart';
import 'package:hiide_flutter/core/theme/app_themes.dart';
import 'package:hiide_flutter/features/chat/ai_chat_sidebar.dart';
import 'package:hiide_flutter/features/status_bar/status_bar.dart';
import 'package:hiide_flutter/shared/providers/editor_providers.dart';

Future<void> _loadAppFonts() async {
  const families = {
    'Inter': ['400', '500', '600', '700'],
    'JetBrains Mono': ['400', '500', '700'],
  };
  for (final entry in families.entries) {
    final loader = FontLoader(entry.key);
    for (final weight in entry.value) {
      final bytes =
          File('assets/fonts/${entry.key.replaceAll(' ', '')}-$weight.ttf')
              .readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }
}

void main() {
  setUpAll(_loadAppFonts);

  testWidgets('chat sidebar shows the welcome panel with suggested prompts',
      (tester) async {
    final backend = MockBackendService();
    addTearDown(backend.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendServiceProvider.overrideWithValue(backend),
          groqAiServiceProvider
              .overrideWith((ref) async => GroqAiService(apiKey: 'test-key')),
          // Deterministic connectivity for the header dot — no real HTTP.
          groqConnectionProvider
              .overrideWith((ref) async => (ok: true, message: 'Connected')),
        ],
        child: MaterialApp(
          theme: AppThemes.darkTheme,
          home: const Scaffold(body: AiChatSidebar()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Header + welcome title.
    expect(find.text('Hiide AI'), findsWidgets);
    expect(find.byType(ActionChip), findsNWidgets(4));
    expect(find.text('Explain the active file'), findsOneWidget);
    expect(find.text('Write tests'), findsOneWidget);

    // The send affordance is present even in the empty state.
    expect(find.byIcon(Icons.send), findsOneWidget);
  });

  testWidgets('status bar shows AI ready and engine state', (tester) async {
    final backend = MockBackendService();
    addTearDown(backend.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendServiceProvider.overrideWithValue(backend),
          groqConnectionProvider
              .overrideWith((ref) async => (ok: true, message: 'Connected')),
        ],
        child: MaterialApp(
          theme: AppThemes.darkTheme,
          home: const Scaffold(body: StatusBar()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('AI: Ready'), findsOneWidget);
    expect(find.text('Ln 1, Col 1'), findsOneWidget);

    // Agent running → the status flips to Working.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(StatusBar)),
    );
    container.read(isAiThinkingProvider.notifier).state = true;
    await tester.pump();

    expect(find.text('AI: Working'), findsOneWidget);
  });
}
