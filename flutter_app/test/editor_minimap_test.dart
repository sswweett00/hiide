// Verifies the editor minimap: it renders next to the line-number gutter and
// tapping it jumps the editor to that line (the gutter shows the last lines,
// the first line scrolls out of view).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hiide_flutter/core/backend/mock_backend_service.dart';
import 'package:hiide_flutter/core/providers/backend_provider.dart';
import 'package:hiide_flutter/core/theme/app_themes.dart';
import 'package:hiide_flutter/features/editor/editor_screen.dart';
import 'package:hiide_flutter/shared/models/editor_tab.dart';
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

  testWidgets('minimap renders and tapping it jumps to that line',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final backend = MockBackendService();
    // No `await backend.connect()` — its Future.delayed never completes in a
    // testWidgets fake-async zone without pumping; the mock works regardless.
    addTearDown(backend.dispose);

    // A long file so the minimap has real scrolling to navigate.
    final content =
        List.generate(300, (i) => 'line ${i + 1}').join('\n') + '\n';
    const tab = EditorTab(
      id: 't1',
      title: 'long.txt',
      path: '/tmp/editor_minimap_test.txt',
      content: '',
    );
    final tabWithContent = tab.copyWith(content: content);

    final container = ProviderContainer(
      overrides: [backendServiceProvider.overrideWithValue(backend)],
    );
    addTearDown(container.dispose);
    container.read(openTabsProvider.notifier).state = [tabWithContent];
    container.read(activeTabIdProvider.notifier).state = 't1';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        // The app theme sets fontFamily: 'Inter' — without it the test uses
        // the Ahem placeholder font and the dialog title overflows.
        child: MaterialApp(
          theme: AppThemes.darkTheme,
          home: Scaffold(body: EditorScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // dialog opens

    await tester.tap(find.text('İptal'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // dialog closes

    // Minimap present, gutter at the top (line 1 visible, 300 not).
    expect(find.byKey(const Key('editor_minimap')), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('300'), findsNothing);

    // Tap near the bottom of the minimap → jump to the end of the file.
    final rect = tester.getRect(find.byKey(const Key('editor_minimap')));
    await tester.tapAt(Offset(rect.center.dx, rect.bottom - 3));
    await tester.pump();

    expect(find.text('1'), findsNothing);
    expect(find.text('300'), findsOneWidget);

    // Unmount so session.dispose() runs inside the test (its mock
    // editorDestroy timer must be pumped, not left pending for teardown).
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));
  });
}
