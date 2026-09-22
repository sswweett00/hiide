// Verifies the editor's layout correctness: the text field and the
// line-number gutter scroll in lockstep (28px lines, linked controllers),
// and the editor with an active tab renders without overflow at narrow widths.

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

Future<void> _pumpEditor(
  WidgetTester tester, {
  required Size size,
  required String content,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final backend = MockBackendService();
  addTearDown(backend.dispose);

  const tab =
      EditorTab(id: 't1', title: 'code.txt', path: '/tmp/ed.txt', content: '');
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
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUpAll(_loadAppFonts);

  testWidgets('text scroll keeps the line-number gutter in lockstep',
      (tester) async {
    final content = List.generate(200, (i) => 'line ${i + 1}').join('\n');
    await _pumpEditor(tester, size: const Size(1280, 720), content: content);

    // Top of file: line 1 visible, a deeper line not yet built (the viewport
    // shows roughly lines 1–23 of a 200-line file).
    expect(find.text('1'), findsOneWidget);
    expect(find.text('25'), findsNothing);

    // Scrolling the text field scrolls the gutter (shared 28px rows).
    await tester.drag(find.byKey(const Key('editor-code-text-field')), const Offset(0, -300));
    await tester.pump();

    expect(find.text('1'), findsNothing);
    expect(find.text('25'), findsOneWidget);

    await _unmount(tester);
  });

  testWidgets('editor with an active tab renders without overflow at 500px',
      (tester) async {
    final content = List.generate(80, (i) => 'line ${i + 1}').join('\n');
    final errors = <FlutterErrorDetails>[];
    final oldHandler = FlutterError.onError;
    FlutterError.onError = (details) => errors.add(details);

    await _pumpEditor(tester, size: const Size(500, 800), content: content);
    await tester.pump(const Duration(milliseconds: 300));

    FlutterError.onError = oldHandler;
    final overflows = errors.where((e) => e.toString().contains('overflowed'));
    expect(overflows, isEmpty, reason: 'overflowed: $overflows');

    await _unmount(tester);
  });
}
