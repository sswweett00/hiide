// Verifies the agentic loop in AgentController: native function calling,
// tool execution, result feedback, cancellation, and budget enforcement.
// Uses a scripted fake AiChatClient — no network access.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiide_flutter/core/backend/agent_controller.dart';
import 'package:hiide_flutter/core/backend/ai_chat_client.dart';
import 'package:hiide_flutter/core/backend/backend_service.dart';
import 'package:hiide_flutter/core/backend/mock_backend_service.dart';
import 'package:hiide_flutter/core/backend/terminal_service.dart';

Map<String, dynamic> _toolResponse(
  String id,
  String name,
  Map<String, dynamic> args,
) {
  return {
    'choices': [
      {
        'message': {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': id,
              'type': 'function',
              'function': {'name': name, 'arguments': jsonEncode(args)},
            },
          ],
        },
      },
    ],
  };
}

Map<String, dynamic> _textResponse(String text) {
  return {
    'choices': [
      {
        'message': {'role': 'assistant', 'content': text},
      },
    ],
  };
}

class FakeAiClient implements AiChatClient {
  FakeAiClient(this.responses, {this.onCall});

  final List<Map<String, dynamic>> responses;
  final Future<void> Function(int callIndex)? onCall;

  int calls = 0;
  List<Map<String, dynamic>> lastMessages = [];

  @override
  Future<Map<String, dynamic>> chatCompletion({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    String? model,
    double temperature = 0.2,
  }) async {
    final idx = calls < responses.length ? calls : responses.length - 1;
    if (onCall != null) await onCall!(idx);
    calls++;
    lastMessages = messages;
    return responses[idx];
  }

  @override
  Stream<String> chatCompletionStream({
    required List<Map<String, dynamic>> messages,
    String? model,
  }) async* {}
}

void main() {
  late Directory tempDir;
  late TerminalService terminal;
  late MockBackendService backend;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('hiide_agent_test');
    terminal = TerminalService();
    backend = MockBackendService();
  });

  tearDown(() {
    terminal.dispose();
    backend.dispose();
    tempDir.deleteSync(recursive: true);
  });

  AgentController makeController(AiChatClient ai, {int maxIterations = 15}) {
    return AgentController(
      ai: ai,
      backend: backend,
      workspaceRoot: tempDir.path,
      model: 'test-model',
      maxIterations: maxIterations,
    );
  }

  test('executes tool calls and feeds results back to the model', () async {
    final file = File('${tempDir.path}/hello.txt')
      ..writeAsStringSync('hello world');
    final ai = FakeAiClient([
      _toolResponse('call_1', 'read_file', {'path': file.path}),
      _toolResponse('call_2', 'run_command', {'command': 'echo agent-works'}),
      _textResponse('I read the file and ran the command.'),
    ]);

    final controller = makeController(ai);
    final events = await controller.run([
      {'role': 'user', 'content': 'read hello.txt and echo'},
    ]).toList();

    // Tool events in order.
    expect(events.whereType<AgentToolStartedEvent>().length, 2);
    final finished = events.whereType<AgentToolFinishedEvent>().toList();
    expect(finished.length, 2);

    expect(finished[0].toolCall.name, 'read_file');
    expect(finished[0].toolCall.status, AgentToolStatus.success);
    expect(finished[0].toolCall.result, contains('hello world'));

    expect(finished[1].toolCall.name, 'run_command');
    expect(finished[1].toolCall.status, AgentToolStatus.success);
    expect(finished[1].toolCall.result, contains('agent-works'));

    // Final answer is streamed then completed.
    final typed =
        events.whereType<AgentTextTokenEvent>().map((e) => e.token).join();
    expect(typed, 'I read the file and ran the command.');
    expect(events.last, isA<AgentDoneEvent>());

    // Canonical history: user, assistant(tool_calls), tool,
    // assistant(tool_calls), tool, assistant(content).
    final history = controller.workingMessages;
    expect(history.length, 6);
    expect(history[0]['role'], 'user');
    expect(history[1]['role'], 'assistant');
    expect((history[1]['tool_calls'] as List).length, 1);
    expect(history[2]['role'], 'tool');
    expect(history[2]['tool_call_id'], 'call_1');
    expect(history[2]['content'], contains('hello world'));
    expect(history[5]['role'], 'assistant');
    expect(history[5]['content'], 'I read the file and ran the command.');

    // The second model call received the tool result.
    expect(ai.lastMessages.any((m) => m['role'] == 'tool'), isTrue);
  });

  test('write_file creates the file on disk with relative path resolution',
      () async {
    final ai = FakeAiClient([
      _toolResponse('call_1', 'write_file', {
        'path': 'new_file.txt',
        'content': 'line1\nline2',
      }),
      _textResponse('done'),
    ]);

    final controller = makeController(ai);
    await controller.run([
      {'role': 'user', 'content': 'create new_file.txt'},
    ]).toList();

    expect(
      File('${tempDir.path}/new_file.txt').readAsStringSync(),
      'line1\nline2',
    );
    final toolMsg = controller.workingMessages[2]['content'] as String;
    expect(toolMsg, contains('Wrote 11 characters'));
  });

  test('delete_file deletes a file or directory from workspace', () async {
    final file = File('${tempDir.path}/to_delete.txt')
      ..writeAsStringSync('goodbye');
    expect(file.existsSync(), isTrue);

    final ai = FakeAiClient([
      _toolResponse('call_1', 'delete_file', {
        'path': 'to_delete.txt',
      }),
      _textResponse('deleted'),
    ]);

    final controller = makeController(ai);
    await controller.run([
      {'role': 'user', 'content': 'delete to_delete.txt'},
    ]).toList();

    expect(file.existsSync(), isFalse);
    final toolMsg = controller.workingMessages[2]['content'] as String;
    expect(toolMsg, contains('Deleted to_delete.txt'));
  });

  test('create_directory creates directories in workspace', () async {
    final dir = Directory('${tempDir.path}/sub/folder');
    expect(dir.existsSync(), isFalse);

    final ai = FakeAiClient([
      _toolResponse('call_1', 'create_directory', {
        'path': 'sub/folder',
      }),
      _textResponse('created'),
    ]);

    final controller = makeController(ai);
    await controller.run([
      {'role': 'user', 'content': 'create directory sub/folder'},
    ]).toList();

    expect(dir.existsSync(), isTrue);
    final toolMsg = controller.workingMessages[2]['content'] as String;
    expect(toolMsg, contains('Created directory sub/folder'));
  });

  test('apply_diff applies a targeted edit', () async {
    final file = File('${tempDir.path}/app.dart')
      ..writeAsStringSync('void main() { run(); }\n');
    final ai = FakeAiClient([
      _toolResponse('apply_diff', 'apply_diff', {
        'path': 'app.dart',
        'target': 'run()',
        'replacement': 'runTwice()',
      }),
      _textResponse('edited'),
    ]);

    final controller = makeController(ai);
    await controller.run([
      {'role': 'user', 'content': 'edit app.dart'},
    ]).toList();

    expect(file.readAsStringSync(), contains('runTwice()'));
  });

  test('failed tool calls are reported as errors but do not abort the loop',
      () async {
    final ai = FakeAiClient([
      _toolResponse('call_1', 'read_file', {'path': 'missing.txt'}),
      _textResponse('recovered'),
    ]);

    final controller = makeController(ai);
    final events = await controller.run([
      {'role': 'user', 'content': 'read missing.txt'},
    ]).toList();

    final finished = events.whereType<AgentToolFinishedEvent>().single;
    expect(finished.toolCall.status, AgentToolStatus.error);
    expect(finished.toolCall.result, contains('file not found'));
    expect(events.last, isA<AgentDoneEvent>());
  });

  test(
      'tool calls are dispatched to the backend with engine tool ids and '
      'workspace-relative paths', () async {
    final file = File('${tempDir.path}/probe.txt')
      ..writeAsStringSync('probe-content');
    final recorded = <(String, Map<String, dynamic>)>[];

    final spy = _RecordingBackend(backend, (toolId, input) {
      recorded.add((toolId, Map<String, dynamic>.from(input)));
    });

    final ai = FakeAiClient([
      _toolResponse('call_1', 'read_file', {'path': file.path}), // absolute
      _toolResponse('call_2', 'list_directory', {'path': '.'}),
      _toolResponse('call_3', 'write_file', {
        'path': 'nested/out.txt',
        'content': 'abc',
      }),
      _textResponse('done'),
    ]);

    final controller = AgentController(
      ai: ai,
      backend: spy,
      workspaceRoot: tempDir.path,
      model: 'test-model',
    );
    await controller.run([
      {'role': 'user', 'content': 'go'},
    ]).toList();

    expect(recorded.map((r) => r.$1).toList(), [
      'file.read',
      'file.list',
      'file.write',
    ]);
    // Absolute paths inside the workspace are normalized to relative so the
    // engine sandbox can enforce them.
    expect(recorded[0].$2['path'], 'probe.txt');
    expect(recorded[1].$2['path'], '.');
    expect(recorded[2].$2['path'], 'nested/out.txt');
    expect(File('${tempDir.path}/nested/out.txt').existsSync(), isTrue);
  });

  test(
      'search_workspace falls back to a local scan when the engine index '
      'is empty (offline/mock)', () async {
    File('${tempDir.path}/search_target.dart')
        .writeAsStringSync('// findUniqueTokenHere\n');
    final ai = FakeAiClient([
      _toolResponse(
          'call_1', 'search_workspace', {'query': 'findUniqueTokenHere'}),
      _textResponse('found it'),
    ]);

    final controller = makeController(ai);
    await controller.run([
      {'role': 'user', 'content': 'search'},
    ]).toList();

    final toolMsg = controller.workingMessages[2]['content'] as String;
    expect(toolMsg, contains('findUniqueTokenHere'));
    expect(toolMsg, contains('search_target.dart'));
  });

  test('stops cleanly when stop() is requested', () async {
    late AgentController controller;
    final ai = FakeAiClient([
      _toolResponse('call_1', 'read_file', {'path': 'nope.txt'}),
      _textResponse('never shown'),
    ], onCall: (i) async {
      if (i == 1) controller.stop();
    });

    controller = makeController(ai);
    final events = await controller.run([
      {'role': 'user', 'content': 'go'},
    ]).toList();

    expect(events.any((e) => e is AgentStoppedEvent), isTrue);
    expect(events.any((e) => e is AgentDoneEvent), isFalse);
  });

  test('enforces the iteration budget', () async {
    final ai = FakeAiClient([
      _toolResponse('call_1', 'list_directory', {'path': '.'}),
      _toolResponse('call_2', 'list_directory', {'path': '.'}),
      _toolResponse('call_3', 'list_directory', {'path': '.'}),
    ]);

    final controller = makeController(ai, maxIterations: 2);
    final events = await controller.run([
      {'role': 'user', 'content': 'loop'},
    ]).toList();

    expect(events.last, isA<AgentIterationLimitEvent>());
    expect((events.last as AgentIterationLimitEvent).iterations, 2);
  });

  test('surfaces API errors to the caller', () async {
    final ai = FakeAiClient([
      {'error': 'rate limited, try again later'},
    ]);

    final controller = makeController(ai);
    final events = await controller.run([
      {'role': 'user', 'content': 'hi'},
    ]).toList();

    expect(events.single, isA<AgentErrorEvent>());
    expect(
        (events.single as AgentErrorEvent).message, contains('rate limited'));
  });

  test(
      'recovers from Groq tool_use_failed by retrying with a corrective '
      'hint, without burning iteration budget', () async {
    // First response is Groq's hard rejection of malformed tool-call JSON;
    // the loop must retry instead of surfacing the error.
    final ai = FakeAiClient([
      {
        'error': "Failed to call a function. Please adjust your prompt. See "
            "'failed_generation' for more details.",
      },
      _toolResponse('call_1', 'list_directory', {'path': '.'}),
      _textResponse('listed the directory'),
    ]);

    final controller = makeController(ai, maxIterations: 2);
    final events = await controller.run([
      {'role': 'user', 'content': 'list the root'},
    ]).toList();

    // The tool round still executed and the final answer arrived: the retry
    // did not surface an error nor consume an iteration (2 API calls for a
    // budget of 2, instead of 3).
    expect(events.any((e) => e is AgentErrorEvent), isFalse);
    expect(events.whereType<AgentToolFinishedEvent>().length, 1);
    expect(events.last, isA<AgentDoneEvent>());
    expect(ai.calls, 3);

    // The corrective system note was appended before the retried call.
    final retryCall = ai.lastMessages;
    expect(
      retryCall.any((m) =>
          m['role'] == 'system' &&
          (m['content'] as String).contains('invalid JSON')),
      isTrue,
    );
  });

  test('gives up on tool_use_failed after the retry budget is exhausted',
      () async {
    final ai = FakeAiClient([
      {'error': 'tool_use_failed: malformed arguments'},
      {'error': 'tool_use_failed: malformed arguments'},
      {'error': 'tool_use_failed: malformed arguments'},
      {'error': 'tool_use_failed: malformed arguments'},
    ]);

    final controller = makeController(ai);
    final events = await controller.run([
      {'role': 'user', 'content': 'go'},
    ]).toList();

    expect(events.single, isA<AgentErrorEvent>());
    expect((events.single as AgentErrorEvent).message,
        contains('tool_use_failed'));
    // 1 original + 2 retries, then the error is surfaced.
    expect(ai.calls, 3);
  });
}

/// Delegates to a [MockBackendService] while recording every agent tool call.
class _RecordingBackend implements BackendService {
  _RecordingBackend(this._inner, this.onTool);

  final BackendService _inner;
  final void Function(String toolId, Map<String, dynamic> input) onTool;

  @override
  Future<AgentToolResult> executeAgentTool(
    String toolId,
    Map<String, dynamic> input, {
    String? workspaceRoot,
    Duration? timeout,
  }) {
    onTool(toolId, input);
    return _inner.executeAgentTool(toolId, input,
        workspaceRoot: workspaceRoot, timeout: timeout);
  }

  @override
  Future<void> connect() => _inner.connect();

  @override
  Future<void> disconnect() => _inner.disconnect();

  @override
  void dispose() => _inner.dispose();

  @override
  Future<int> editorDelete(int handle, int pos, int len) =>
      _inner.editorDelete(handle, pos, len);

  @override
  Future<void> editorApplyText(int handle, String text) =>
      _inner.editorApplyText(handle, text);

  @override
  Future<void> editorDestroy(int handle) => _inner.editorDestroy(handle);

  @override
  Future<List<EditorDiffRegion>> editorDiffLines(int handle, String diskText) =>
      _inner.editorDiffLines(handle, diskText);

  @override
  Future<String> editorGetText(int handle) => _inner.editorGetText(handle);

  @override
  Future<String> editorHighlight(int handle, String lang) =>
      _inner.editorHighlight(handle, lang);

  @override
  Future<int> editorInsert(int handle, int pos, String text) =>
      _inner.editorInsert(handle, pos, text);

  @override
  Future<int> editorLineCount(int handle) => _inner.editorLineCount(handle);

  @override
  Future<int> editorLoad(String text) => _inner.editorLoad(text);

  @override
  Future<void> editorRedo(int handle) => _inner.editorRedo(handle);

  @override
  Future<List<EditorSearchResult>> editorSearch(int handle, String query) =>
      _inner.editorSearch(handle, query);

  @override
  Future<int> editorSize(int handle) => _inner.editorSize(handle);

  @override
  Future<void> editorUndo(int handle) => _inner.editorUndo(handle);

  @override
  bool get isConnected => _inner.isConnected;

  @override
  Stream<FsChange> get fsChangeStream => _inner.fsChangeStream;

  @override
  Future<void> watchWorkspace(String root) => _inner.watchWorkspace(root);

  @override
  Future<void> unwatchWorkspace() => _inner.unwatchWorkspace();

  @override
  Stream<String> get outputStream => _inner.outputStream;

  @override
  Future<String> ping() => _inner.ping();

  @override
  Future<List<WorkspaceSearchResult>> workspaceSearch(
    String root,
    String query, {
    int maxResults = 200,
  }) =>
      _inner.workspaceSearch(root, query, maxResults: maxResults);

  @override
  Future<List<WorkspaceFile>> workspaceTree(
    String root, {
    int maxEntries = 50000,
  }) =>
      _inner.workspaceTree(root, maxEntries: maxEntries);
}
