import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ai_chat_client.dart';
import '../backend_service.dart';

// ─── Types ───────────────────────────────────────────────────────────────────

class GeneratedTest {
  final String testCode;
  final String fileName;
  final String description;
  final int testCount;

  const GeneratedTest({
    required this.testCode,
    required this.fileName,
    required this.description,
    required this.testCount,
  });
}

// ─── Test Generator Agent ────────────────────────────────────────────────────

/// Generates unit tests for a given function/class/file. Detects the test
/// framework automatically and produces runnable test code.
class TestGeneratorAgent {
  TestGeneratorAgent({
    required AiChatClient ai,
    required BackendService backend,
    required String workspaceRoot,
  })  : _ai = ai,
        _backend = backend,
        _workspaceRoot = workspaceRoot;

  final AiChatClient _ai;
  final BackendService _backend;
  final String _workspaceRoot;

  /// Generates tests for the given code. [language] helps the model pick
  /// the right test framework (dart, zig, python, javascript, etc.).
  Future<GeneratedTest> generateTests({
    required String code,
    required String filePath,
    String? language,
  }) async {
    final lang = language ?? _detectLanguage(filePath);
    final framework = _testFramework(lang);

    final response = await _ai.chatCompletion(
      messages: [
        {
          'role': 'system',
          'content': '''You are an expert test engineer. Generate comprehensive
unit tests for the given code.

Language: $lang
Test framework: $framework

Requirements:
- Cover normal cases, edge cases, and error cases
- Include descriptive test names
- Use proper assertions
- Mock external dependencies where needed
- Keep tests independent (no shared state)
- Follow the project's existing test conventions
- Output ONLY the test code (no explanation)

Generate at least 3-5 test cases.''',
        },
        {
          'role': 'user',
          'content': 'Generate tests for this code from $filePath:\n\n$code',
        },
      ],
      temperature: 0.2,
    );

    if (response.containsKey('error')) {
      return GeneratedTest(
        testCode: '// Error generating tests: ${response['error']}',
        fileName: _testFileName(filePath),
        description: 'Failed to generate tests',
        testCount: 0,
      );
    }

    final choices = (response['choices'] as List?) ?? [];
    if (choices.isEmpty) {
      return GeneratedTest(
        testCode: '// No response from model',
        fileName: _testFileName(filePath),
        description: 'No response',
        testCount: 0,
      );
    }

    var testCode = (choices.first as Map)['message']?['content']?.toString() ?? '';
    // Clean markdown fences
    if (testCode.contains('```')) {
      final match =
          RegExp(r'```(?:\w+)?\s*([\s\S]*?)```').firstMatch(testCode);
      if (match != null) testCode = match.group(1)!.trim();
    }

    // Count test cases
    final testCount = RegExp(r'(?:test|it)\s*\(').allMatches(testCode).length;

    return GeneratedTest(
      testCode: testCode,
      fileName: _testFileName(filePath),
      description: 'Generated $testCount test(s) for ${_baseName(filePath)}',
      testCount: testCount,
    );
  }

  /// Generates tests and writes them to disk.
  Future<bool> generateAndSave({
    required String code,
    required String filePath,
    String? language,
  }) async {
    final test = await generateTests(
      code: code,
      filePath: filePath,
      language: language,
    );

    if (test.testCount == 0) return false;

    try {
      await _backend.executeAgentTool(
        'file.write',
        {
          'path': test.fileName,
          'content': test.testCode,
        },
        workspaceRoot: _workspaceRoot,
      );
      return true;
    } catch (e) {
      debugPrint('Test save error: $e');
      return false;
    }
  }

  String _detectLanguage(String path) {
    if (path.endsWith('.dart')) return 'dart';
    if (path.endsWith('.zig')) return 'zig';
    if (path.endsWith('.py')) return 'python';
    if (path.endsWith('.ts') || path.endsWith('.tsx')) return 'typescript';
    if (path.endsWith('.js') || path.endsWith('.jsx')) return 'javascript';
    if (path.endsWith('.rs')) return 'rust';
    if (path.endsWith('.go')) return 'go';
    return 'unknown';
  }

  String _testFramework(String lang) {
    return switch (lang) {
      'dart' => 'flutter_test (package:flutter_test)',
      'zig' => 'std.testing (Zig built-in)',
      'python' => 'pytest',
      'typescript' => 'jest',
      'javascript' => 'jest',
      'rust' => '#[test] (built-in)',
      'go' => 'testing (built-in)',
      _ => 'any appropriate framework',
    };
  }

  String _testFileName(String filePath) {
    final parts = filePath.split('/');
    final name = parts.last;
    final dir = parts.length > 1 ? parts.sublist(0, parts.length - 1).join('/') : '.';

    if (name.endsWith('.dart')) {
      final base = name.substring(0, name.length - 5);
      return '$dir/${base}_test.dart';
    }
    if (name.endsWith('.py')) {
      final base = name.substring(0, name.length - 3);
      return '$dir/test_${base}.py';
    }
    if (name.endsWith('.js') || name.endsWith('.ts')) {
      final base = name.substring(0, name.lastIndexOf('.'));
      return '$dir/${base}.test.${name.split('.').last}';
    }
    return '$dir/test_$name';
  }

  String _baseName(String path) => path.split('/').last;
}
