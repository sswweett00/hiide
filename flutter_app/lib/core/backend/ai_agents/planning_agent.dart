import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../ai_chat_client.dart';
import '../backend_service.dart';

enum PlanStepStatus { pending, running, success, error, skipped }

class PlanStep {
  final String id;
  final String title;
  final String description;
  final String rationale;
  final String agent;
  final List<String> files;
  final List<String> dependsOn;
  final List<String> verification;
  final String risk;
  final Map<String, dynamic> raw;

  PlanStep({
    required this.id,
    required this.title,
    required this.description,
    required this.rationale,
    required this.agent,
    required this.files,
    required this.dependsOn,
    required this.verification,
    required this.risk,
    this.raw = const {},
    this.status = PlanStepStatus.pending,
    this.result,
    this.error,
  });

  PlanStepStatus status;
  String? result;
  String? error;
}

class PlanDocument {
  final String title;
  final String summary;
  final String goal;
  final List<String> assumptions;
  final List<String> scope;
  final List<String> constraints;
  final List<String> risks;
  final List<String> acceptanceCriteria;
  final List<String> validation;
  final List<String> rollback;
  final List<PlanStep> steps;

  const PlanDocument({
    required this.title,
    required this.summary,
    required this.goal,
    required this.assumptions,
    required this.scope,
    required this.constraints,
    required this.risks,
    required this.acceptanceCriteria,
    required this.validation,
    required this.rollback,
    required this.steps,
  });

  String toMarkdown() {
    final b = StringBuffer()
      ..writeln('# ' + (title.trim().isEmpty ? 'Implementation Plan' : title))
      ..writeln()
      ..writeln('## Summary')
      ..writeln(summary.isEmpty ? 'No summary supplied.' : summary.trim())
      ..writeln()
      ..writeln('## Goal')
      ..writeln(goal.isEmpty ? summary.trim() : goal.trim())
      ..writeln();
    _section(b, 'Assumptions', assumptions);
    _section(b, 'Scope', scope);
    _section(b, 'Constraints', constraints);
    b.writeln('## Steps');
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      b
        ..writeln()
        ..writeln('### ' + (i + 1).toString() + '. ' + step.title)
        ..writeln(step.description)
        ..writeln()
        ..writeln('- **Agent:** ' + step.agent)
        ..writeln('- **Rationale:** ' + (step.rationale.isEmpty ? '—' : step.rationale));
      if (step.files.isNotEmpty) b.writeln('- **Files:** ' + step.files.join(', '));
      if (step.dependsOn.isNotEmpty) b.writeln('- **Depends on:** ' + step.dependsOn.join(', '));
      if (step.verification.isNotEmpty) {
        b.writeln('- **Verification:**');
        for (final check in step.verification) {
        b.writeln('  - ' + check);
      }
      }
      if (step.risk.isNotEmpty) b.writeln('- **Risk:** ' + step.risk);
    }
    _section(b, 'Validation', validation);
    _section(b, 'Acceptance criteria', acceptanceCriteria);
    _section(b, 'Risks', risks);
    _section(b, 'Rollback', rollback);
    return b.toString().trim();
  }

  static void _section(StringBuffer b, String title, List<String> values) {
    if (values.isEmpty) return;
    b..writeln('## ' + title)..writeln();
    for (final value in values) {
      b.writeln('- ' + value);
    }
    b.writeln();
  }
}

sealed class PlanningEvent { const PlanningEvent(); }
class PlanCreatedEvent extends PlanningEvent {
  final List<PlanStep> steps;
  final PlanDocument document;
  PlanCreatedEvent(this.steps, this.document);
}
class PlanStepStartedEvent extends PlanningEvent {
  final PlanStep step;
  PlanStepStartedEvent(this.step);
}
class PlanStepCompletedEvent extends PlanningEvent {
  final PlanStep step;
  PlanStepCompletedEvent(this.step);
}
class PlanTextTokenEvent extends PlanningEvent {
  final String token;
  PlanTextTokenEvent(this.token);
}
class PlanDoneEvent extends PlanningEvent {
  final String summary;
  final PlanDocument document;
  PlanDoneEvent(this.summary, this.document);
}
class PlanErrorEvent extends PlanningEvent {
  final String message;
  const PlanErrorEvent(this.message);
}

class PlanningAgent {
  PlanningAgent({
    required AiChatClient ai,
    required BackendService backend,
    required String workspaceRoot,
    this.maxSteps = 24,
    this.maxWorkspaceEntries = 300,
  })  : _ai = ai,
        _backend = backend,
        _workspaceRoot = workspaceRoot;

  final AiChatClient _ai;
  final BackendService _backend;
  final String _workspaceRoot;
  final int maxSteps;
  final int maxWorkspaceEntries;
  bool _stopRequested = false;
  PlanDocument? lastPlan;

  void stop() => _stopRequested = true;

  static const _readOnlyToolDefinitions = <Map<String, dynamic>>[
    {
      'type': 'function',
      'function': {
        'name': 'read_file',
        'description': 'Read a file inside the workspace. Planning is read-only.',
        'parameters': {
          'type': 'object',
          'properties': {'path': {'type': 'string'}},
          'required': ['path'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'list_directory',
        'description': 'List one workspace directory. Planning is read-only.',
        'parameters': {
          'type': 'object',
          'properties': {'path': {'type': 'string'}},
          'required': ['path'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'search_workspace',
        'description': 'Search the workspace for a text fragment. Planning is read-only.',
        'parameters': {
          'type': 'object',
          'properties': {'query': {'type': 'string'}},
          'required': ['query'],
        },
      },
    },
  ];

  static const _maxInspectionRounds = 8;
  static const _maxToolResultChars = 12000;
  static const _systemPrompt = '''
You are Hiide Plan Mode, a senior software architect and implementation planner.
Produce an exhaustive but executable implementation plan. Planning is read-only.
Return ONLY one JSON object with title, summary, goal, assumptions, scope,
constraints, risks, acceptance_criteria, validation, rollback and steps.
Every step must contain id, title, description, rationale, agent, files,
depends_on, verification and risk.
Dependencies must be acyclic. Identify concrete files only when supported by the workspace.
Separate implementation, review, testing and verification. Include edge cases,
failure paths, security/performance implications and rollback. Match the user's language.
''' ;

  Stream<PlanningEvent> run(String userRequest) async* {
    _stopRequested = false;
    final workspace = await _workspaceSnapshot();
    final request = 'USER REQUEST:\n' + userRequest + '\n\nWORKSPACE ROOT:\n' + _workspaceRoot + '\n\nCURRENT WORKSPACE SNAPSHOT:\n' + workspace;

    Map<String, dynamic> response;
    try {
      response = await _requestWithReadOnlyInspection(request);
    } catch (e) {
      yield PlanErrorEvent('Planning request failed: ' + e.toString());
      return;
    }
    if (_stopRequested) return;

    late final PlanDocument document;
    try {
      document = parseDocument(_contentFromResponse(response), maxSteps: maxSteps);
    } catch (firstError) {
      try {
        final repaired = await _ai.chatCompletion(
          messages: [
            {'role': 'system', 'content': _systemPrompt},
            {'role': 'user', 'content': request + '\n\nThe previous plan was invalid: ' + firstError.toString() + '\nRepair it and return only valid JSON.'},
          ],
          temperature: 0.0,
        );
        if (_stopRequested) return;
        document = parseDocument(_contentFromResponse(repaired), maxSteps: maxSteps);
      } catch (repairError) {
        yield PlanErrorEvent('Plan could not be validated: ' + repairError.toString());
        return;
      }
    }

    lastPlan = document;
    yield PlanCreatedEvent(document.steps, document);

    for (final step in document.steps) {
      if (_stopRequested) return;
      step.status = PlanStepStatus.running;
      yield PlanStepStartedEvent(step);
      step.status = PlanStepStatus.success;
      step.result = 'Planned; no workspace mutation performed.';
      yield PlanStepCompletedEvent(step);
    }

    final markdown = document.toMarkdown();
    const chunkSize = 180;
    for (var i = 0; i < markdown.length; i += chunkSize) {
      if (_stopRequested) return;
      final end = (i + chunkSize < markdown.length) ? i + chunkSize : markdown.length;
      yield PlanTextTokenEvent(markdown.substring(i, end));
    }
    if (!_stopRequested) yield PlanDoneEvent(markdown, document);
  }

  Future<Map<String, dynamic>> _requestWithReadOnlyInspection(String request) async {
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': _systemPrompt},
      {'role': 'user', 'content': request},
    ];

    for (var round = 0; round < _maxInspectionRounds; round++) {
      if (_stopRequested) return const {'error': 'planning_stopped'};
      final response = await _ai.chatCompletion(
        messages: messages,
        tools: _readOnlyToolDefinitions,
        temperature: 0.1,
      );
      if (response['error'] != null) return response;
      final choices = response['choices'];
      if (choices is! List || choices.isEmpty) return response;
      final first = choices.first;
      if (first is! Map) return response;
      final message = first['message'];
      if (message is! Map) return response;
      final toolCalls = message['tool_calls'];
      if (toolCalls is! List || toolCalls.isEmpty) return response;

      messages.add({
        'role': 'assistant',
        'content': message['content']?.toString() ?? '',
        'tool_calls': toolCalls,
      });

      for (final rawCall in toolCalls) {
        if (_stopRequested) return const {'error': 'planning_stopped'};
        if (rawCall is! Map) continue;
        final call = Map<String, dynamic>.from(rawCall);
        final function = call['function'];
        if (function is! Map) {
          messages.add({
            'role': 'tool',
            'tool_call_id': call['id']?.toString() ?? 'unknown',
            'content': '(error) invalid tool call payload',
          });
          continue;
        }
        final fn = Map<String, dynamic>.from(function);
        final name = fn['name']?.toString() ?? '';
        final args = _parseToolArguments(fn['arguments']);
        final output = await _executeReadOnlyTool(name, args);
        messages.add({
          'role': 'tool',
          'tool_call_id': call['id']?.toString() ?? 'unknown',
          'content': output,
        });
      }
    }

    return const {
      'error': 'Planner reached the maximum read-only inspection rounds (8).',
    };
  }

  Future<String> _executeReadOnlyTool(String name, Map<String, dynamic> args) async {
    try {
      switch (name) {
        case 'read_file':
          final path = args['path']?.toString().trim() ?? '';
          if (path.isEmpty) return '(error) path is required';
          final result = await _backend.executeAgentTool(
            'file.read',
            {'path': path},
            workspaceRoot: _workspaceRoot,
          );
          return _truncateToolResult(result.ok ? result.output : '(error) ' + result.error);
        case 'list_directory':
          final path = args['path']?.toString().trim() ?? '.';
          final result = await _backend.executeAgentTool(
            'file.list',
            {'path': path.isEmpty ? '.' : path},
            workspaceRoot: _workspaceRoot,
          );
          return _truncateToolResult(result.ok ? result.output : '(error) ' + result.error);
        case 'search_workspace':
          final query = args['query']?.toString().trim() ?? '';
          if (query.isEmpty) return '(error) query is required';
          final hits = await _backend.workspaceSearch(_workspaceRoot, query, maxResults: 80);
          if (hits.isEmpty) return '(no matches)';
          final out = StringBuffer();
          for (final hit in hits) {
            out.writeln(hit.path + ':' + hit.line.toString() + ':' + hit.col.toString() + ': ' + hit.text);
          }
          return _truncateToolResult(out.toString().trim());
        default:
          return '(error) tool not permitted in Plan mode: ' + name;
      }
    } catch (e) {
      return '(error) ' + e.toString();
    }
  }

  static Map<String, dynamic> _parseToolArguments(dynamic raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is! String || raw.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return const {};
  }

  static String _truncateToolResult(String value) {
    if (value.length <= _maxToolResultChars) return value;
    return value.substring(0, _maxToolResultChars) + '\n…[truncated read-only tool result]';
  }
  Future<String> _workspaceSnapshot() async {
    try {
      final entries = await _backend.workspaceTree(_workspaceRoot, maxEntries: maxWorkspaceEntries.clamp(1, 300).toInt());
      if (entries.isEmpty) return '(workspace tree unavailable or empty)';
      final b = StringBuffer();
      for (final entry in entries) {
        b.writeln((entry.isDirectory ? '[DIR] ' : '[FILE] ') + entry.path + (entry.isDirectory ? '' : ' (' + entry.size.toString() + ' bytes)'));
      }
      return b.toString().trim();
    } catch (e) {
      debugPrint('Plan workspace snapshot unavailable: ' + e.toString());
      return '(workspace snapshot unavailable: ' + e.toString() + ')';
    }
  }

  String _contentFromResponse(Map<String, dynamic> response) {
    final error = response['error'];
    if (error != null) throw StateError(error.toString());
    final choices = response['choices'];
    if (choices is! List || choices.isEmpty) throw StateError('Model returned an empty planning response.');
    final first = choices.first;
    if (first is! Map) throw StateError('Invalid model choice payload.');
    final message = first['message'];
    if (message is! Map) throw StateError('Missing planning message.');
    final content = message['content'];
    if (content == null || content.toString().trim().isEmpty) throw StateError('Planning response was empty.');
    return content.toString();
  }

  static PlanDocument parseDocument(String content, {int maxSteps = 24}) {
    final decoded = jsonDecode(_extractJsonObject(content));
    if (decoded is! Map) throw const FormatException('Plan root must be an object.');

    final rawSteps = decoded['steps'];
    final limit = maxSteps.clamp(1, 24);
    if (rawSteps is! List || rawSteps.isEmpty) throw const FormatException('Plan must contain at least one step.');
    if (rawSteps.length > limit) throw FormatException('Plan exceeds the ' + limit.toString() + '-step safety limit.');

    final ids = <String>{};
    final steps = <PlanStep>[];
    for (var i = 0; i < rawSteps.length; i++) {
      final raw = rawSteps[i];
      if (raw is! Map) throw FormatException('Step ' + (i + 1).toString() + ' is not an object.');
      final id = _string(raw['id']);
      final title = _string(raw['title']);
      final description = _string(raw['description']);
      if (id.isEmpty || title.isEmpty || description.isEmpty) throw FormatException('Step ' + (i + 1).toString() + ' requires id, title and description.');
      if (!ids.add(id)) throw FormatException('Duplicate plan step id: ' + id);
      final agent = _string(raw['agent']).isEmpty ? 'coder' : _string(raw['agent']);
      const allowedAgents = <String>{'planner', 'researcher', 'coder', 'reviewer', 'tester', 'security'};
      if (!allowedAgents.contains(agent)) throw FormatException('Unsupported plan agent: ' + agent);
      final files = _strings(raw['files']);
      if (files.length > 32) throw FormatException('Step ' + id + ' references too many files.');
      final dependencies = _strings(raw['depends_on']);
      if (dependencies.length > rawSteps.length) throw FormatException('Step ' + id + ' has too many dependencies.');
      steps.add(PlanStep(id: id, title: title, description: description, rationale: _string(raw['rationale']), agent: agent, files: files, dependsOn: dependencies, verification: _strings(raw['verification']), risk: _string(raw['risk']), raw: Map<String, dynamic>.from(raw)));
    }
    for (final step in steps) {
      for (final dependency in step.dependsOn) {
        if (!ids.contains(dependency)) throw FormatException('Step ' + step.id + ' depends on unknown step ' + dependency + '.');
      }
    }
    _validateAcyclic(steps);

    final document = PlanDocument(title: _string(decoded['title']), summary: _string(decoded['summary']), goal: _string(decoded['goal']), assumptions: _strings(decoded['assumptions']), scope: _strings(decoded['scope']), constraints: _strings(decoded['constraints']), risks: _strings(decoded['risks']), acceptanceCriteria: _strings(decoded['acceptance_criteria']), validation: _strings(decoded['validation']), rollback: _strings(decoded['rollback']), steps: steps);
    if (document.summary.isEmpty && document.goal.isEmpty) throw const FormatException('Plan needs a summary or goal.');
    if (document.acceptanceCriteria.isEmpty) throw const FormatException('Plan must include acceptance criteria.');
    if (document.validation.isEmpty) throw const FormatException('Plan must include validation checks.');
    return document;
  }

  static String _extractJsonObject(String content) {
    var text = content.trim();
    final fence = text.indexOf(String.fromCharCode(96) + String.fromCharCode(96) + String.fromCharCode(96));
    if (fence >= 0) {
      final lineEnd = text.indexOf('\n', fence);
      final close = text.lastIndexOf(String.fromCharCode(96) + String.fromCharCode(96) + String.fromCharCode(96));
      if (lineEnd >= 0 && close > lineEnd) text = text.substring(lineEnd + 1, close).trim();
    }
    final start = text.indexOf('{');
    if (start < 0) throw const FormatException('No JSON object found.');
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < text.length; i++) {
      final ch = text.codeUnitAt(i);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == 92) {
          escaped = true;
        } else if (ch == 34) {
          inString = false;
        }
        continue;
      }
      if (ch == 34) {
        inString = true;
      } else if (ch == 123) {
        depth++;
      } else if (ch == 125) {
        depth--;
        if (depth == 0) return text.substring(start, i + 1);
      }
    }
    throw const FormatException('Unterminated JSON object.');
  }
  static List<String> _strings(dynamic value) {
    if (value is! List) return const [];
    return value.map((item) => item?.toString().trim() ?? '').where((item) => item.isNotEmpty).toList();
  }
  static String _string(dynamic value) => value?.toString().trim() ?? '';

  static void _validateAcyclic(List<PlanStep> steps) {
    final byId = <String, PlanStep>{for (final step in steps) step.id: step};
    final visiting = <String>{};
    final visited = <String>{};
    void visit(String id) {
      if (visiting.contains(id)) throw FormatException('Dependency cycle detected at ' + id + '.');
      if (visited.contains(id)) return;
      final step = byId[id]!;
      visiting.add(id);
      for (final dependency in step.dependsOn) {
        visit(dependency);
      }
      visiting.remove(id);
      visited.add(id);
    }
    for (final step in steps) {
      visit(step.id);
    }
  }
}