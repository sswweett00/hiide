import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'backend_service.dart';

class HiideBackendService implements BackendService {
  HiideBackendService({this.host = '127.0.0.1', this.port = 4879});
  final String host;
  final int port;
  static const Duration _connectTimeout = Duration(seconds: 3);
  static const Duration _requestTimeout = Duration(seconds: 15);
  static const Duration _agentToolTimeout = Duration(seconds: 180);
  static const int _maxLineBytes = 2 * 1024 * 1024;
  static const int _maxSearchResults = 1000;
  static const int _maxTreeEntries = 50000;

  Socket? _socket;
  StreamSubscription<String>? _socketSubscription;
  Future<void>? _connectFuture;
  final StreamController<String> _output = StreamController<String>.broadcast();
  final StreamController<FsChange> _fsChanges = StreamController<FsChange>.broadcast();
  final Map<int, Completer<Map<String, dynamic>>> _pending = <int, Completer<Map<String, dynamic>>>{};
  int _nextId = 1;
  bool _connected = false;
  bool _disposed = false;
  String? _watchedRoot;

  @override
  Stream<FsChange> get fsChangeStream => _fsChanges.stream;
  @override
  Stream<String> get outputStream => _output.stream;
  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() {
    if (_disposed) return Future<void>.error(StateError('backend disposed'));
    if (_connected) return Future<void>.value();
    return _connectFuture ??= _connectInternal().whenComplete(() => _connectFuture = null);
  }

  Future<void> _connectInternal() async {
    final socket = await Socket.connect(host, port, timeout: _connectTimeout);
    if (_disposed) {
      socket.destroy();
      throw StateError('backend disposed');
    }
    _socket = socket;
    _connected = true;
    _socketSubscription = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleLine, onDone: _onDisconnected, onError: _onSocketError);
    try {
      final hello = _expectResult(
        await _request('hello', null, timeout: _requestTimeout),
      );
      final protocolVersion = _requiredInt(hello, 'protocol_version');
      if (protocolVersion != hiideIpcProtocolVersion) {
        throw StateError(
          'Incompatible Hiide IPC protocol: engine=$protocolVersion '
          'client=$hiideIpcProtocolVersion',
        );
      }
      final transport = _requiredString(hello, 'transport');
      if (transport != hiideIpcTransport) {
        throw StateError(
          'Incompatible Hiide IPC transport: engine=$transport '
          'client=$hiideIpcTransport',
        );
      }
      final service = _requiredString(hello, 'service');
      final version = _requiredString(hello, 'version');
      _emitOutput(
        'Connected to $service v$version on $host:$port '
        '(IPC v$protocolVersion)',
      );
      final watched = _watchedRoot;
      if (watched != null && watched.isNotEmpty) {
        await _request('watch.subscribe', {'root': watched});
      }
    } catch (error) {
      await disconnect();
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    _failPending(StateError('disconnected'));
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    final socket = _socket;
    _socket = null;
    socket?.destroy();
    _emitOutput('Backend disconnected');
  }

  void _handleLine(String line) {
    if (line.length > _maxLineBytes) {
      _failPending(StateError('backend response exceeded maximum size'));
      unawaited(disconnect());
      return;
    }
    dynamic decoded;
    try { decoded = jsonDecode(line); } catch (_) { return; }
    if (decoded is! Map) return;
    final message = Map<String, dynamic>.from(decoded);
    if (message['event'] == 'fs.change') {
      try {
        final rawParams = message['params'];
        if (rawParams is! Map) {
          throw StateError(
            'IPC contract violation: fs.change params must be an object',
          );
        }
        final params = Map<String, dynamic>.from(rawParams);
        final root = _requiredString(params, 'root');
        if (_watchedRoot != null && root != _watchedRoot) return;
        final changes = _requiredList(params, 'changes');
        for (final raw in changes) {
          if (raw is! Map) {
            throw StateError(
              'IPC contract violation: fs.change item must be an object',
            );
          }
          final map = Map<String, dynamic>.from(raw);
          final path = _requiredString(map, 'path');
          final kind = _requiredString(map, 'kind');
          final isDirectory = _requiredBool(map, 'is_dir');
          if (!const {'created', 'modified', 'deleted'}.contains(kind)) {
            throw StateError(
              'IPC contract violation: unknown fs.change kind "$kind"',
            );
          }
          if (_fsChanges.isClosed) continue;
          _fsChanges.add(
            FsChange(
              path: path,
              isDirectory: isDirectory,
              kind: kind,
            ),
          );
        }
      } catch (error) {
        _emitOutput('Backend protocol error: $error');
        unawaited(disconnect());
      }
      return;
    }
    final id = message['id'];
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer != null && !completer.isCompleted) completer.complete(message);
  }

  void _onDisconnected() {
    _connected = false;
    _socket = null;
    _socketSubscription = null;
    _failPending(StateError('connection closed by engine'));
    _emitOutput('Backend disconnected');
  }

  void _onSocketError(Object error) {
    _connected = false;
    _socket = null;
    _failPending(StateError('socket error: $error'));
  }

  void _failPending(Object error) {
    final pending = List<Completer<Map<String, dynamic>>>.from(_pending.values);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) completer.completeError(error);
    }
  }

  void _emitOutput(String value) {
    if (!_output.isClosed) _output.add(value);
  }

  Future<Map<String, dynamic>> _request(String method, Object? params, {Duration? timeout}) async {
    final socket = _socket;
    if (!_connected || socket == null) throw StateError('backend not connected');
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    try {
      final message = <String, dynamic>{'id': id, 'method': method};
      if (params != null) message['params'] = params;
      socket.add(utf8.encode('${jsonEncode(message)}\n'));
      return await completer.future.timeout(timeout ?? _requestTimeout);
    } on TimeoutException {
      _pending.remove(id);
      throw TimeoutException('IPC request $method timed out');
    } catch (_) {
      _pending.remove(id);
      rethrow;
    }
  }

  Map<String, dynamic> _expectResult(Map<String, dynamic> response) {
    if (response['err'] != null) {
      throw StateError('engine error: ${response['err']}');
    }
    final value = response['result'];
    if (value is! Map) {
      throw StateError(
        'IPC contract violation: expected object result, got ${value.runtimeType}',
      );
    }
    return Map<String, dynamic>.from(value);
  }

  String _requiredString(Map<String, dynamic> value, String key) {
    final raw = value[key];
    if (raw is! String) {
      throw StateError('IPC contract violation: "$key" must be a string');
    }
    return raw;
  }

  int _requiredInt(Map<String, dynamic> value, String key) {
    final raw = value[key];
    if (raw is! int) {
      throw StateError('IPC contract violation: "$key" must be an integer');
    }
    return raw;
  }

  bool _requiredBool(Map<String, dynamic> value, String key) {
    final raw = value[key];
    if (raw is! bool) {
      throw StateError('IPC contract violation: "$key" must be a boolean');
    }
    return raw;
  }

  List<dynamic> _requiredList(Map<String, dynamic> value, String key) {
    final raw = value[key];
    if (raw is! List<dynamic>) {
      throw StateError('IPC contract violation: "$key" must be an array');
    }
    return raw;
  }

  @override
  Future<String> ping() async {
    final response = await _request('ping', null);
    if (response['err'] != null) {
      throw StateError('engine error: ${response['err']}');
    }
    final value = response['result'];
    if (value is! String) {
      throw StateError('IPC contract violation: ping result must be a string');
    }
    return value;
  }
  @override
  Future<int> editorLoad(String text) async {
    final result = _expectResult(await _request('editor.load', text));
    return _requiredInt(result, 'handle');
  }

  @override
  Future<String> editorGetText(int handle) async {
    final result = _expectResult(await _request('editor.get_text', handle));
    return _requiredString(result, 'text');
  }
  Future<Map<String, dynamic>> _editorObjectOp(String method, int handle, {int? pos, int? len, String? text, String? query, String? lang}) async {
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
    return _requiredInt(
      await _editorObjectOp('editor.insert', handle, pos: pos, text: text),
      'size',
    );
  }

  @override
  Future<int> editorDelete(int handle, int pos, int len) async {
    return _requiredInt(
      await _editorObjectOp('editor.delete', handle, pos: pos, len: len),
      'size',
    );
  }
  @override
  Future<void> editorUndo(int handle) async { await _editorObjectOp('editor.undo', handle); }
  @override
  Future<void> editorRedo(int handle) async { await _editorObjectOp('editor.redo', handle); }
  @override
  Future<int> editorLineCount(int handle) async {
    return _requiredInt(
      await _editorObjectOp('editor.line_count', handle),
      'lines',
    );
  }

  @override
  Future<int> editorSize(int handle) async {
    return _requiredInt(
      await _editorObjectOp('editor.size', handle),
      'size',
    );
  }
  @override
  Future<List<EditorSearchResult>> editorSearch(int handle, String query) async {
    final value = _requiredList(
      await _editorObjectOp('editor.search', handle, query: query),
      'results',
    );
    return value.map((item) {
      if (item is! Map) {
        throw StateError(
          'IPC contract violation: editor.search item must be an object',
        );
      }
      final map = Map<String, dynamic>.from(item);
      return EditorSearchResult(
        line: _requiredInt(map, 'line'),
        col: _requiredInt(map, 'col'),
        text: _requiredString(map, 'text'),
      );
    }).toList();
  }
  @override
  Future<String> editorHighlight(int handle, String lang) async {
    return _requiredString(
      await _editorObjectOp('editor.highlight', handle, lang: lang),
      'html',
    );
  }
  @override
  Future<void> editorDestroy(int handle) async { await _editorObjectOp('editor.destroy', handle); }
  @override
  Future<void> editorApplyText(int handle, String text) async { await _editorObjectOp('editor.apply_text', handle, text: text); }
  @override
  Future<List<EditorDiffRegion>> editorDiffLines(int handle, String diskText) async {
    final raw = _requiredList(
      _expectResult(
        await _request('editor.diff_lines', {
          'handle': handle,
          'disk_text': diskText,
        }),
      ),
      'changes',
    );
    return raw.map((item) {
      if (item is! Map) {
        throw StateError(
          'IPC contract violation: editor.diff_lines item must be an object',
        );
      }
      final map = Map<String, dynamic>.from(item);
      return EditorDiffRegion(
        line: _requiredInt(map, 'line'),
        kind: _requiredString(map, 'kind'),
        count: _requiredInt(map, 'count'),
      );
    }).toList();
  }
  @override
  Future<List<WorkspaceSearchResult>> workspaceSearch(String root, String query, {int maxResults = 200}) async {
    final limit = maxResults.clamp(1, _maxSearchResults);
    final raw = _requiredList(
      _expectResult(
        await _request('workspace.search', {
          'root': root,
          'query': query,
          'max_results': limit,
        }),
      ),
      'results',
    );
    return raw.take(limit).map((item) {
      if (item is! Map) {
        throw StateError(
          'IPC contract violation: workspace.search item must be an object',
        );
      }
      final map = Map<String, dynamic>.from(item);
      return WorkspaceSearchResult(
        path: _requiredString(map, 'path'),
        line: _requiredInt(map, 'line'),
        col: _requiredInt(map, 'col'),
        text: _requiredString(map, 'text'),
      );
    }).toList();
  }
  @override
  Future<List<WorkspaceFile>> workspaceTree(String root, {int maxEntries = 50000}) async {
    final limit = maxEntries.clamp(1, _maxTreeEntries);
    final raw = _requiredList(
      _expectResult(
        await _request('workspace.tree', {
          'root': root,
          'max_entries': limit,
        }),
      ),
      'entries',
    );
    return raw.take(limit).map((item) {
      if (item is! Map) {
        throw StateError(
          'IPC contract violation: workspace.tree item must be an object',
        );
      }
      final map = Map<String, dynamic>.from(item);
      final kind = _requiredString(map, 'kind');
      if (kind != 'directory' && kind != 'file') {
        throw StateError(
          'IPC contract violation: unknown workspace.tree kind "$kind"',
        );
      }
      return WorkspaceFile(
        name: _requiredString(map, 'name'),
        path: _requiredString(map, 'path'),
        isDirectory: kind == 'directory',
        size: _requiredInt(map, 'size'),
      );
    }).toList();
  }
  @override
  Future<AgentToolResult> executeAgentTool(String toolId, Map<String, dynamic> input, {required String workspaceRoot, Duration? timeout}) async {
    late String encoded;
    try { encoded = jsonEncode(input); } catch (error) { return AgentToolResult(ok: false, output: '', error: 'Invalid tool input: $error'); }
    final response = await _request('agent.tool.execute', {'tool': toolId, 'input': encoded, 'workspace_root': workspaceRoot, 'timeout_ms': (timeout ?? _agentToolTimeout).inMilliseconds}, timeout: timeout ?? _agentToolTimeout);
    final result = _expectResult(response);
    return AgentToolResult(
      ok: _requiredBool(result, 'ok'),
      output: _requiredString(result, 'output'),
      error: _requiredString(result, 'error'),
    );
  }
  @override
  Future<void> watchWorkspace(String root) async {
    if (_watchedRoot == root) return;
    if (_watchedRoot != null) {
      await _request('watch.unsubscribe', null);
      _watchedRoot = null;
    }
    await _request('watch.subscribe', {'root': root});
    _watchedRoot = root;
  }

  @override
  Future<void> unwatchWorkspace() async {
    if (_connected) {
      await _request('watch.unsubscribe', null);
    }
    _watchedRoot = null;
  }
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _connected = false;
    _failPending(StateError('backend disposed'));
    final subscription = _socketSubscription;
    _socketSubscription = null;
    unawaited(subscription?.cancel() ?? Future<void>.value());
    final socket = _socket;
    _socket = null;
    socket?.destroy();
    _output.close();
    _fsChanges.close();
  }
}
