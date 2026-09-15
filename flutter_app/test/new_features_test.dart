// Unit tests for the new-feature pure logic: the workspace TODO/FIXME
// scanner, the markdown renderer, the AI completion prompt builder + API
// parsing, and the language/icon helpers.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hiide_flutter/core/backend/groq_ai_service.dart';
import 'package:hiide_flutter/core/theme/app_themes.dart';
import 'package:hiide_flutter/features/editor/editor_screen.dart';
import 'package:hiide_flutter/features/editor/markdown_preview.dart';
import 'package:hiide_flutter/shared/models/editor_tab.dart';
import 'package:hiide_flutter/shared/models/todo_issue.dart';
import 'package:hiide_flutter/shared/providers/editor_providers.dart';
import 'package:hiide_flutter/shared/widgets/ide_shell.dart';

void main() {
  group('TODO/FIXME scanner', () {
    test('extractTodos finds markers with 1-based lines', () {
      const content = '// TODO: refactor this\n'
          'void main() {\n'
          '  // FIXME crash here\n'
          "  print('hello'); // HACK: ugly\n"
          '}';
      final matches = extractTodos(content);
      expect(matches, hasLength(3));
      expect(matches[0].line, 1);
      expect(matches[0].kind, 'TODO');
      expect(matches[0].text, 'refactor this');
      expect(matches[1].line, 3);
      expect(matches[1].kind, 'FIXME');
      expect(matches[1].text, 'crash here');
      expect(matches[2].kind, 'HACK');
    });

    test('extractTodos is case-insensitive and maps XXX to TODO', () {
      final matches = extractTodos('todo lowercase\nXXX mapped');
      expect(matches[0].kind, 'TODO');
      expect(matches[1].kind, 'TODO');
      expect(matches[1].text, 'mapped');
    });

    test('extractTodos ignores markers inside words', () {
      expect(extractTodos('notodo here'), isEmpty);
      expect(extractTodos('  '), isEmpty);
    });
  });

  group('Markdown renderer', () {
    test('parseMarkdown builds blocks', () {
      final blocks = parseMarkdown('''
# Başlık

Normal paragraf metni.

- a
- b

```dart
void main() {}
```

> alıntı
''');
      expect(blocks[0].type, 'h1');
      expect(blocks[0].text, 'Başlık');
      expect(blocks[1].type, 'p');
      expect(blocks[2].type, 'ul');
      expect(blocks[2].items, ['a', 'b']);
      expect(blocks[3].type, 'code');
      expect(blocks[3].text, 'void main() {}');
      expect(blocks[4].type, 'quote');
    });

    test('inline spans: bold, code and links', () {
      final spans = markdownInlineSpans(
        '**kalın** ve `kod` ve [bağ](https://x.dev)',
        const TextStyle(fontSize: 13),
        codeColor: const Color(0xFF22D3EE),
        linkColor: const Color(0xFF58A6FF),
      );
      final texts = spans
          .whereType<TextSpan>()
          .map((s) => s.text)
          .where((t) => t != null)
          .join('|');
      expect(texts, 'kalın| ve |kod| ve |bağ');
      expect(
          spans.whereType<TextSpan>().first.style?.fontWeight, FontWeight.bold);
    });
  });

  group('AI completion', () {
    test('buildCompletionPrompt includes language, indent and caret', () {
      final prompt = buildCompletionPrompt(
        language: 'Dart',
        linePrefix: '  final x = ',
        indentation: '  ',
      );
      expect(prompt, contains('Language: Dart'));
      expect(prompt, contains('Indentation: 2 spaces'));
      expect(prompt, contains('final x = |'));
    });

    test('completeCode parses the assistant content', () async {
      final client = MockClient((request) async {
        expect(request.url.path, endsWith('/chat/completions'));
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '  42;  '}
              }
            ]
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = GroqAiService(apiKey: 'test', client: client);
      final result = await service.completeCode('x |');
      expect(result, '42;');
    });

    test('completeCode returns null when the API errors', () async {
      final client = MockClient((request) async => http.Response('{}', 500));
      final service = GroqAiService(apiKey: 'test', client: client);
      expect(await service.completeCode('x |'), isNull);
    });
  });

  group('Find & replace matching', () {
    test('plain mode is case-insensitive by default', () {
      final (ranges, error) = findTextRanges(
        'Foo foo FOO',
        'foo',
        caseSensitive: false,
        regex: false,
      );
      expect(error, isNull);
      expect(ranges, [(0, 3), (4, 7), (8, 11)]);
    });

    test('case-sensitive mode only matches exact case', () {
      final (ranges, _) = findTextRanges(
        'Foo foo FOO',
        'foo',
        caseSensitive: true,
        regex: false,
      );
      expect(ranges, [(4, 7)]);
    });

    test('regex mode matches patterns', () {
      final (ranges, error) = findTextRanges(
        'abc 123 xyz 456',
        r'\d+',
        caseSensitive: false,
        regex: true,
      );
      expect(error, isNull);
      expect(ranges, [(4, 7), (12, 15)]);
    });

    test('regex respects the case toggle', () {
      final (ranges, _) = findTextRanges(
        'Foo foo',
        'foo',
        caseSensitive: true,
        regex: true,
      );
      // Only the exact-case "foo" matches, not "Foo".
      expect(ranges, [(4, 7)]);
    });

    test('invalid regex returns an error and no ranges', () {
      final (ranges, error) = findTextRanges(
        'abc',
        '([',
        caseSensitive: false,
        regex: true,
      );
      expect(ranges, isEmpty);
      expect(error, isNotNull);
      expect(error, contains('Geçersiz desen'));
    });

    test('empty query yields no matches', () {
      final (ranges, error) = findTextRanges(
        'abc',
        '',
        caseSensitive: false,
        regex: false,
      );
      expect(ranges, isEmpty);
      expect(error, isNull);
    });

    test('highlightTextSpans paints matches and the active one distinctly', () {
      const base = TextStyle(fontSize: 13);
      const match = Color(0x3322D3EE);
      const active = Color(0x59FFA657);

      final span = highlightTextSpans(
        'foo bar foo',
        const [(0, 3), (8, 11)],
        baseStyle: base,
        matchColor: match,
        activeColor: active,
        activeIndex: 1,
      );

      expect(span.children, hasLength(3));
      final first = span.children![0] as TextSpan;
      final middle = span.children![1] as TextSpan;
      final last = span.children![2] as TextSpan;
      expect(first.text, 'foo');
      expect(first.style?.backgroundColor, match);
      expect(middle.text, ' bar ');
      expect(middle.style?.backgroundColor, isNull);
      expect(last.text, 'foo');
      expect(last.style?.backgroundColor, active);
    });

    test('highlightTextSpans clamps stale ranges after edits', () {
      const base = TextStyle(fontSize: 13);
      final span = highlightTextSpans(
        'hi',
        const [(100, 105)],
        baseStyle: base,
        matchColor: const Color(0x3322D3EE),
        activeColor: const Color(0x59FFA657),
      );
      // Out-of-range match is dropped, the text survives — no crash.
      final only = span.children!.single as TextSpan;
      expect(only.text, 'hi');
      expect(only.style?.backgroundColor, isNull);
      expect(span.toPlainText(), 'hi');
    });
  });

  group('File helpers', () {
    test('languageForPath detects known extensions', () {
      expect(languageForPath('/a/b/main.dart'), 'Dart');
      expect(languageForPath('src/main.zig'), 'Zig');
      expect(languageForPath('README.md'), 'Markdown');
      expect(languageForPath('pubspec.yaml'), 'YAML');
      expect(languageForPath('file.xyz'), '—');
    });

    test('withRecentFile keeps most recent first, max 10, deduped', () {
      var recents = <RecentFile>[];
      for (var i = 1; i <= 12; i++) {
        recents = withRecentFile(
            recents,
            EditorTab(
              id: 't$i',
              title: 'file$i.dart',
              path: '/ws/file$i.dart',
            ));
      }
      // Reopen file 3 — moves to front, no duplicate.
      recents = withRecentFile(
          recents,
          const EditorTab(
            id: 't3b',
            title: 'file3.dart',
            path: '/ws/file3.dart',
          ));

      expect(recents, hasLength(10));
      expect(recents.first.path, '/ws/file3.dart');
      expect(recents.where((r) => r.path == '/ws/file3.dart'), hasLength(1));
    });
  });

  group('Zen mode', () {
    testWidgets('zen hides the explorer, bottom panel and status bar',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppThemes.darkTheme,
            home: const IdeShell(child: SizedBox.expand()),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Explorer'), findsOneWidget);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(IdeShell)),
      );
      container.read(zenModeProvider.notifier).state = true;
      await tester.pump();

      expect(find.text('Explorer'), findsNothing);
    });
  });
}
