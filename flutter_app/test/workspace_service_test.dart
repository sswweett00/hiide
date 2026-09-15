// Verifies WorkspaceService.normalizePath: trailing separators are stripped
// for concatenation safety, while root paths and drive roots stay intact.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiide_flutter/core/backend/workspace_service.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('hiide_ws_svc_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('findWelcomeFile locates a README.md in the root', () async {
    File('${tempDir.path}/README.md').writeAsStringSync('# My Project\n');
    final service = WorkspaceService(rootPath: tempDir.path);

    final found = await service.findWelcomeFile(tempDir.path);
    expect(found, isNotNull);
    expect(found!.path, '${tempDir.path}/README.md');
    expect(found.content, contains('My Project'));
  });

  test('findWelcomeFile prefers README.md over README.txt', () async {
    File('${tempDir.path}/README.txt').writeAsStringSync('txt');
    File('${tempDir.path}/README.md').writeAsStringSync('md');
    final service = WorkspaceService(rootPath: tempDir.path);

    final found = await service.findWelcomeFile(tempDir.path);
    expect(found!.path, endsWith('README.md'));
  });

  test('findWelcomeFile returns null for a folder without a README', () async {
    final empty = Directory('${tempDir.path}/no_readme')..createSync();
    final service = WorkspaceService(rootPath: tempDir.path);

    expect(await service.findWelcomeFile(empty.path), isNull);
  });

  test('normalizePath strips trailing separators', () {
    expect(WorkspaceService.normalizePath('/home/kaan/projeler/hiide/'),
        '/home/kaan/projeler/hiide');
    expect(WorkspaceService.normalizePath('/tmp/x//'), '/tmp/x');
    expect(WorkspaceService.normalizePath('  /tmp/x  '), '/tmp/x');
  });

  test('normalizePath keeps root paths intact', () {
    expect(WorkspaceService.normalizePath('/'), '/');
    expect(WorkspaceService.normalizePath('C:\\'), 'C:\\');
    expect(WorkspaceService.normalizePath('C:/'), 'C:/');
  });

  test('normalizePath keeps the original when stripping would empty it', () {
    expect(WorkspaceService.normalizePath('///'), '///');
  });

  test('normalizePath leaves already-clean paths unchanged', () {
    expect(WorkspaceService.normalizePath('/home/kaan'), '/home/kaan');
  });

  test('pathBasename handles posix, windows and root paths', () {
    expect(pathBasename('/home/kaan/projeler/hiide'), 'hiide');
    expect(pathBasename('flutter_app/lib/main.dart'), 'main.dart');
    expect(pathBasename(r'C:\Users\kaan\project'), 'project');
    expect(pathBasename('/tmp/x/'), 'x');
    expect(pathBasename('/'), '/');
  });
}
