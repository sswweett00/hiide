import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../ai_chat_client.dart';

// ─── Types ───────────────────────────────────────────────────────────────────

enum PlanStepStatus { pending, running, success, error, skipped }

class PlanStep {
  final String id;
  final String description;
  PlanStepStatus status;
  String? result;
  String? error;

  PlanStep({
    required this.id,
    required this.description,
    this.status = PlanStepStatus.pending,
    this.result,
    this.error,
  });
}

sealed class PlanningEvent {
  const PlanningEvent();
}

class PlanCreatedEvent extends PlanningEvent {
  final List<PlanStep> steps;
  PlanCreatedEvent(this.steps);
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
  PlanDoneEvent(this.summary);
}

class PlanErrorEvent extends PlanningEvent {
  final String message;
  const PlanErrorEvent(this.message);
}

// ─── Planning Agent ──────────────────────────────────────────────────────────

/// Breaks a user request into subtasks, executes each via the agent tools,
/// and verifies the result. The planning prompt forces the model to output
/// a JSON plan first, then the agent executes each step.
class PlanningAgent {
  PlanningAgent({
    required AiChatClient ai,
    this.maxSteps = 20,
  }) : _ai = ai;

  final AiChatClient _ai;
  final int maxSteps;

  bool _stopRequested = false;
  void stop() => _stopRequested = true;

  Stream<PlanningEvent> run(String userRequest) async* {
    // Step 1: Ask the model to create a plan
    final planResponse = await _ai.chatCompletion(
      messages: [
        {
          'role': 'system',
          'content': '''You are a planning agent. Given the user's request,
analyze it and create a step-by-step plan. Output ONLY a JSON array of steps.
Each step has "description" (what to do) and "tool" (one of: read_file,
write_file, apply_diff, run_command, search_workspace, list_directory).

Example:
[{"description":"Read main.dart to understand structure","tool":"read_file","args":{"path":"main.dart"}},
 {"description":"Add error handling","tool":"apply_diff","args":{"path":"main.dart","target":"old code","replacement":"new code"}}]

Keep steps small and focused. Max 15 steps. Output ONLY the JSON array.''',
        },
        {'role': 'user', 'content': userRequest},
      ],
      temperature: 0.1,
    );

    if (planResponse.containsKey('error')) {
      yield PlanErrorEvent(planResponse['error'].toString());
      return;
    }

    // Parse plan
    final choices = (planResponse['choices'] as List?) ?? [];
    if (choices.isEmpty) {
      yield const PlanErrorEvent('Model returned empty response.');
      return;
    }
    final content =
        (choices.first as Map)['message']?['content']?.toString() ?? '';
    final steps = _parsePlan(content);

    if (steps.isEmpty) {
      yield PlanErrorEvent('Could not parse a plan from the response.');
      return;
    }

    yield PlanCreatedEvent(steps);

    // Step 2: Execute each step
    final completedSteps = <Map<String, dynamic>>[];
    for (final step in steps) {
      if (_stopRequested) break;

      step.status = PlanStepStatus.running;
      yield PlanStepStartedEvent(step);

      try {
        final result = await _executeStep(step, completedSteps);
        step.status = PlanStepStatus.success;
        step.result = result;
        completedSteps.add({
          'description': step.description,
          'result': result,
        });
        yield PlanStepCompletedEvent(step);
      } catch (e) {
        step.status = PlanStepStatus.error;
        step.error = e.toString();
        yield PlanStepCompletedEvent(step);
      }
    }

    // Step 3: Summary
    final summary = await _generateSummary(userRequest, steps);
    yield PlanDoneEvent(summary);
  }

  List<PlanStep> _parsePlan(String content) {
    try {
      // Extract JSON array from the response (may be wrapped in markdown)
      var json = content.trim();
      if (json.contains('```')) {
        final match = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(json);
        if (match != null) json = match.group(1)!.trim();
      }
      // Find the array
      final start = json.indexOf('[');
      final end = json.lastIndexOf(']');
      if (start < 0 || end < 0) return [];
      json = json.substring(start, end + 1);

      final decoded = jsonDecode(json) as List;
      return decoded.asMap().entries.map((entry) {
        final map = entry.value as Map<String, dynamic>;
        return PlanStep(
          id: 'step_${entry.key}',
          description: map['description']?.toString() ?? 'Unknown step',
        );
      }).toList();
    } catch (e) {
      debugPrint('Plan parse error: $e');
      return [];
    }
  }

  Future<String> _executeStep(
    PlanStep step,
    List<Map<String, dynamic>> context,
  ) async {
    // Use the agent's existing tool infrastructure
    final response = await _ai.chatCompletion(
      messages: [
        {
          'role': 'system',
          'content':
              'Execute this single step. Use tools as needed. Be concise.',
        },
        ...context.map((c) => {
              'role': 'assistant',
              'content':
                  'Previously: ${c['description']}\nResult: ${c['result']}',
            }),
        {'role': 'user', 'content': step.description},
      ],
      tools: _toolDefinitions(),
      temperature: 0.1,
    );

    if (response.containsKey('error')) {
      throw Exception(response['error']);
    }

    final choices = (response['choices'] as List?) ?? [];
    if (choices.isEmpty) return '(no response)';
    final msg = (choices.first as Map)['message'] as Map?;
    return msg?['content']?.toString() ?? '(done)';
  }

  Future<String> _generateSummary(
    String request,
    List<PlanStep> steps,
  ) async {
    final succeeded = steps.where((s) => s.status == PlanStepStatus.success).length;
    final failed = steps.where((s) => s.status == PlanStepStatus.error).length;
    return 'Plan completed: $succeeded/${steps.length} steps succeeded'
        '${failed > 0 ? ', $failed failed' : ''}.';
  }

  List<Map<String, dynamic>> _toolDefinitions() {
    return [
      {
        'type': 'function',
        'function': {
          'name': 'read_file',
          'description': 'Read a file.',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
            },
            'required': ['path'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'write_file',
          'description': 'Create or overwrite a file.',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'content': {'type': 'string'},
            },
            'required': ['path', 'content'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'run_command',
          'description': 'Run a shell command.',
          'parameters': {
            'type': 'object',
            'properties': {
              'command': {'type': 'string'},
            },
            'required': ['command'],
          },
        },
      },
    ];
  }
}
