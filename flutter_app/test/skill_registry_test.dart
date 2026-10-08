import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiide_flutter/core/backend/skill_registry.dart';

void main() {
  test('loads project skills and matches them on demand', () async {
    final root = await Directory.systemTemp.createTemp('hiide_skill_test_');
    addTearDown(() => root.delete(recursive: true));

    final skills = Directory(
      root.path + Platform.pathSeparator + '.hiide' + Platform.pathSeparator + 'skills',
    );
    await skills.create(recursive: true);
    await File(skills.path + Platform.pathSeparator + 'testing.md').writeAsString(
      '''
---
name: Verification
description: Verification workflow
keywords: test, verify
---
Run the smallest meaningful test first.
''',
    );

    const registry = HiideSkillRegistry();
    final loaded = await registry.load(root.path);
    expect(loaded, hasLength(1));
    expect(loaded.single.id, 'testing');

    final context = await registry.contextFor(root.path, 'verify this change');
    expect(context, contains('Verification'));
    expect(context, contains('smallest meaningful test'));
  });
}