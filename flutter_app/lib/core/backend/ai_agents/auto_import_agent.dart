import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../ai_chat_client.dart';

// ─── Types ───────────────────────────────────────────────────────────────────

class ImportSuggestion {
  final String importPath;
  final String symbol;
  final String type; // 'package', 'dart', 'relative'
  final double confidence;

  const ImportSuggestion({
    required this.importPath,
    required this.symbol,
    required this.type,
    this.confidence = 0.9,
  });
}

// ─── Auto-Import Agent ───────────────────────────────────────────────────────

/// Detects missing imports in code and suggests the correct import statements.
/// Works for Dart (package imports), TypeScript (ES imports), Python, etc.
class AutoImportAgent {
  AutoImportAgent({required AiChatClient ai}) : _ai = ai;

  final AiChatClient _ai;

  /// Analyzes code for undefined references and suggests imports.
  Future<List<ImportSuggestion>> findMissingImports({
    required String code,
    required String filePath,
    List<String>? existingImports,
  }) async {
    final lang = _detectLanguage(filePath);

    final response = await _ai.chatCompletion(
      messages: [
        {
          'role': 'system',
          'content': '''You are an import resolution expert for $lang code.
Analyze the code for undefined references and suggest the correct import statements.

Output a JSON array of missing imports:
[{
  "path": "import path (e.g. 'package:flutter/material.dart')",
  "symbol": "the undefined symbol that needs importing",
  "type": "package"|"dart"|"relative",
  "confidence": 0.0-1.0
}]

Only suggest imports that are genuinely missing. Don't suggest imports
for standard library types that are already available. Output ONLY valid JSON.''',
        },
        {
          'role': 'user',
          'content': 'File: $filePath\n'
              '${existingImports != null ? "Existing imports:\n${existingImports.join('\n')}\n\n" : ""}'
              'Code:\n$code',
        },
      ],
      temperature: 0.1,
    );

    if (response.containsKey('error')) return [];

    final choices = (response['choices'] as List?) ?? [];
    if (choices.isEmpty) return [];

    final text = (choices.first as Map)['message']?['content']?.toString() ?? '';
    return _parseImports(text);
  }

  /// Auto-fixes missing imports by inserting them into the code.
  Future<String> autoFixImports({
    required String code,
    required String filePath,
  }) async {
    final suggestions = await findMissingImports(
      code: code,
      filePath: filePath,
    );

    if (suggestions.isEmpty) return code;

    final lines = code.split('\n');
    final importLines = <String>[];
    final nonImportEnd = _findImportInsertPosition(lines);

    for (final s in suggestions) {
      if (s.confidence < 0.7) continue;
      final importLine = _buildImportLine(s);
      if (!code.contains(importLine)) {
        importLines.add(importLine);
      }
    }

    if (importLines.isEmpty) return code;

    // Insert imports after existing imports
    final result = List<String>.from(lines);
    result.insertAll(nonImportEnd, importLines);
    return result.join('\n');
  }

  String _buildImportLine(ImportSuggestion s) {
    return "import '${s.importPath}';";
  }

  int _findImportInsertPosition(List<String> lines) {
    var lastImportLine = 0;
    for (var i = 0; i < lines.length; i++) {
      final trimmed = lines[i].trim();
      if (trimmed.startsWith('import ') || trimmed.startsWith('export ') || trimmed.startsWith('part ')) {
        lastImportLine = i + 1;
      }
    }
    return lastImportLine;
  }

  String _detectLanguage(String path) {
    if (path.endsWith('.dart')) return 'Dart';
    if (path.endsWith('.ts') || path.endsWith('.tsx')) return 'TypeScript';
    if (path.endsWith('.js') || path.endsWith('.jsx')) return 'JavaScript';
    if (path.endsWith('.py')) return 'Python';
    if (path.endsWith('.rs')) return 'Rust';
    return 'unknown';
  }

  List<ImportSuggestion> _parseImports(String text) {
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
        return ImportSuggestion(
          importPath: map['path']?.toString() ?? '',
          symbol: map['symbol']?.toString() ?? '',
          type: map['type']?.toString() ?? 'package',
          confidence: (map['confidence'] as num?)?.toDouble() ?? 0.9,
        );
      }).toList();
    } catch (e) {
      debugPrint('Import parse error: $e');
      return [];
    }
  }
}
