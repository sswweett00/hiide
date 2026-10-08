import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hiide_flutter/core/backend/settings_service.dart';
import 'package:hiide_flutter/core/routing/router.dart';
import 'package:hiide_flutter/core/theme/app_themes.dart';
import 'package:hiide_flutter/shared/providers/workspace_providers.dart';
import 'package:hiide_flutter/shared/widgets/folder_browser_dialog.dart';

const _dialogTitle = 'Dosya Yöneticisi — Proje Klasörü Seç';
const _confirmLabel = 'Bu Klasörü Çalışma Alanı Yap';

void main() {
  late Directory tempDir;
  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('hiide_folder_test');
    settingsService.resetForTesting();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() { if (tempDir.existsSync()) tempDir.deleteSync(recursive: true); });

  Future<void> pumpBrowser(WidgetTester tester, {required String path}) async {
    await tester.pumpWidget(MaterialApp(theme: AppThemes.darkTheme, home: Scaffold(body: FolderBrowserDialog(initialPath: path))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('folder browser selects an existing workspace', (tester) async {
    final future = showDialog<String>(
      context: tester.element(find.byType(Scaffold)),
      builder: (_) => FolderBrowserDialog(initialPath: tempDir.path),
    );
    await tester.pump();
    expect(find.text(_dialogTitle), findsOneWidget);
    final button = tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, _confirmLabel));
    expect(button.onPressed, isNotNull);
    await tester.tap(find.widgetWithText(ElevatedButton, _confirmLabel));
    expect(await future, tempDir.path);
  });

  testWidgets('unreadable or missing workspace disables confirm', (tester) async {
    await pumpBrowser(tester, path: tempDir.path + '/missing');
    expect(find.text(_dialogTitle), findsOneWidget);
    expect(find.textContaining('Klasör bulunamadı'), findsOneWidget);
    final button = tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, _confirmLabel));
    expect(button.onPressed, isNull);
  });

  testWidgets('hidden files are hidden by default and toggleable', (tester) async {
    File(tempDir.path + '/visible.txt').writeAsStringSync('x');
    File(tempDir.path + '/.hidden').writeAsStringSync('y');
    await pumpBrowser(tester, path: tempDir.path);
    expect(find.text('visible.txt'), findsOneWidget);
    expect(find.text('.hidden'), findsNothing);
    await tester.tap(find.byIcon(Icons.visibility_off));
    await tester.pump();
    expect(find.text('.hidden'), findsOneWidget);
  });

  testWidgets('navigating into a subfolder changes the selectable path', (tester) async {
    Directory(tempDir.path + '/proj').createSync();
    await pumpBrowser(tester, path: tempDir.path);
    await tester.tap(find.text('proj'));
    await tester.pump();
    expect(find.text(tempDir.path + '/proj'), findsOneWidget);
  });

  test('resolveStartupWorkspace returns an existing stored workspace', () async {
    SharedPreferences.setMockInitialValues({'last_workspace': tempDir.path});
    expect(await resolveStartupWorkspace(), tempDir.path);
  });

  test('resolveStartupWorkspace clears a vanished workspace', () async {
    SharedPreferences.setMockInitialValues({'last_workspace': tempDir.path + '/gone'});
    expect(await resolveStartupWorkspace(), isNull);
    expect(await settingsService.getLastWorkspace(), isNull);
  });

  testWidgets('workspace picker shows recent workspaces', (tester) async {
    final container = ProviderContainer(overrides: [
      recentWorkspacesProvider.overrideWith((ref) => [tempDir.path]),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppThemes.darkTheme, home: const WorkspacePickerScreen()),
    ));
    await tester.pump();
    expect(find.text('SON KLASÖRLER'), findsOneWidget);
    expect(find.text(tempDir.path), findsOneWidget);
  });
}