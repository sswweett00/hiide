// Verifies the editor gutter change markers: with an open tab whose buffer
// diverges from the on-disk baseline, the modified line gets a colored marker
// bar next to its line number. Uses the mock backend (local diff fallback).

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

const _modifiedColor = Color(0xFFD29922);
const _addedColor = Color(0xFF3FB950);

bool _isMarker(Color color, Widget w) {
  if (w is! Container) return false;
  final d = w.decoration;
  return d is BoxDecoration && d.color == color;
}

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

  testWidgets('gutter marks the modified line after the buffer diverges',
      (tester) async {
    // Desktop-sized surface: the editor header row (Ask AI, Klasör Seç, …)
    // is designed for the real 1280+ window and overflows on narrow widths.
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final backend = MockBackendService();
    // NOTE: no `await backend.connect()` — it uses Future.delayed, which
    // never completes in a testWidgets fake-async zone without pumping. The
    // mock's methods work regardless of the connected flag.
    addTearDown(backend.dispose);

    const tab = EditorTab(
      id: 't1',
      title: 'test.txt',
      path: '/tmp/editor_gutter_test.txt',
      content: 'alpha\nbeta\ngamma\n',
    );

    final container = ProviderContainer(
      overrides: [backendServiceProvider.overrideWithValue(backend)],
    );
    addTearDown(container.dispose);
    container.read(openTabsProvider.notifier).state = [tab];
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
    await tester.pump(); // first frame
    await tester.pump(const Duration(milliseconds: 400)); // dialog opens

    // Dismiss the auto-opened folder browser dialog.
    await tester.tap(find.text('İptal'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // dialog closes

    // Let the initial diff (buffer == disk) settle.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));

    // Buffer == disk baseline → no markers.
    expect(find.byWidgetPredicate((w) => _isMarker(_modifiedColor, w)),
        findsNothing);
    expect(
        find.byWidgetPredicate((w) => _isMarker(_addedColor, w)), findsNothing);

    // Edit the middle line: 'beta' → 'BETA' (one modified region).
    await tester.enterText(find.byType(TextField), 'alpha\nBETA\ngamma\n');
    await tester.pump(const Duration(milliseconds: 300)); // debounce fires
    await tester.pump(const Duration(milliseconds: 100)); // diff completes

    expect(find.byWidgetPredicate((w) => _isMarker(_modifiedColor, w)),
        findsOneWidget);

    // Appending a line is an added marker, not modified.
    await tester.enterText(
        find.byType(TextField), 'alpha\nBETA\ngamma\ndelta\n');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byWidgetPredicate((w) => _isMarker(_modifiedColor, w)),
        findsOneWidget);
    expect(find.byWidgetPredicate((w) => _isMarker(_addedColor, w)),
        findsOneWidget);

    // Unmount the editor so session.dispose() runs inside the test (its mock
    // editorDestroy timer must be pumped, not left pending for teardown).
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));
  });
}
