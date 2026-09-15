// Verifies the startup folder-selection system: first-run auto-open, restore
// of a persisted workspace, invalid-path handling (error + disabled confirm),
// the hidden-files toggle, and persisting the selection + recents.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hiide_flutter/core/backend/mock_backend_service.dart';
import 'package:hiide_flutter/core/backend/settings_service.dart';
import 'package:hiide_flutter/core/providers/backend_provider.dart';
import 'package:hiide_flutter/core/routing/router.dart';
import 'package:hiide_flutter/core/theme/app_themes.dart';
import 'package:hiide_flutter/features/editor/editor_screen.dart';
import 'package:hiide_flutter/shared/providers/editor_providers.dart';

const _dialogTitle = 'Dosya Yöneticisi — Proje Klasörü Seç';
const _confirmLabel = 'Bu Klasörü Çalışma Alanı Yap';

Future<void> _pumpEditor(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppThemes.darkTheme,
        home: const Scaffold(body: EditorScreen()),
      ),
    ),
  );
  await tester.pump(); // first frame
  // Let the async first-run/restore logic and the dialog open settle.
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
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
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late MockBackendService backend;

  setUpAll(_loadAppFonts);

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('hiide_folder_test');
    backend = MockBackendService();
    settingsService.resetForTesting();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    backend.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ProviderContainer makeContainer({
    String? startPath,
    bool restored = false,
  }) {
    return ProviderContainer(
      overrides: [
        backendServiceProvider.overrideWithValue(backend),
        if (startPath != null)
          workspaceRootProvider.overrideWith((ref) => startPath),
        workspaceRestoredProvider.overrideWith((ref) => restored),
      ],
    );
  }

  testWidgets('first run auto-opens the folder browser and persists the pick',
      (tester) async {
    final container = makeContainer(startPath: tempDir.path);
    addTearDown(container.dispose);

    await _pumpEditor(tester, container);

    // No stored workspace → the browser dialog opened by itself.
    expect(find.text(_dialogTitle), findsOneWidget);

    // Confirm the current folder as the workspace.
    await tester.tap(find.widgetWithText(ElevatedButton, _confirmLabel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(container.read(workspaceRootProvider), tempDir.path);
    // Persisted for the next launch + added to recents.
    expect(await settingsService.getLastWorkspace(), tempDir.path);
    expect(container.read(recentWorkspacesProvider), contains(tempDir.path));
  });

  testWidgets('a restored workspace is not re-picked', (tester) async {
    // Mirrors what main() does after resolveStartupWorkspace() succeeds.
    final container = makeContainer(startPath: tempDir.path, restored: true);
    addTearDown(container.dispose);

    await _pumpEditor(tester, container);

    expect(find.text(_dialogTitle), findsNothing);
    expect(container.read(workspaceRootProvider), tempDir.path);
  });

  test('resolveStartupWorkspace returns an existing stored workspace',
      () async {
    SharedPreferences.setMockInitialValues({'last_workspace': tempDir.path});
    expect(await resolveStartupWorkspace(), tempDir.path);
  });

  test('resolveStartupWorkspace clears and ignores a vanished workspace',
      () async {
    SharedPreferences.setMockInitialValues(
      {'last_workspace': '/nonexistent/vanished-workspace'},
    );
    expect(await resolveStartupWorkspace(), isNull);
    expect(await settingsService.getLastWorkspace(), isNull);
  });

  testWidgets('no stored workspace opens the browser once', (tester) async {
    final container = makeContainer();
    addTearDown(container.dispose);

    await _pumpEditor(tester, container);

    expect(find.text(_dialogTitle), findsOneWidget);
  });

  testWidgets('an unreadable initial path shows an error and disables confirm',
      (tester) async {
    final bad = '${tempDir.path}/does-not-exist';
    final container = makeContainer(startPath: bad);
    addTearDown(container.dispose);

    await _pumpEditor(tester, container);

    expect(find.text(_dialogTitle), findsOneWidget);
    expect(find.textContaining('Klasör bulunamadı'), findsOneWidget);

    final button = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, _confirmLabel),
    );
    expect(button.onPressed, isNull, reason: 'invalid folder must not select');
  });

  testWidgets('hidden files are hidden by default and toggleable',
      (tester) async {
    File('${tempDir.path}/visible.txt').writeAsStringSync('x');
    File('${tempDir.path}/.hidden').writeAsStringSync('y');
    final container = makeContainer(startPath: tempDir.path);
    addTearDown(container.dispose);

    await _pumpEditor(tester, container);

    expect(find.text(_dialogTitle), findsOneWidget);
    expect(find.text('visible.txt'), findsOneWidget);
    expect(find.text('.hidden'), findsNothing);

    // Toggle hidden files on.
    await tester.tap(find.byIcon(Icons.visibility_off));
    await tester.pump();

    expect(find.text('.hidden'), findsOneWidget);
  });

  testWidgets('workspace picker opens a folder and activates it',
      (tester) async {
    final container = makeContainer(startPath: tempDir.path);
    addTearDown(container.dispose);
    final router = GoRouter(
      initialLocation: '/workspace-picker',
      routes: [
        GoRoute(
            path: '/workspace-picker',
            builder: (context, state) => const WorkspacePickerScreen()),
        GoRoute(
            path: '/dashboard',
            builder: (context, state) =>
                const Scaffold(body: Center(child: Text('dashboard')))),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppThemes.darkTheme,
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Select Workspace'), findsOneWidget);

    // Open the real browser dialog and confirm the current folder.
    await tester.tap(find.widgetWithText(ElevatedButton, 'Open Workspace'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text(_dialogTitle), findsOneWidget);
    await tester.tap(find.widgetWithText(ElevatedButton, _confirmLabel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(container.read(workspaceRootProvider), tempDir.path);
    expect(await settingsService.getLastWorkspace(), tempDir.path);
  });

  testWidgets('workspace picker lists recents as quick-open entries',
      (tester) async {
    final container = makeContainer();
    addTearDown(container.dispose);
    container.read(recentWorkspacesProvider.notifier).state = [
      tempDir.path,
    ];

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppThemes.darkTheme,
          home: const WorkspacePickerScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('SON KLASÖRLER'), findsOneWidget);
    expect(find.text(tempDir.path), findsOneWidget);
  });

  testWidgets('navigating into a subfolder updates the selectable path',
      (tester) async {
    final sub = Directory('${tempDir.path}/proj')..createSync();
    final container = makeContainer(startPath: tempDir.path);
    addTearDown(container.dispose);

    await _pumpEditor(tester, container);

    await tester.tap(find.text('proj'));
    await tester.pump();

    // The path bar now shows the subfolder; selecting it activates that root.
    await tester.tap(find.widgetWithText(ElevatedButton, _confirmLabel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(container.read(workspaceRootProvider), sub.path);
    expect(await settingsService.getLastWorkspace(), sub.path);
  });
}
