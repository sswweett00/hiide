import 'dart:async';

import '../ai_chat_client.dart';
// ignore: unused_import
import 'package:http/http.dart' as http;

// ─── Documentation Generator Agent ───────────────────────────────────────────

/// Generates documentation for code files, functions, classes, and projects.
class DocGeneratorAgent {
  DocGeneratorAgent({required AiChatClient ai}) : _ai = ai;

  final AiChatClient _ai;

  /// Generates doc comments for a specific function or class.
  Future<String> generateDocComments({
    required String code,
    required String filePath,
    String? elementName,
  }) async {
    final lang = _detectLanguage(filePath);

    final response = await _ai.chatCompletion(
      messages: [
        {
          'role': 'system',
          'content': 'You are a documentation expert for $lang code. Generate '
              'proper doc comments for the given code element. Use the '
              'language\'s standard documentation format '
              '(/// for Dart, /** */ for JS/TS, # for Python, /// for Rust). '
              'Include: description, parameters, return value, and examples '
              'where appropriate. Output ONLY the doc comments.',
        },
        {
          'role': 'user',
          'content': 'File: $filePath\n'
              '${elementName != null ? "Element: $elementName\n" : ""}'
              'Code:\n$code',
        },
      ],
      temperature: 0.2,
    );

    if (response.containsKey('error')) return '// Documentation generation failed';
    final choices = (response['choices'] as List?) ?? [];
    if (choices.isEmpty) return '// No response';
    return (choices.first as Map)['message']?['content']?.toString() ?? '';
  }

  /// Generates or updates a README for the project.
  Future<String> generateReadme({
    required String projectStructure,
    required String mainFiles,
    String? existingReadme,
  }) async {
    final response = await _ai.chatCompletion(
      messages: [
        {
          'role': 'system',
          'content': 'Generate a comprehensive README.md for this project. '
              'Include: project description, features, installation, usage, '
              'architecture overview, and contributing guidelines. '
              'Use clean Markdown formatting. Output ONLY the README content.',
        },
        {
          'role': 'user',
          'content': 'Project structure:\n$projectStructure\n\n'
              'Main files:\n$mainFiles\n'
              '${existingReadme != null ? "\nExisting README:\n$existingReadme" : ""}',
        },
      ],
      temperature: 0.3,
    );

    if (response.containsKey('error')) return '# Project\n\nDocumentation generation failed.';
    final choices = (response['choices'] as List?) ?? [];
    if (choices.isEmpty) return '# Project\n\nNo response from model.';
    return (choices.first as Map)['message']?['content']?.toString() ?? '';
  }

  /// Generates a changelog entry from git log.
  Future<String> generateChangelog({
    required String gitLog,
    String? version,
  }) async {
    final response = await _ai.chatCompletion(
      messages: [
        {
          'role': 'system',
          'content': 'Generate a changelog entry from the git log. Use '
              'Keep a Changelog format (https://keepachangelog.com/). '
              'Group changes by: Added, Changed, Fixed, Removed. '
              'Output ONLY the changelog entry in Markdown.',
        },
        {
          'role': 'user',
          'content': '${version != null ? "Version: $version\n\n" : ""}'
              'Git log:\n$gitLog',
        },
      ],
      temperature: 0.2,
    );

    if (response.containsKey('error')) return '## Changelog\n\nGeneration failed.';
    final choices = (response['choices'] as List?) ?? [];
    if (choices.isEmpty) return '## Changelog\n\nNo response.';
    return (choices.first as Map)['message']?['content']?.toString() ?? '';
  }

  String _detectLanguage(String path) {
    if (path.endsWith('.dart')) return 'Dart';
    if (path.endsWith('.zig')) return 'Zig';
    if (path.endsWith('.py')) return 'Python';
    if (path.endsWith('.ts') || path.endsWith('.tsx')) return 'TypeScript';
    if (path.endsWith('.js') || path.endsWith('.jsx')) return 'JavaScript';
    if (path.endsWith('.rs')) return 'Rust';
    if (path.endsWith('.go')) return 'Go';
    return 'code';
  }
}
