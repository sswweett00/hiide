import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'ai_chat_client.dart';
import 'backend_service.dart';
import '../mechanics/agent_context.dart';
import '../mechanics/agent_guard.dart';

// ─── Agent loop types ─────────────────────────────────────────────────────────

enum AgentToolStatus { running, success, error }

/// A single tool invocation requested by the model.
class AgentToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  AgentToolStatus status;
  String? result;

  AgentToolCall({
    required this.id,
    required this.name,
    required this.arguments,
    this.status = AgentToolStatus.running,
    this.result,
  });
}

/// Events emitted while the agent loop runs. The UI renders these
/// incrementally (streaming text, live tool cards, completion, errors).
sealed class AgentEvent {
  const AgentEvent();
}

class AgentTextTokenEvent extends AgentEvent {
  final String token;
  const AgentTextTokenEvent(this.token);
}

class AgentToolStartedEvent extends AgentEvent {
  final AgentToolCall toolCall;
  const AgentToolStartedEvent(this.toolCall);
}

class AgentToolFinishedEvent extends AgentEvent {
  final AgentToolCall toolCall;
  const AgentToolFinishedEvent(this.toolCall);
}

class AgentDoneEvent extends AgentEvent {
  final String text;
  const AgentDoneEvent(this.text);
}

class AgentErrorEvent extends AgentEvent {
  final String message;
  const AgentErrorEvent(this.message);
}

class AgentStoppedEvent extends AgentEvent {
  const AgentStoppedEvent();
}

class AgentIterationLimitEvent extends AgentEvent {
  final int iterations;
  final String reason;
  const AgentIterationLimitEvent(
    this.iterations, [
    this.reason = 'Agent iteration limit reached.',
  ]);
}

class _ToolResult {
  final String output;
  final bool success;
  const _ToolResult(this.output, {this.success = true});
}

// ─── The agent ────────────────────────────────────────────────────────────────

/// Runs a proper agentic loop over Groq's native function-calling API.
///
/// The model decides which tools to call (`read_file`, `write_file`,
/// `apply_diff`, `list_directory`, `run_command`, `search_workspace`); each
/// call is executed by the Zig engine's agent tool framework through
/// [BackendService.executeAgentTool] and its result is fed back as a
/// `role: 'tool'` message. The loop continues until the model stops requesting
/// tools, the caller requests a stop, or the iteration budget is exhausted.
class AgentController {
  AgentController({
    required AiChatClient ai,
    required BackendService backend,
    required String workspaceRoot,
    required String model,
    String? systemPrompt,
    this.maxIterations = 15,
    this.toolResultMaxChars = 8000,
    this.maxToolContextChars = 12000,
    this.maxToolCalls = 64,
    this.maxRunDuration = const Duration(minutes: 10),
    this.maxRepeatedToolCalls = 2,
    this.maxUnchangedToolResults = 3,
    this.maxContextMessages = 48,
    this.maxContextCharacters = 120000,
    this.approvalHandler,
  })  : _ai = ai,
        _backend = backend,
        _workspaceRoot = workspaceRoot,
        _model = model,
        _systemPrompt = systemPrompt ?? _defaultSystemPrompt(workspaceRoot);

  final AiChatClient _ai;
  final BackendService _backend;
  final String _workspaceRoot;
  final String _model;
  final String _systemPrompt;
  final int maxIterations;
  final int toolResultMaxChars;
  final int maxToolContextChars;
  final int maxToolCalls;
  final Duration maxRunDuration;
  final int maxRepeatedToolCalls;
  final int maxUnchangedToolResults;
  final int maxContextMessages;
  final int maxContextCharacters;
  final Future<bool> Function(String toolName, Map<String, dynamic> arguments)? approvalHandler;

  bool _stopRequested = false;
  bool _workspaceMutated = false;
  bool _verificationObserved = false;
  bool _verificationNudgeSent = false;
  List<Map<String, dynamic>> _workingMessages = [];

  /// Asks the loop to stop after the current step completes.
  void stop() => _stopRequested = true;

  /// The conversation history (excluding the system prompt) as it evolved
  /// during the last [run]. Persist this for the next turn.
  List<Map<String, dynamic>> get workingMessages =>
      List.unmodifiable(_workingMessages);

  static String _defaultSystemPrompt(String workspaceRoot) => '''
You are Hiide, an autonomous coding agent running inside the Hiide AI-Native IDE.

Workspace root: $workspaceRoot

You have full control over the workspace and can inspect, create, edit, and delete files/directories by calling tools:
- Create new files: use `write_file`
- Edit files: use `apply_diff` (for small, precise edits) or `write_file` (for full file rewrites)
- Delete files or directories: use `delete_file`
- Create directories: use `create_directory`
- Read files: use `read_file`
- List directory contents: use `list_directory`
- Search workspace: use `search_workspace`
- Run commands (build, test, etc.): use `run_command`

Guidelines:
- When asked to create, edit, or delete files, proceed directly with the appropriate tool.
- Resolve file paths yourself — list directories and read files before editing.
- Prefer small, targeted edits (`apply_diff`) over rewriting whole files.
- After editing code, run the relevant tests or build to verify your work
  (e.g. `zig build test` or `cd flutter_app && flutter test`).
- When you run a command, wait for its output and react to it before continuing.
- If a tool fails, read the error, adjust, and retry; do not give up on the first error.
- Only call tools that are necessary; never call one "just in case".
- When finished, summarize what you changed and how you verified it.
- Respond in the same language as the user (e.g. Turkish if asked in Turkish, English if asked in English).
''';

  /// OpenAI-style tool definitions advertised to the model.
  static const List<Map<String, dynamic>> toolDefinitions = [
    {
      'type': 'function',
      'function': {
        'name': 'read_file',
        'description':
            'Read the full content of a file. Path may be absolute or relative to the workspace root.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'File path (absolute or workspace-relative).',
            },
          },
          'required': ['path'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'write_file',
        'description':
            'Create or overwrite a file with the given content. Use this to write new files or replace an entire file.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'File path (absolute or workspace-relative).',
            },
            'content': {
              'type': 'string',
              'description': 'The complete new file content.',
            },
          },
          'required': ['path', 'content'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'delete_file',
        'description':
            'Delete a file or directory in the workspace.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'File or directory path to delete (absolute or workspace-relative).',
            },
          },
          'required': ['path'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'create_directory',
        'description':
            'Create a directory (including parent directories) in the workspace.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Directory path to create (absolute or workspace-relative).',
            },
          },
          'required': ['path'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'apply_diff',
        'description':
            'Replace the first occurrence of an exact target string in a file with a replacement. Use for small, surgical edits.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'File path (absolute or workspace-relative).',
            },
            'target': {
              'type': 'string',
              'description': 'Exact text currently in the file to replace.',
            },
            'replacement': {
              'type': 'string',
              'description': 'New text to substitute in place of target.',
            },
          },
          'required': ['path', 'target', 'replacement'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'list_directory',
        'description':
            'List the entries of a directory. Directories are prefixed with 📁, files with 📄.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Directory path (absolute or workspace-relative).',
            },
          },
          'required': ['path'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'run_command',
        'description':
            'Run a shell command in the workspace. The command output (stdout + stderr) is returned so you can react to it. Use for builds, tests, and other verification.',
        'parameters': {
          'type': 'object',
          'properties': {
            'command': {
              'type': 'string',
              'description': 'Shell command to execute, e.g. `zig build test`.',
            },
          },
          'required': ['command'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'search_workspace',
        'description':
            'Case-insensitive grep across the workspace (runs in the native Zig engine). Returns up to 50 matches as path:line:col: text.',
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'Text or pattern to search for.',
            },
          },
          'required': ['query'],
        },
      },
    },
  ];

  /// Runs the agent loop. [messages] is the conversation history without the
  /// system prompt (the controller prepends its own).
  Stream<AgentEvent> run(List<Map<String, dynamic>> messages) async* {
    _stopRequested = false;
    _workingMessages = List<Map<String, dynamic>>.from(messages);
    final apiMessages = <Map<String, dynamic>>[
      {'role': 'system', 'content': _systemPrompt},
      ..._workingMessages,
    ];

    var iterations = 0;
    var toolFailRetries = 0;
    final guard = AgentRunGuard(
      budget: AgentRunBudget(
        maxToolCalls: maxToolCalls,
        maxRunDuration: maxRunDuration,
        maxRepeatedToolCalls: maxRepeatedToolCalls,
        maxUnchangedToolResults: maxUnchangedToolResults,
      ),
    );
    final context = AgentContextCompactor(
      maxMessages: maxContextMessages,
      maxCharacters: maxContextCharacters,
    );
    while (true) {
      final budgetFailure = guard.checkRunBudget(iterations: iterations);
      if (budgetFailure != null) {
        yield AgentIterationLimitEvent(iterations, budgetFailure);
        return;
      }

      if (_stopRequested) {
        yield const AgentStoppedEvent();
        return;
      }

      final compacted = context.compact(apiMessages);
      apiMessages
        ..clear()
        ..addAll(compacted);

      final response = await _ai.chatCompletion(
        messages: apiMessages,
        tools: toolDefinitions,
        model: _model,
      );

      if (_stopRequested) {
        yield const AgentStoppedEvent();
        return;
      }

      final error = response['error'];
      if (error != null) {
        final err = error.toString();
        // Groq rejects the whole request when a model emits malformed tool-call
        // JSON (`tool_use_failed`). That is a flaky model-side generation, not
        // a user error — nudge the model and retry a couple of times without
        // burning iteration budget.
        if (_isToolUseFailure(err) && toolFailRetries < maxToolFailRetries) {
          toolFailRetries++;
          apiMessages.add({
            'role': 'system',
            'content': 'Note: the previous turn failed because a tool call '
                'had invalid JSON arguments. Retry the function call with '
                'strictly valid JSON arguments.',
          });
          debugPrint('Groq tool_use_failed; retrying '
              '($toolFailRetries/$maxToolFailRetries)');
          continue;
        }
        yield AgentErrorEvent(err);
        return;
      }

      if (iterations >= maxIterations) {
        yield AgentIterationLimitEvent(iterations);
        return;
      }
      iterations++;

      final choices = response['choices'];
      if (choices is! List || choices.isEmpty) {
        yield const AgentErrorEvent('Model returned an empty response.');
        return;
      }
      final firstChoice = choices.first;
      if (firstChoice is! Map) {
        yield const AgentErrorEvent('Model returned an invalid response shape.');
        return;
      }
      final rawMessage = firstChoice['message'];
      final message = rawMessage is Map
          ? Map<String, dynamic>.from(rawMessage)
          : <String, dynamic>{};
      final toolCalls = (message?['tool_calls'] as List?) ?? const [];

      if (toolCalls.isEmpty) {
        // A workspace mutation without verification is not treated as a
        // trustworthy completion. Give the agent one explicit self-check turn.
        if (_workspaceMutated &&
            !_verificationObserved &&
            !_verificationNudgeSent) {
          _verificationNudgeSent = true;
          apiMessages.add({
            'role': 'system',
            'content': 'You modified workspace state but have not run a '
                'verification command yet. Before giving the final answer, '
                'run the narrowest relevant test/build/lint/type-check command '
                'and inspect its result. If verification is genuinely '
                'impossible, explain why instead of claiming success.',
          });
          continue;
        }

        final content = message?['content']?.toString() ?? '';
        _workingMessages.add({'role': 'assistant', 'content': content});
        yield* _emitTypedText(content);
        yield AgentDoneEvent(content);
        return;
      }

      // Record the assistant message (with its tool calls) in history.
      final assistantMsg = <String, dynamic>{
        'role': 'assistant',
        'content': message?['content']?.toString() ?? '',
        'tool_calls': toolCalls.map((tc) {
          final t = tc as Map<String, dynamic>;
          return {
            'id': t['id']?.toString() ?? '',
            'type': 'function',
            'function': t['function'],
          };
        }).toList(),
      };
      apiMessages.add(assistantMsg);
      _workingMessages.add(assistantMsg);

      // Materialize the calls once so the runtime can safely parallelize
      // independent read-only work without ever racing writes/commands.
      final calls = <AgentToolCall>[];
      for (final tc in toolCalls) {
        final t = tc as Map<String, dynamic>;
        final fn = (t['function'] as Map<String, dynamic>?) ?? const {};
        final name = fn['name']?.toString() ?? 'unknown';
        final arguments = _parseArguments(fn['arguments']);
        final call = AgentToolCall(
          id: t['id']?.toString() ?? 'call_${iterations}_${calls.length}',
          name: name,
          arguments: arguments,
        );
        calls.add(call);
        yield AgentToolStartedEvent(call);
      }

      final parallelReadOnly = calls.length > 1 &&
          calls.every((call) => AgentReadOnlyTool.contains(call.name));

      final results = parallelReadOnly
          ? await Future.wait(calls.map((call) => _executeGuardedTool(call, guard)))
          : <_ToolResult>[
              for (final call in calls)
                await _executeGuardedTool(call, guard),
            ];

      for (var i = 0; i < calls.length; i++) {
        final call = calls[i];
        final result = results[i];
        call.status =
            result.success ? AgentToolStatus.success : AgentToolStatus.error;
        call.result = _truncate(result.output, toolResultMaxChars);

        if (result.success) {
          if (_isMutationTool(call.name)) _workspaceMutated = true;
          if (call.name == 'run_command' &&
              _isVerificationCommand(
                call.arguments['command']?.toString() ?? '',
              )) {
            _verificationObserved = true;
          }
          guard.recordResult(call.name, result.output);
        }
        final toolMsg = <String, dynamic>{
          'role': 'tool',
          'tool_call_id': call.id,
          'content': _truncate(result.output, maxToolContextChars),
        };
        apiMessages.add(toolMsg);
        _workingMessages.add(toolMsg);
        yield AgentToolFinishedEvent(call);

        if (_stopRequested) {
          yield const AgentStoppedEvent();
          return;
        }
      }
    }
  }

  bool _isMutationTool(String name) {
    return name == 'write_file' ||
        name == 'apply_diff' ||
        name == 'delete_file' ||
        name == 'create_directory';
  }

  bool _isVerificationCommand(String command) {
    final lower = command.toLowerCase();
    const markers = <String>[
      'test',
      'build',
      'analyze',
      'lint',
      'typecheck',
      'type-check',
      'check',
      'verify',
      'compile',
      'fmt',
    ];
    return markers.any(lower.contains);
  }

  Future<_ToolResult> _executeGuardedTool(
    AgentToolCall call,
    AgentRunGuard guard,
  ) async {
    final blocked = guard.reserveTool(call.name, call.arguments);
    if (blocked != null) {
      return _ToolResult('(agent guard) $blocked', success: false);
    }
    return _executeTool(call.name, call.arguments);
  }

  /// Whether an API error is Groq's hard rejection of a malformed tool call
  /// (rather than a genuine transport/API failure).
  static bool _isToolUseFailure(String error) {
    final e = error.toLowerCase();
    return e.contains('tool_use_failed') ||
        e.contains('failed to call a function');
  }

  /// How many times a `tool_use_failed` response is retried with a corrective
  /// hint before surfacing the error to the user.
  static const maxToolFailRetries = 2;

  // ─── Final-answer streaming (typewriter) ──────────────────────────────────

  Stream<AgentEvent> _emitTypedText(String text) async* {
    if (text.isEmpty) return;
    const chunkSize = 64;
    for (var i = 0; i < text.length; i += chunkSize) {
      if (_stopRequested) break;
      final end = min(i + chunkSize, text.length);
      yield AgentTextTokenEvent(text.substring(i, end));
      await Future<void>.delayed(const Duration(milliseconds: 14));
    }
  }

  // ─── Tool execution ────────────────────────────────────────────────────────

  Future<_ToolResult> _executeTool(
      String name, Map<String, dynamic> args) async {
    try {
      switch (name) {
        case 'read_file':
          final path = args['path']?.toString() ?? '';
          final result = await _backend.executeAgentTool(
            'file.read',
            {'path': _relPath(path)},
            workspaceRoot: _workspaceRoot,
          );
          if (!result.ok) {
            return _ToolResult('(error) ${result.error}', success: false);
          }
          return _ToolResult('${_relPath(path)}\n${result.output}');

        case 'write_file':
          final path = args['path']?.toString() ?? '';
          final content = args['content']?.toString() ?? '';
          final result = await _backend.executeAgentTool(
            'file.write',
            {'path': _relPath(path), 'content': content},
            workspaceRoot: _workspaceRoot,
          );
          if (!result.ok) {
            return _ToolResult('(error) ${result.error}', success: false);
          }
          final size = _jsonField(result.output, 'size') ?? content.length;
          return _ToolResult('Wrote $size characters to ${_relPath(path)}');

        case 'delete_file':
          final path = args['path']?.toString() ?? '';
          if (path.isEmpty) {
            return const _ToolResult('(error) No path provided.',
                success: false);
          }
          final result = await _backend.executeAgentTool(
            'file.delete',
            {'path': _relPath(path)},
            workspaceRoot: _workspaceRoot,
          );
          if (!result.ok) {
            return _ToolResult('(error) ${result.error}', success: false);
          }
          return _ToolResult('Deleted ${_relPath(path)}');

        case 'create_directory':
          final path = args['path']?.toString() ?? '';
          if (path.isEmpty) {
            return const _ToolResult('(error) No path provided.',
                success: false);
          }
          final result = await _backend.executeAgentTool(
            'file.mkdir',
            {'path': _relPath(path)},
            workspaceRoot: _workspaceRoot,
          );
          if (!result.ok) {
            return _ToolResult('(error) ${result.error}', success: false);
          }
          return _ToolResult('Created directory ${_relPath(path)}');

        case 'apply_diff':
          final path = args['path']?.toString() ?? '';
          final result = await _backend.executeAgentTool(
            'file.apply_diff',
            {
              'path': _relPath(path),
              'target': args['target']?.toString() ?? '',
              'replacement': args['replacement']?.toString() ?? '',
            },
            workspaceRoot: _workspaceRoot,
          );
          if (!result.ok) {
            return _ToolResult('(error) ${result.error}', success: false);
          }
          return _ToolResult('Applied edit to ${_relPath(path)}');

        case 'list_directory':
          final path = args['path']?.toString() ?? '.';
          final result = await _backend.executeAgentTool(
            'file.list',
            {'path': _relPath(path)},
            workspaceRoot: _workspaceRoot,
          );
          if (!result.ok) {
            return _ToolResult('(error) ${result.error}', success: false);
          }
          return _ToolResult(_formatList(result.output));

        case 'run_command':
          final command = args['command']?.toString() ?? '';
          if (command.isEmpty) {
            return const _ToolResult('(error) No command provided.',
                success: false);
          }
          // Never execute shell commands without an explicit approval
          // policy. The UI normally supplies the handler; headless callers
          // must opt in explicitly in the same way.
          if (approvalHandler == null) {
            return const _ToolResult(
              '(approval required) No command approval handler is configured.',
              success: false,
            );
          }
          final approved = await approvalHandler!(name, args);
          if (!approved) {
            return const _ToolResult(
              '(approval rejected) The user did not approve this command.',
              success: false,
            );
          }
          final result = await _backend.executeAgentTool(
            'process.run',
            {'command': command, 'approved': true},
            workspaceRoot: _workspaceRoot,
            timeout: _agentToolTimeout,
          );
          if (!result.ok) {
            final out = result.output.trim();
            return _ToolResult(
              '(error) ${result.error}${out.isEmpty ? '' : '\n$out'}',
              success: false,
            );
          }
          return _ToolResult(result.output);

        case 'search_workspace':
          final query = args['query']?.toString() ?? '';
          if (query.isEmpty) {
            return const _ToolResult('(error) No query provided.',
                success: false);
          }
          return _ToolResult(await _searchWorkspace(query));

        default:
          return _ToolResult('(error) Unknown tool: $name', success: false);
      }
    } catch (e) {
      return _ToolResult('(error) $e', success: false);
    }
  }

  /// Socket ceiling for a single agent tool call. The engine's `process.run`
  /// watchdog kills long commands well before this.
  static const _agentToolTimeout = Duration(seconds: 180);

  /// Workspace grep through the engine's `workspace.search` tool, with an
  /// offline fallback scan when the engine is unavailable or finds nothing.
  Future<String> _searchWorkspace(String query) async {
    try {
      final result = await _backend.executeAgentTool(
        'workspace.search',
        {'query': query},
        workspaceRoot: _workspaceRoot,
      );
      if (result.ok) {
        final formatted = _formatSearchHits(result.output);
        if (formatted.isNotEmpty) return formatted;
      }
    } catch (e) {
      debugPrint('Zig workspace search failed ($e); using local scan');
    }
    return _localSearch(query);
  }

  String _formatSearchHits(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List || decoded.isEmpty) return '';
      final buffer = StringBuffer();
      for (final item in decoded) {
        final map = item as Map<String, dynamic>;
        buffer.writeln(
            '${map['path']}:${map['line']}:${map['col']}: ${map['text']}');
      }
      return buffer.toString().trim();
    } catch (_) {
      return '';
    }
  }

  /// Formats the `file.list` JSON entries (`[{"name","kind"}]`) the same way
  /// the engine-side listing is shown to the model.
  String _formatList(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return json;
      final lines = decoded.map((e) {
        final map = e as Map<String, dynamic>;
        final name = map['name']?.toString() ?? '';
        final kind = map['kind']?.toString() ?? 'file';
        return kind == 'directory' ? '📁 $name' : '📄 $name';
      }).toList();
      return lines.isEmpty ? '(empty directory)' : lines.join('\n');
    } catch (_) {
      return json;
    }
  }

  int? _jsonField(String json, String key) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map<String, dynamic>) {
        final v = decoded[key];
        if (v is num) return v.toInt();
      }
    } catch (_) {}
    return null;
  }

  Future<String> _localSearch(String query) async {
    final buffer = StringBuffer();
    final lowered = query.toLowerCase();
    var count = 0;

    Future<void> walk(Directory dir) async {
      if (count >= 50) return;
      try {
        await for (final entity in dir.list(followLinks: false)) {
          if (count >= 50) return;
          final name = entity.path.split(Platform.pathSeparator).last;
          if (_junkDirs.contains(name)) continue;
          if (entity is Directory) {
            await walk(entity);
          } else if (entity is File && !name.endsWith('.git')) {
            try {
              if (await entity.length() > 512 * 1024) continue;
              final lines = (await entity.readAsString()).split('\n');
              for (var i = 0; i < lines.length; i++) {
                if (lines[i].toLowerCase().contains(lowered)) {
                  buffer.writeln('${entity.path}:${i + 1}: ${lines[i].trim()}');
                  count++;
                  if (count >= 50) return;
                }
              }
            } catch (_) {}
          }
        }
      } catch (_) {}
    }

    await walk(Directory(_workspaceRoot));
    return buffer.isEmpty ? '(no matches)' : buffer.toString().trim();
  }

  static const _junkDirs = {
    '.git',
    '.zig-cache',
    'zig-out',
    'node_modules',
    'build',
    'dist',
    '.dart_tool',
    'target',
  };

  // ─── Helpers ───────────────────────────────────────────────────────────────

  String _resolvePath(String raw) {
    var p = raw.trim();
    if (p.isEmpty) return _workspaceRoot;
    if (p == '~' || p.startsWith('~/')) {
      final home = Platform.environment['HOME'] ?? '/home';
      p = p.replaceFirst('~', home);
    }
    final isAbsolute =
        p.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p);
    if (!isAbsolute) {
      p = '$_workspaceRoot/$p';
    }
    return p;
  }

  /// The engine sandbox works on workspace-relative paths: express the raw
  /// model path relative to [_workspaceRoot]. Paths outside the workspace
  /// become `../` segments, which the engine rejects (PathEscapesWorkspace).
  String _relPath(String raw) {
    final abs = _resolvePath(raw);
    final rootPrefix =
        _workspaceRoot.endsWith('/') ? _workspaceRoot : '$_workspaceRoot/';
    if (abs.startsWith(rootPrefix)) {
      final rel = abs.substring(rootPrefix.length);
      return rel.isEmpty ? '.' : rel;
    }
    final rootSegs = rootPrefix.split('/').where((s) => s.isNotEmpty).toList();
    final absSegs = abs.split('/').where((s) => s.isNotEmpty).toList();
    var common = 0;
    while (common < rootSegs.length &&
        common < absSegs.length &&
        rootSegs[common] == absSegs[common]) {
      common++;
    }
    final ups = List.filled(rootSegs.length - common, '..');
    final downs = absSegs.sublist(common);
    final joined = [...ups, ...downs].join('/');
    return joined.isEmpty ? '.' : joined;
  }

  Map<String, dynamic> _parseArguments(dynamic raw) {
    if (raw == null) return const <String, dynamic>{};
    if (raw is Map<String, dynamic>) {
      return Map<String, dynamic>.from(raw);
    }
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    final text = raw.toString().trim();
    if (text.isEmpty) return const <String, dynamic>{};
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {
      // The provider emitted malformed arguments. The tool invocation will
      // return a structured error and the model can repair the call.
    }
    return const <String, dynamic>{};
  }

  String _truncate(String text, [int? limit]) {
    final maxChars = (limit ?? toolResultMaxChars).clamp(256, 1 << 20).toInt();
    if (text.length <= maxChars) return text;

    // Keep both the beginning (diagnostics/context) and the tail (compiler
    // summaries, exit codes and stack traces) instead of discarding the tail.
    final head = (maxChars * 2) ~/ 3;
    final tail = maxChars - head;
    final omitted = text.length - head - tail;
    return '${text.substring(0, head)}\n'
        '…[$omitted chars truncated]…\n'
        '${text.substring(text.length - tail)}';
  }
}
