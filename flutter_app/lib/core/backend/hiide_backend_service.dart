import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'backend_service.dart';

/// Production backend: speaks the Zig engine's wire protocol.
///
/// Transport: TCP to `127.0.0.1:4879` (the `hiide-ipc-server` binary).
/// Framing:   one JSON object per line — request lines from the client,
///            response lines from the server, correlated by `id`.
///
/// NOTE: the Zig server historically uses raw JSON values for `editor.load`
/// (params = the text string) and `editor.get_text` (params = the handle int),
/// and JSON objects for every newer method. `_request` accepts any JSON value.
class HiideBackendService implements BackendService {
  HiideBackendService({this.host = '127.0.0.1', this.port = 4879});

  final String host;
  final int port;

  static const Duration _connectTimeout = Duration(seconds: 3);
  static const Duration _requestTimeout = Duration(seconds: 15);

  /// Agent tool calls can run long builds/tests; the engine's `process.run`
  /// watchdog kills the command well before this socket ceiling.
  static const Duration _agentToolTimeout = Duration(seconds: 180);

  Socket? _socket;
  final StreamController<String> _output = StreamController<String>.broadcast();
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final StringBuffer _buffer = StringBuffer();
  int _nextId = 1;
  bool _connected = false;

  /// Pushed `fs.change` events from the native watcher (broadcast; the
  /// workspace tree provider and open editor tabs subscribe here).
  final StreamController<FsChange> _fsChanges =
      StreamController<FsChange>.broadcast();

  @override
  Stream<FsChange> get fsChangeStream => _fsChanges.stream;

  @override
  Stream<String> get outputStream => _output.stream;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async {
    if (_connected) return;

    final socket = await Socket.connect(host, port, timeout: _connectTimeout);
    _socket = socket;
    _connected = true;
    _buffer.clear();
    socket.listen(_onData, onDone: _onDisconnected, onError: _onSocketError);

    // Handshake: confirm we are talking to the Zig engine.
    final hello = await _request('hello', null);
    _output.add(
      'Connected to Hiide Zig engine '
      '(${hello['service']} v${hello['version']}) on $host:$port',
    );
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    final socket = _socket;
    _socket = null;
    socket?.destroy();
    _failPending(StateError('disconnected'));
    _output.add('Backend disconnected');
  }

  void _onData(List<int> data) {
    _buffer.write(utf8.decode(data));
    var text = _buffer.toString();
    _buffer.clear();

    var newline = text.indexOf('\n');
    while (newline != -1) {
      final line = text.substring(0, newline).trim();
      text = text.substring(newline + 1);
      if (line.isNotEmpty) _handleLine(line);
      newline = text.indexOf('\n');
    }
    _buffer.write(text);
  }

  void _handleLine(String line) {
    Map<String, dynamic> message;
    try {
      message = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    // Server-pushed events have no request id.
    if (message['event'] == 'fs.change') {
      final params = message['params'] as Map<String, dynamic>? ?? const {};
      final changes = params['changes'] as List<dynamic>? ?? const [];
      for (final raw in changes) {
        final map = raw as Map<String, dynamic>;
        _fsChanges.add(FsChange(
          path: map['path']?.toString() ?? '',
          isDirectory: map['is_dir'] == true,
          kind: map['kind']?.toString() ?? 'modified',
        ));
      }
      return;
    }

    final id = message['id'];
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer != null && !completer.isCompleted)
      completer.complete(message);
  }

  void _onDisconnected() {
    _connected = false;
    _socket = null;
    _failPending(StateError('connection closed by engine'));
    _output.add('Backend disconnected');
  }

  void _onSocketError(Object error) {
    _connected = false;
    _socket = null;
    _failPending(StateError('socket error: $error'));
  }

  void _failPending(Object error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Object? params, {
    Duration? timeout,
  }) async {
    final socket = _socket;
    if (socket == null) {
      throw StateError('backend not connected');
    }
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;

    final message = <String, dynamic>{'id': id, 'method': method};
    if (params != null) message['params'] = params;
    socket.write('${jsonEncode(message)}\n');

    try {
      return await completer.future.timeout(timeout ?? _requestTimeout);
    } on TimeoutException {
      _pending.remove(id);
      rethrow;
    }
  }

  Map<String, dynamic> _expectResult(Map<String, dynamic> response) {
    final err = response['err'];
    if (err != null) {
      throw StateError('engine error: $err');
    }
    return (response['result'] as Map<String, dynamic>?) ?? const {};
  }

  @override
  Future<String> ping() async {
    final response = await _request('ping', null);
    return response['result'] as String? ?? '';
  }

  @override
  Future<int> editorLoad(String text) async {
    final result = _expectResult(await _request('editor.load', text));
    return result['handle'] as int;
  }

  @override
  Future<String> editorGetText(int handle) async {
    final result = _expectResult(await _request('editor.get_text', handle));
    return result['text'] as String? ?? '';
  }

  Future<Map<String, dynamic>> _editorObjectOp(
    String method,
    int handle, {
    int? pos,
    int? len,
    String? text,
    String? query,
    String? lang,
  }) async {
    final params = <String, dynamic>{'handle': handle};
    if (pos != null) params['pos'] = pos;
    if (len != null) params['len'] = len;
    if (text != null) params['text'] = text;
    if (query != null) params['query'] = query;
    if (lang != null) params['lang'] = lang;
    return _expectResult(await _request(method, params));
  }

  @override
  Future<int> editorInsert(int handle, int pos, String text) async {
    final result =
        await _editorObjectOp('editor.insert', handle, pos: pos, text: text);
    return result['size'] as int? ?? 0;
  }

  @override
  Future<int> editorDelete(int handle, int pos, int len) async {
    final result =
        await _editorObjectOp('editor.delete', handle, pos: pos, len: len);
    return result['size'] as int? ?? 0;
  }

  @override
  Future<void> editorUndo(int handle) async {
    await _editorObjectOp('editor.undo', handle);
  }

  @override
  Future<void> editorRedo(int handle) async {
    await _editorObjectOp('editor.redo', handle);
  }

  @override
  Future<int> editorLineCount(int handle) async {
    final result = await _editorObjectOp('editor.line_count', handle);
    return result['lines'] as int? ?? 0;
  }

  @override
  Future<int> editorSize(int handle) async {
    final result = await _editorObjectOp('editor.size', handle);
    return result['size'] as int? ?? 0;
  }

  @override
  Future<List<EditorSearchResult>> editorSearch(
      int handle, String query) async {
    final result = await _editorObjectOp('editor.search', handle, query: query);
    final raw = (result['results'] as List<dynamic>?) ?? const [];
    return raw.map((item) {
      final map = item as Map<String, dynamic>;
      return EditorSearchResult(
        line: map['line'] as int,
        col: map['col'] as int,
        text: map['text'] as String? ?? '',
      );
    }).toList();
  }

  @override
  Future<String> editorHighlight(int handle, String lang) async {
    final result =
        await _editorObjectOp('editor.highlight', handle, lang: lang);
    return result['html'] as String? ?? '';
  }

  @override
  Future<void> editorDestroy(int handle) async {
    await _editorObjectOp('editor.destroy', handle);
  }

  @override
  Future<void> editorApplyText(int handle, String text) async {
    await _editorObjectOp('editor.apply_text', handle, text: text);
  }

  @override
  Future<List<EditorDiffRegion>> editorDiffLines(
      int handle, String diskText) async {
    final response = await _request('editor.diff_lines', {
      'handle': handle,
      'disk_text': diskText,
    });
    final result = _expectResult(response);
    final raw = (result['changes'] as List<dynamic>?) ?? const [];
    return raw.map((item) {
      final map = item as Map<String, dynamic>;
      return EditorDiffRegion(
        line: map['line'] as int,
        kind: map['kind']?.toString() ?? 'modified',
        count: map['count'] as int? ?? 1,
      );
    }).toList();
  }

  @override
  Future<List<WorkspaceSearchResult>> workspaceSearch(
    String root,
    String query, {
    int maxResults = 200,
  }) async {
    final response = await _request('workspace.search', {
      'root': root,
      'query': query,
      'max_results': maxResults,
    });
    final result = _expectResult(response);
    final raw = (result['results'] as List<dynamic>?) ?? const [];
    return raw.map((item) {
      final map = item as Map<String, dynamic>;
      return WorkspaceSearchResult(
        path: map['path'] as String? ?? '',
        line: map['line'] as int,
        col: map['col'] as int,
        text: map['text'] as String? ?? '',
      );
    }).toList();
  }

  @override
  Future<List<WorkspaceFile>> workspaceTree(
    String root, {
    int maxEntries = 50000,
  }) async {
    final response = await _request('workspace.tree', {
      'root': root,
      'max_entries': maxEntries,
    });
    final result = _expectResult(response);
    final raw = (result['entries'] as List<dynamic>?) ?? const [];
    return raw.map((item) {
      final map = item as Map<String, dynamic>;
      return WorkspaceFile(
        name: map['name'] as String? ?? '',
        path: map['path'] as String? ?? '',
        isDirectory: map['kind']?.toString() == 'directory',
        size: map['size'] as int? ?? 0,
      );
    }).toList();
  }

  @override
  Future<AgentToolResult> executeAgentTool(
    String toolId,
    Map<String, dynamic> input, {
    String? workspaceRoot,
    Duration? timeout,
  }) async {
    final response = await _request(
      'agent.tool.execute',
      {
        'tool': toolId,
        'input': jsonEncode(input),
        if (workspaceRoot != null) 'workspace_root': workspaceRoot,
        'timeout_ms': (timeout ?? _agentToolTimeout).inMilliseconds,
      },
      timeout: timeout ?? _agentToolTimeout,
    );
    final result = response['result'] as Map<String, dynamic>? ?? const {};
    return AgentToolResult(
      ok: result['ok'] == true,
      output: result['output']?.toString() ?? '',
      error: result['error']?.toString() ?? '',
    );
  }

  @override
  Future<void> watchWorkspace(String root) async {
    await _request('watch.subscribe', {'root': root});
  }

  @override
  Future<void> unwatchWorkspace() async {
    await _request('watch.unsubscribe', null);
  }

  @override
  void dispose() {
    _output.close();
    _fsChanges.close();
    _connected = false;
    final socket = _socket;
    _socket = null;
    socket?.destroy();
  }
}
