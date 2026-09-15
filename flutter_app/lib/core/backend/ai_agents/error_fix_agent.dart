import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../ai_chat_client.dart';
import '../backend_service.dart';

// ─── Types ───────────────────────────────────────────────────────────────────

class ErrorFix {
  final String filePath;
  final int line;
  final String originalCode;
  final String fixedCode;
  final String explanation;
  final double confidence; // 0.0 - 1.0

  const ErrorFix({
    required this.filePath,
    required this.line,
    required this.originalCode,
    required this.fixedCode,
    required this.explanation,
    this.confidence = 0.8,
  });
}

// ─── Error Fix Agent ─────────────────────────────────────────────────────────

/// Analyzes compiler/runtime errors and generates targeted fixes.
/// Sends the error message + surrounding code to the model and gets
/// back a diff-style fix.
class ErrorFixAgent {
  ErrorFixAgent({
    required AiChatClient ai,
    required BackendService backend,
    required String workspaceRoot,
  })  : _ai = ai,
        _backend = backend,
        _workspaceRoot = workspaceRoot;

  final AiChatClient _ai;
  final BackendService _backend;
  final String _workspaceRoot;

  /// Analyzes an error and suggests a fix for the given file.
  Future<ErrorFix?> fixError({
    required String filePath,
    required String errorCode,
    required String fileContent,
    int? errorLine,
  }) async {
    // Extract context around the error line
    final lines = fileContent.split('\n');
    final contextStart = (errorLine != null ? errorLine - 10 : 0).clamp(0, lines.length);
    final contextEnd = (errorLine != null ? errorLine + 10 : lines.length).clamp(0, lines.length);
    final context = lines.sublist(contextStart, contextEnd).join('\n');

    final response = await _ai.chatCompletion(
      messages: [
        {
          'role': 'system',
          'content': '''You are a debugging expert. Given a compile/runtime error
and the surrounding code, produce a fix.

Output JSON:
{
  "line": <line number in the full file>,
  "original": "<exact original code to replace>",
  "fixed": "<replacement code>",
  "explanation": "<brief explanation>",
  "confidence": <0.0 to 1.0>
}

Rules:
- Only fix the actual error, don't refactor unrelated code
- Keep changes minimal and surgical
- Output ONLY valid JSON, no markdown''',
        },
        {
          'role': 'user',
          'content': 'Error in $filePath'
              '${errorLine != null ? ' at line $errorLine' : ''}:\n'
              '$errorCode\n\n'
              'Context (lines $contextStart-$contextEnd):\n```dart\n$context\n```',
        },
      ],
      temperature: 0.1,
    );

    if (response.containsKey('error')) return null;

    final choices = (response['choices'] as List?) ?? [];
    if (choices.isEmpty) return null;

    final text = (choices.first as Map)['message']?['content']?.toString() ?? '';
    return _parseFix(filePath, text);
  }

  /// Analyzes a build/test error log and suggests multiple fixes.
  Future<List<ErrorFix>> fixBuildErrors({
    required String errorLog,
    required String workingDir,
  }) async {
    final response = await _ai.chatCompletion(
      messages: [
        {
          'role': 'system',
          'content': '''You are a build error analyzer. Given an error log from
a build or test run, identify all fixable errors and suggest fixes.

Output a JSON array:
[{
  "file": "<file path>",
  "line": <line number>,
  "original": "<code to replace>",
  "fixed": "<replacement code>",
  "explanation": "<what you fixed>",
  "confidence": <0.0 to 1.0>
}]

Focus on the first 5 most critical errors. Output ONLY valid JSON.''',
        },
        {
          'role': 'user',
          'content': 'Error log from $workingDir:\n\n$errorLog',
        },
      ],
      temperature: 0.1,
    );

    if (response.containsKey('error')) return [];

    final choices = (response['choices'] as List?) ?? [];
    if (choices.isEmpty) return [];

    final text = (choices.first as Map)['message']?['content']?.toString() ?? '';
    return _parseFixes(text);
  }

  ErrorFix? _parseFix(String filePath, String text) {
    try {
      var json = text.trim();
      if (json.contains('```')) {
        final match = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(json);
        if (match != null) json = match.group(1)!.trim();
      }
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      return ErrorFix(
        filePath: filePath,
        line: decoded['line'] as int? ?? 0,
        originalCode: decoded['original']?.toString() ?? '',
        fixedCode: decoded['fixed']?.toString() ?? '',
        explanation: decoded['explanation']?.toString() ?? '',
        confidence: (decoded['confidence'] as num?)?.toDouble() ?? 0.8,
      );
    } catch (e) {
      debugPrint('ErrorFix parse error: $e');
      return null;
    }
  }

  List<ErrorFix> _parseFixes(String text) {
    try {
      var json = text.trim();
      if (json.contains('```')) {
        final match = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(json);
        if (match != null) json = match.group(1)!.trim();
      }
      final start = json.indexOf('[');
      final end = json.lastIndexOf(']');
      if (start < 0 || end < 0) return [];
      json = json.substring(start, end + 1);

      final decoded = jsonDecode(json) as List;
      return decoded.map((item) {
        final map = item as Map<String, dynamic>;
        return ErrorFix(
          filePath: map['file']?.toString() ?? '',
          line: map['line'] as int? ?? 0,
          originalCode: map['original']?.toString() ?? '',
          fixedCode: map['fixed']?.toString() ?? '',
          explanation: map['explanation']?.toString() ?? '',
          confidence: (map['confidence'] as num?)?.toDouble() ?? 0.8,
        );
      }).toList();
    } catch (e) {
      debugPrint('ErrorFix parse error: $e');
      return [];
    }
  }
}
