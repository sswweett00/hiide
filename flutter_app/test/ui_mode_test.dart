// Verifies the secondary layout switch: the default is agent-native and the
// classic editor shell can still be opened when a code-centric surface is needed.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hiide_flutter/core/backend/agent_mode.dart';
import 'package:hiide_flutter/core/backend/groq_ai_service.dart';
import 'package:hiide_flutter/core/backend/mock_backend_service.dart';
import 'package:hiide_flutter/core/providers/backend_provider.dart';
import 'package:hiide_flutter/core/theme/app_themes.dart';
import 'package:hiide_flutter/features/chat/ai_chat_sidebar.dart';
import 'package:hiide_flutter/features/status_bar/status_bar.dart';
import 'package:hiide_flutter/shared/providers/editor_providers.dart';
import 'package:hiide_flutter/shared/widgets/ide_shell.dart';

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

  Future<void> pumpShell(WidgetTester tester) async {
    // Desktop-sized surface so the IdeShell shows the Explorer panel (it is
    // hidden below 900px).
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final backend = MockBackendService();
    addTearDown(backend.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendServiceProvider.overrideWithValue(backend),
          groqAiServiceProvider
              .overrideWith((ref) async => GroqAiService(apiKey: 'test-key')),
          groqConnectionProvider
              .overrideWith((ref) async => (ok: true, message: 'Connected')),
        ],
        child: MaterialApp(
          theme: AppThemes.darkTheme,
          home: const IdeShell(child: SizedBox.expand()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('default product mode is agent-native', (tester) async {
    await pumpShell(tester);

    expect(find.byType(AiChatSidebar), findsOneWidget);
    expect(find.text('Explorer'), findsNothing);
    expect(find.byType(StatusBar), findsNothing);
    expect(find.text('AI'), findsOneWidget);
  });

  testWidgets('secondary editor shell can be opened and closed', (tester) async {
    await pumpShell(tester);

    // Opt into the secondary classic shell.
    await tester.tap(find.text('IDE'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Explorer'), findsNothing);
    expect(find.byType(StatusBar), findsNothing);
    expect(find.byType(AiChatSidebar), findsOneWidget);

    await tester.tap(find.text('AI'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Explorer'), findsOneWidget);
    expect(find.byType(StatusBar), findsOneWidget);
  });


  testWidgets('AI sidebar exposes independent Plan and Code modes', (tester) async {
    await pumpShell(tester);

    expect(find.text('Plan'), findsOneWidget);
    expect(find.text('Code'), findsOneWidget);

    await tester.tap(find.text('Plan'));
    await tester.pump();

    expect(find.textContaining('dosya değiştirmez'), findsOneWidget);
    expect(find.text('Son planı uygula'), findsNothing);
  });

  testWidgets('uiModeProvider drives the shell directly', (tester) async {
    await pumpShell(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AiChatSidebar)),
    );
    container.read(uiModeProvider.notifier).state = UiMode.aiNative;
    await tester.pump();

    expect(find.byType(StatusBar), findsNothing);
    expect(find.byType(AiChatSidebar), findsOneWidget);
  });
}
