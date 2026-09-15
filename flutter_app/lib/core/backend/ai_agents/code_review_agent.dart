import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../ai_chat_client.dart';
import '../backend_service.dart';

// ─── Types ───────────────────────────────────────────────────────────────────

enum ReviewSeverity { info, warning, error, critical }

enum ReviewCategory { bug, security, performance, style, logic, test }

class ReviewFinding {
  final int line;
  final ReviewSeverity severity;
  final ReviewCategory category;
  final String message;
  final String? suggestion;

  const ReviewFinding({
    required this.line,
    required this.severity,
    required this.category,
    required this.message,
    this.suggestion,
  });
}

class ReviewResult {
  final String filePath;
  final List<ReviewFinding> findings;
  final int score; // 0-100
  final String summary;

  const ReviewResult({
    required this.filePath,
    required this.findings,
    required this.score,
    required this.summary,
  });
}

// ─── Code Review Agent ───────────────────────────────────────────────────────

/// Analyzes code files for bugs, security issues, performance problems,
/// and style violations. Returns structured findings with line numbers.
class CodeReviewAgent {
  CodeReviewAgent({
    required AiChatClient ai,
    required BackendService backend,
    required String workspaceRoot,
  })  : _ai = ai,
        _backend = backend,
        _workspaceRoot = workspaceRoot;

  final AiChatClient _ai;
  final BackendService _backend;
  final String _workspaceRoot;

  /// Reviews a single file and returns structured findings.
  Future<ReviewResult> reviewFile(String filePath, String content) async {
    final response = await _ai.chatCompletion(
      messages: [
        {
          'role': 'system',
          'content': '''You are a senior code reviewer. Analyze the given code
file for issues. Output a JSON array of findings. Each finding:
{
  "line": <line number>,
  "severity": "info"|"warning"|"error"|"critical",
  "category": "bug"|"security"|"performance"|"style"|"logic"|"test",
  "message": "description of the issue",
  "suggestion": "optional fix suggestion"
}

Be specific and actionable. Focus on real issues, not style nitpicks.
Score the file 0-100 (100 = perfect). Output ONLY valid JSON.''',
        },
        {
          'role': 'user',
          'content': 'Review this file ($filePath):\n\n$content',
        },
      ],
      temperature: 0.1,
    );

    if (response.containsKey('error')) {
      return ReviewResult(
        filePath: filePath,
        findings: [],
        score: 50,
        summary: 'Review failed: ${response['error']}',
      );
    }

    final choices = (response['choices'] as List?) ?? [];
    if (choices.isEmpty) {
      return ReviewResult(
        filePath: filePath,
        findings: [],
        score: 50,
        summary: 'No response from model.',
      );
    }

    final text = (choices.first as Map)['message']?['content']?.toString() ?? '';
    return _parseReview(filePath, text);
  }

  /// Reviews the entire workspace (top-level files only, capped).
  Future<List<ReviewResult>> reviewWorkspace() async {
    final results = <ReviewResult>[];
    try {
      final result = await _backend.executeAgentTool(
        'file.list',
        {'path': '.'},
        workspaceRoot: _workspaceRoot,
      );
      if (!result.ok) return results;

      final decoded = jsonDecode(result.output) as List;
      for (final item in decoded) {
        final map = item as Map<String, dynamic>;
        if (map['kind'] == 'directory') continue;
        final name = map['name']?.toString() ?? '';
        if (_skipFile(name)) continue;

        try {
          final fileResult = await _backend.executeAgentTool(
            'file.read',
            {'path': name},
            workspaceRoot: _workspaceRoot,
          );
          if (fileResult.ok && fileResult.output.length < 100000) {
            results.add(await reviewFile(name, fileResult.output));
          }
        } catch (_) {}
      }
    } catch (_) {}
    return results;
  }

  bool _skipFile(String name) {
    return name.startsWith('.') ||
        name.endsWith('.lock') ||
        name.endsWith('.bin') ||
        name.endsWith('.generated') ||
        name == 'pubspec.lock';
  }

  ReviewResult _parseReview(String filePath, String text) {
    try {
      var json = text.trim();
      if (json.contains('```')) {
        final match = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(json);
        if (match != null) json = match.group(1)!.trim();
      }
      final start = json.indexOf('[');
      final end = json.lastIndexOf(']');
      if (start < 0 || end < 0) {
        return ReviewResult(
          filePath: filePath,
          findings: [],
          score: 50,
          summary: text,
        );
      }
      json = json.substring(start, end + 1);
      final decoded = jsonDecode(json) as List;

      final findings = decoded.map((item) {
        final map = item as Map<String, dynamic>;
        return ReviewFinding(
          line: map['line'] as int? ?? 0,
          severity: ReviewSeverity.values.firstWhere(
            (s) => s.name == map['severity'],
            orElse: () => ReviewSeverity.info,
          ),
          category: ReviewCategory.values.firstWhere(
            (c) => c.name == map['category'],
            orElse: () => ReviewCategory.style,
          ),
          message: map['message']?.toString() ?? '',
          suggestion: map['suggestion']?.toString(),
        );
      }).toList();

      final criticalCount =
          findings.where((f) => f.severity == ReviewSeverity.critical).length;
      final errorCount =
          findings.where((f) => f.severity == ReviewSeverity.error).length;
      final warningCount =
          findings.where((f) => f.severity == ReviewSeverity.warning).length;
      final score =
          (100 - criticalCount * 20 - errorCount * 10 - warningCount * 3)
              .clamp(0, 100);

      return ReviewResult(
        filePath: filePath,
        findings: findings,
        score: score,
        summary:
            '${findings.length} issues found ($criticalCount critical, '
            '$errorCount errors, $warningCount warnings). Score: $score/100.',
      );
    } catch (e) {
      debugPrint('Review parse error: $e');
      return ReviewResult(
        filePath: filePath,
        findings: [],
        score: 50,
        summary: 'Parse error: $e',
      );
    }
  }
}
