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
      final hello = await _request('hello', null, timeout: _requestTimeout);
      _emitOutput('Connected to Hiide Zig engine (${hello['service'] ?? 'unknown'} v${hello['version'] ?? 'unknown'}) on $host:$port');
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
      final rawParams = message['params'];
      if (rawParams is! Map) return;
      final changes = rawParams['changes'];
      if (changes is! List) return;
      for (final raw in changes) {
        if (raw is! Map) continue;
        final map = Map<String, dynamic>.from(raw);
        final path = map['path']?.toString() ?? '';
        if (path.isEmpty || _fsChanges.isClosed) continue;
        _fsChanges.add(FsChange(path: path, isDirectory: map['is_dir'] == true, kind: map['kind']?.toString() ?? 'modified'));
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
    if (response['err'] != null) throw StateError('engine error: ${response['err']}');
    final value = response['result'];
    if (value is Map) return Map<String, dynamic>.from(value);
    return const <String, dynamic>{};
  }

  @override
  Future<String> ping() async => (await _request('ping', null))['result']?.toString() ?? '';
  @override
  Future<int> editorLoad(String text) async {
    final result = _expectResult(await _request('editor.load', text));
    final handle = result['handle'];
    if (handle is! int) throw StateError('invalid editor handle');
    return handle;
  }
  @override
  Future<String> editorGetText(int handle) async => _expectResult(await _request('editor.get_text', handle))['text']?.toString() ?? '';
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
  Future<int> editorInsert(int handle, int pos, String text) async => (_editorObjectOp('editor.insert', handle, pos: pos, text: text).then((r) => r['size'] is int ? r['size'] as int : 0));
  @override
  Future<int> editorDelete(int handle, int pos, int len) async => (_editorObjectOp('editor.delete', handle, pos: pos, len: len).then((r) => r['size'] is int ? r['size'] as int : 0));
  @override
  Future<void> editorUndo(int handle) async { await _editorObjectOp('editor.undo', handle); }
  @override
  Future<void> editorRedo(int handle) async { await _editorObjectOp('editor.redo', handle); }
  @override
  Future<int> editorLineCount(int handle) async => (_editorObjectOp('editor.line_count', handle).then((r) => r['lines'] is int ? r['lines'] as int : 0));
  @override
  Future<int> editorSize(int handle) async => (_editorObjectOp('editor.size', handle).then((r) => r['size'] is int ? r['size'] as int : 0));
  @override
  Future<List<EditorSearchResult>> editorSearch(int handle, String query) async {
    final value = await _editorObjectOp('editor.search', handle, query: query).then((r) => r['results']);
    if (value is! List) return const [];
    return value.whereType<Map>().map((item) {
      final map = Map<String, dynamic>.from(item);
      return EditorSearchResult(line: map['line'] is int ? map['line'] as int : 0, col: map['col'] is int ? map['col'] as int : 0, text: map['text']?.toString() ?? '');
    }).toList();
  }
  @override
  Future<String> editorHighlight(int handle, String lang) async => _editorObjectOp('editor.highlight', handle, lang: lang).then((r) => r['html']?.toString() ?? '');
  @override
  Future<void> editorDestroy(int handle) async { await _editorObjectOp('editor.destroy', handle); }
  @override
  Future<void> editorApplyText(int handle, String text) async { await _editorObjectOp('editor.apply_text', handle, text: text); }
  @override
  Future<List<EditorDiffRegion>> editorDiffLines(int handle, String diskText) async {
    final raw = _expectResult(await _request('editor.diff_lines', {'handle': handle, 'disk_text': diskText}))['changes'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((item) {
      final map = Map<String, dynamic>.from(item);
      return EditorDiffRegion(line: map['line'] is int ? map['line'] as int : 0, kind: map['kind']?.toString() ?? 'modified', count: map['count'] is int ? map['count'] as int : 1);
    }).toList();
  }
  @override
  Future<List<WorkspaceSearchResult>> workspaceSearch(String root, String query, {int maxResults = 200}) async {
    final limit = maxResults.clamp(1, _maxSearchResults);
    final raw = _expectResult(await _request('workspace.search', {'root': root, 'query': query, 'max_results': limit}))['results'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().take(limit).map((item) {
      final map = Map<String, dynamic>.from(item);
      return WorkspaceSearchResult(path: map['path']?.toString() ?? '', line: map['line'] is int ? map['line'] as int : 0, col: map['col'] is int ? map['col'] as int : 0, text: map['text']?.toString() ?? '');
    }).toList();
  }
  @override
  Future<List<WorkspaceFile>> workspaceTree(String root, {int maxEntries = 50000}) async {
    final limit = maxEntries.clamp(1, _maxTreeEntries);
    final raw = _expectResult(await _request('workspace.tree', {'root': root, 'max_entries': limit}))['entries'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().take(limit).map((item) {
      final map = Map<String, dynamic>.from(item);
      return WorkspaceFile(name: map['name']?.toString() ?? '', path: map['path']?.toString() ?? '', isDirectory: map['kind']?.toString() == 'directory', size: map['size'] is int ? map['size'] as int : 0);
    }).toList();
  }
  @override
  Future<AgentToolResult> executeAgentTool(String toolId, Map<String, dynamic> input, {String? workspaceRoot, Duration? timeout}) async {
    late String encoded;
    try { encoded = jsonEncode(input); } catch (error) { return AgentToolResult(ok: false, output: '', error: 'Invalid tool input: $error'); }
    final response = await _request('agent.tool.execute', {'tool': toolId, 'input': encoded, if (workspaceRoot != null) 'workspace_root': workspaceRoot, 'timeout_ms': (timeout ?? _agentToolTimeout).inMilliseconds}, timeout: timeout ?? _agentToolTimeout);
    final value = response['result'];
    final result = value is Map ? Map<String, dynamic>.from(value) : const <String, dynamic>{};
    return AgentToolResult(ok: result['ok'] == true, output: result['output']?.toString() ?? '', error: result['error']?.toString() ?? '');
  }
  @override
  Future<void> watchWorkspace(String root) async { await _request('watch.subscribe', {'root': root}); _watchedRoot = root; }
  @override
  Future<void> unwatchWorkspace() async { _watchedRoot = null; if (_connected) await _request('watch.unsubscribe', null); }
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
