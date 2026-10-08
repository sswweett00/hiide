import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hiide_flutter/core/backend/settings_service.dart';
import 'package:hiide_flutter/shared/models/todo_issue.dart';

void main() {
  test('TODO scanner returns normalized markers and 1-based lines', () {
    final issues = extractTodos('// TODO: refactor\n// FIXME crash\n// XXX migrate');
    expect(issues, hasLength(3));
    expect(issues[0].kind, 'TODO');
    expect(issues[0].line, 1);
    expect(issues[0].text, 'refactor');
    expect(issues[1].kind, 'FIXME');
    expect(issues[2].kind, 'TODO');
  });

  test('AI endpoint policy only permits HTTPS or loopback HTTP', () async {
    settingsService.resetForTesting();
    SharedPreferences.setMockInitialValues({});
    expect(
      () => settingsService.setAiProviderBaseUrl('remote', 'http://example.com/v1'),
      throwsStateError,
    );
    await settingsService.setAiProviderBaseUrl('local', 'http://127.0.0.1:8000/v1');
    expect(await settingsService.getAiProviderBaseUrls(), {'local': 'http://127.0.0.1:8000/v1'});
  });
}