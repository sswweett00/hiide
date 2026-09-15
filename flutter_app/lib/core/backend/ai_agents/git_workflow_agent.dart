import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../ai_chat_client.dart';

// ─── Types ───────────────────────────────────────────────────────────────────

class CommitSuggestion {
  final String message;
  final String type; // feat, fix, refactor, docs, test, chore
  final String description;

  const CommitSuggestion({
    required this.message,
    required this.type,
    required this.description,
  });
}

class BranchSuggestion {
  final String name;
  final String description;

  const BranchSuggestion({required this.name, required this.description});
}

// ─── Git Workflow Agent ──────────────────────────────────────────────────────

/// AI-powered git helpers: commit message generation, branch naming,
/// PR descriptions, and changelog updates.
class GitWorkflowAgent {
  GitWorkflowAgent({
    required AiChatClient ai,
    required String workspaceRoot,
  })  : _ai = ai,
        _workspaceRoot = workspaceRoot;

  final AiChatClient _ai;
  final String _workspaceRoot;

  /// Generates a commit message from the staged diff.
  Future<CommitSuggestion> generateCommitMessage() async {
    final diff = await _getStagedDiff();
    if (diff.isEmpty) {
      return const CommitSuggestion(
        message: 'chore: no changes staged',
        type: 'chore',
        description: 'No staged changes found.',
      );
    }

    final response = await _ai.chatCompletion(
      messages: [
        {
          'role': 'system',
          'content': '''You are a git commit message expert. Given a diff,
generate a concise, conventional commit message.

Output JSON:
{
  "type": "feat"|"fix"|"refactor"|"docs"|"test"|"chore"|"perf"|"style",
  "description": "short imperative description",
  "body": "optional detailed body (may be empty)"
}

Rules:
- Use conventional commits format: type(description)
- Keep subject under 72 characters
- Use imperative mood ("add" not "added")
- Be specific about what changed and why
- Output ONLY valid JSON''',
        },
        {'role': 'user', 'content': 'Staged diff:\n$diff'},
      ],
      temperature: 0.2,
    );

    if (response.containsKey('error')) {
      return CommitSuggestion(
        message: 'chore: update files',
        type: 'chore',
        description: 'Could not analyze diff: ${response['error']}',
      );
    }

    final choices = (response['choices'] as List?) ?? [];
    if (choices.isEmpty) {
      return const CommitSuggestion(
        message: 'chore: update files',
        type: 'chore',
        description: 'Empty response from model.',
      );
    }

    final text = (choices.first as Map)['message']?['content']?.toString() ?? '';
    return _parseCommit(text);
  }

  /// Generates branch name suggestions from a description.
  Future<List<BranchSuggestion>> suggestBranchName(String description) async {
    final response = await _ai.chatCompletion(
      messages: [
        {
          'role': 'system',
          'content': '''Generate 3 git branch name suggestions for the given
task description. Use conventional format (feat/, fix/, refactor/, etc.).
Output JSON array: [{"name":"feat/...","description":"..."}]
Output ONLY valid JSON.''',
        },
        {'role': 'user', 'content': description},
      ],
      temperature: 0.3,
    );

    if (response.containsKey('error')) return [];

    final choices = (response['choices'] as List?) ?? [];
    if (choices.isEmpty) return [];

    final text = (choices.first as Map)['message']?['content']?.toString() ?? '';
    return _parseBranches(text);
  }

  /// Generates a PR description from the branch diff.
  Future<String> generatePrDescription({
    String? baseBranch,
    String? title,
  }) async {
    final diff = await _getBranchDiff(baseBranch: baseBranch);
    if (diff.isEmpty) return 'No changes to describe.';

    final response = await _ai.chatCompletion(
      messages: [
        {
          'role': 'system',
          'content': '''Generate a pull request description in Markdown format.
Include:
- Summary of changes
- What was changed and why
- Testing done
- Any breaking changes

Keep it concise but informative. Use Markdown formatting.''',
        },
        {
          'role': 'user',
          'content': '${title != null ? "PR Title: $title\n\n" : ""}Diff:\n$diff',
        },
      ],
      temperature: 0.2,
    );

    if (response.containsKey('error')) return 'Error generating PR description.';

    final choices = (response['choices'] as List?) ?? [];
    if (choices.isEmpty) return 'No response from model.';

    return (choices.first as Map)['message']?['content']?.toString() ?? '';
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  Future<String> _getStagedDiff() async {
    try {
      final result = await Process.run(
        'git',
        ['diff', '--cached'],
        workingDirectory: _workspaceRoot,
      );
      return result.stdout.toString();
    } catch (e) {
      debugPrint('Git diff error: $e');
      return '';
    }
  }

  Future<String> _getBranchDiff({String? baseBranch}) async {
    try {
      final base = baseBranch ?? 'main';
      final result = await Process.run(
        'git',
        ['diff', '$base...HEAD'],
        workingDirectory: _workspaceRoot,
      );
      return result.stdout.toString();
    } catch (e) {
      debugPrint('Git branch diff error: $e');
      return '';
    }
  }

  CommitSuggestion _parseCommit(String text) {
    try {
      var json = text.trim();
      if (json.contains('```')) {
        final match = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(json);
        if (match != null) json = match.group(1)!.trim();
      }
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      final type = decoded['type']?.toString() ?? 'chore';
      final desc = decoded['description']?.toString() ?? 'update files';
      final body = decoded['body']?.toString();
      return CommitSuggestion(
        message: body != null && body.isNotEmpty ? '$type: $desc\n\n$body' : '$type: $desc',
        type: type,
        description: desc,
      );
    } catch (e) {
      debugPrint('Commit parse error: $e');
      return CommitSuggestion(
        message: 'chore: update files',
        type: 'chore',
        description: text,
      );
    }
  }

  List<BranchSuggestion> _parseBranches(String text) {
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
        return BranchSuggestion(
          name: map['name']?.toString() ?? '',
          description: map['description']?.toString() ?? '',
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }
}
