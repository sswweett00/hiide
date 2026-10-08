import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

class McpServerConfig {
  const McpServerConfig({
    required this.id,
    required this.transport,
    this.command,
    this.args = const [],
    this.workingDirectory,
    this.url,
    this.enabled = true,
  });

  final String id;
  final String transport;
  final String? command;
  final List<String> args;
  final String? workingDirectory;
  final String? url;
  final bool enabled;

  static McpServerConfig? fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim() ?? '';
    final transport = json['transport']?.toString().trim().toLowerCase() ?? '';
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,64}.hasMatch(id)) return null;
    if (transport != 'stdio' && transport != 'streamable-http') return null;

    final enabled = json['enabled'] is bool ? json['enabled'] as bool : true;
    final command = json['command']?.toString().trim();
    final url = json['url']?.toString().trim();
    final args = json['args'] is List
        ? (json['args'] as List).map((v) => v.toString()).take(64).toList()
        : const <String>[];
    final workingDirectory = json['workingDirectory']?.toString().trim();

    if (transport == 'stdio' && (command == null || command.isEmpty)) {
      return null;
    }
    if (transport == 'streamable-http' &&
        (url == null || Uri.tryParse(url) == null)) {
      return null;
    }

    return McpServerConfig(
      id: id,
      transport: transport,
      command: command,
      args: List.unmodifiable(args),
      workingDirectory:
          workingDirectory == null || workingDirectory.isEmpty
              ? null
              : workingDirectory,
      url: url,
      enabled: enabled,
    );
  }
}

class McpToolBinding {
  const McpToolBinding({
    required this.fullName,
    required this.serverId,
    required this.toolName,
    required this.definition,
  });

  final String fullName;
  final String serverId;
  final String toolName;
  final Map<String, dynamic> definition;
}

class McpToolCallResult {
  const McpToolCallResult({required this.success, required this.output});

  final bool success;
  final String output;
}

class HiideMcpManager {
  HiideMcpManager();

  final Map<String, McpClient> _clients = <String, McpClient>{};
  final Map<String, McpToolBinding> _bindings = <String, McpToolBinding>{};
  final Map<String, McpServerConfig> _configs = <String, McpServerConfig>{};
  bool _disposed = false;
  String? _loadedWorkspaceRoot;

  List<McpServerConfig> get servers =>
      List.unmodifiable(_configs.values.where((server) => server.enabled));

  List<McpToolBinding> get tools => List.unmodifiable(_bindings.values);

  Future<void> loadWorkspace(String workspaceRoot) async {
    _ensureNotDisposed();
    if (_loadedWorkspaceRoot == workspaceRoot) return;
    await closeAll();
    _loadedWorkspaceRoot = workspaceRoot;

    final file = File(
      workspaceRoot +
          Platform.pathSeparator +
          '.hiide' +
          Platform.pathSeparator +
          'mcp.json',
    );
    if (!await file.exists()) return;

    final raw = await file.readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('.hiide/mcp.json must contain an object.');
    }

    final rawServers = decoded['servers'];
    if (rawServers is! List) {
      throw const FormatException(
        '.hiide/mcp.json must contain a "servers" array.',
      );
    }

    final configs = <McpServerConfig>[];
    final seen = <String>{};
    for (final rawServer in rawServers.take(32)) {
      if (rawServer is! Map) continue;
      final config =
          McpServerConfig.fromJson(Map<String, dynamic>.from(rawServer));
      if (config == null || !config.enabled || !seen.add(config.id)) continue;
      configs.add(config);
    }

    for (final config in configs) {
      await _connect(config, workspaceRoot);
    }
  }

  List<Map<String, dynamic>> openAiToolDefinitions() =>
      List.unmodifiable(_bindings.values.map((binding) => binding.definition));

  Future<McpToolCallResult> call(
    String fullName,
    Map<String, dynamic> arguments,
  ) async {
    _ensureNotDisposed();
    final binding = _bindings[fullName];
    if (binding == null) {
      return const McpToolCallResult(
        success: false,
        output: 'MCP tool not found: unknown binding.',
      );
    }

    final client = _clients[binding.serverId];
    if (client == null) {
      return McpToolCallResult(
        success: false,
        output: 'MCP server "' + binding.serverId + '" is not connected.',
      );
    }

    try {
      final result = await client.callTool(
        CallToolRequest(
          name: binding.toolName,
          arguments: arguments,
        ),
        options: const RequestOptions(timeout: Duration(seconds: 120)),
      );
      return McpToolCallResult(
        success: !result.isError,
        output: jsonEncode(result.toJson()),
      );
    } catch (error) {
      return McpToolCallResult(
        success: false,
        output: 'MCP tool call failed: ' + error.toString(),
      );
    }
  }

  Future<void> closeAll() async {
    final clients = List<McpClient>.from(_clients.values);
    _clients.clear();
    _bindings.clear();
    _configs.clear();
    _loadedWorkspaceRoot = null;

    for (final client in clients) {
      try {
        await client.close();
      } catch (_) {}
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(closeAll());
  }

  Future<void> _connect(
    McpServerConfig config,
    String workspaceRoot,
  ) async {
    late final Transport transport;
    if (config.transport == 'stdio') {
      transport = StdioClientTransport(
        StdioServerParameters(
          command: config.command!,
          args: config.args,
          workingDirectory: config.workingDirectory ?? workspaceRoot,
        ),
      );
    } else {
      transport = StreamableHttpClientTransport(Uri.parse(config.url!));
    }

    final client = McpClient(
      const Implementation(name: 'hiide', version: '1.0.0'),
      options: const McpClientOptions(protocol: McpProtocol.stable),
    );

    try {
      await client.connect(transport);
      final toolResult = await client.listTools();

      for (final tool in toolResult.tools) {
        final fullName = _uniqueToolName(config.id, tool.name);
        _bindings[fullName] = McpToolBinding(
          fullName: fullName,
          serverId: config.id,
          toolName: tool.name,
          definition: <String, dynamic>{
            'type': 'function',
            'function': <String, dynamic>{
              'name': fullName,
              'description':
                  '[MCP ' + config.id + '] ' +
                  (tool.description ?? tool.name),
              'parameters': tool.inputSchema.toJson(),
            },
          },
        );
      }
      _clients[config.id] = client;
      _configs[config.id] = config;
    } catch (_) {
      await client.close();
      rethrow;
    }
  }

  String _uniqueToolName(String serverId, String toolName) {
    final base = 'mcp_' + _sanitize(serverId) + '_' + _sanitize(toolName);
    final bounded = base.length <= 64 ? base : base.substring(0, 64);
    if (!_bindings.containsKey(bounded)) return bounded;

    var suffix = 1;
    var candidate = bounded;
    while (_bindings.containsKey(candidate) && suffix < 1000) {
      final suffixText = '_' + suffix.toString();
      final prefixLength = 64 - suffixText.length;
      candidate = bounded.substring(0, prefixLength) + suffixText;
      suffix++;
    }
    return candidate;
  }

  String _sanitize(String value) {
    final sanitized = value.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return sanitized.isEmpty ? 'tool' : sanitized;
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('MCP manager is disposed.');
  }
}).hasMatch(id)) return null;
    if (transport != 'stdio' && transport != 'streamable-http') return null;

    final enabled = json['enabled'] is bool ? json['enabled'] as bool : true;
    final command = json['command']?.toString().trim();
    final url = json['url']?.toString().trim();
    final args = json['args'] is List
        ? (json['args'] as List).map((v) => v.toString()).take(64).toList()
        : const <String>[];
    final workingDirectory = json['workingDirectory']?.toString().trim();

    if (transport == 'stdio' && (command == null || command.isEmpty)) {
      return null;
    }
    if (transport == 'streamable-http' &&
        (url == null || Uri.tryParse(url) == null)) {
      return null;
    }

    return McpServerConfig(
      id: id,
      transport: transport,
      command: command,
      args: List.unmodifiable(args),
      workingDirectory:
          workingDirectory == null || workingDirectory.isEmpty
              ? null
              : workingDirectory,
      url: url,
      enabled: enabled,
    );
  }
}

class McpToolBinding {
  const McpToolBinding({
    required this.fullName,
    required this.serverId,
    required this.toolName,
    required this.definition,
  });

  final String fullName;
  final String serverId;
  final String toolName;
  final Map<String, dynamic> definition;
}

class McpToolCallResult {
  const McpToolCallResult({required this.success, required this.output});

  final bool success;
  final String output;
}

class HiideMcpManager {
  HiideMcpManager();

  final Map<String, McpClient> _clients = <String, McpClient>{};
  final Map<String, McpToolBinding> _bindings = <String, McpToolBinding>{};
  final Map<String, McpServerConfig> _configs = <String, McpServerConfig>{};
  bool _disposed = false;

  List<McpServerConfig> get servers =>
      List.unmodifiable(_configs.values.where((server) => server.enabled));

  List<McpToolBinding> get tools => List.unmodifiable(_bindings.values);

  Future<void> loadWorkspace(String workspaceRoot) async {
    _ensureNotDisposed();
    await closeAll();

    final file = File(
      workspaceRoot +
          Platform.pathSeparator +
          '.hiide' +
          Platform.pathSeparator +
          'mcp.json',
    );
    if (!await file.exists()) return;

    final raw = await file.readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('.hiide/mcp.json must contain an object.');
    }

    final rawServers = decoded['servers'];
    if (rawServers is! List) {
      throw const FormatException(
        '.hiide/mcp.json must contain a "servers" array.',
      );
    }

    final configs = <McpServerConfig>[];
    final seen = <String>{};
    for (final rawServer in rawServers.take(32)) {
      if (rawServer is! Map) continue;
      final config =
          McpServerConfig.fromJson(Map<String, dynamic>.from(rawServer));
      if (config == null || !config.enabled || !seen.add(config.id)) continue;
      configs.add(config);
    }

    for (final config in configs) {
      await _connect(config, workspaceRoot);
    }
  }

  List<Map<String, dynamic>> openAiToolDefinitions() =>
      List.unmodifiable(_bindings.values.map((binding) => binding.definition));

  Future<McpToolCallResult> call(
    String fullName,
    Map<String, dynamic> arguments,
  ) async {
    _ensureNotDisposed();
    final binding = _bindings[fullName];
    if (binding == null) {
      return const McpToolCallResult(
        success: false,
        output: 'MCP tool not found: unknown binding.',
      );
    }

    final client = _clients[binding.serverId];
    if (client == null) {
      return McpToolCallResult(
        success: false,
        output: 'MCP server "' + binding.serverId + '" is not connected.',
      );
    }

    try {
      final result = await client.callTool(
        CallToolRequest(
          name: binding.toolName,
          arguments: arguments,
        ),
        options: const RequestOptions(timeout: Duration(seconds: 120)),
      );
      return McpToolCallResult(
        success: !result.isError,
        output: jsonEncode(result.toJson()),
      );
    } catch (error) {
      return McpToolCallResult(
        success: false,
        output: 'MCP tool call failed: ' + error.toString(),
      );
    }
  }

  Future<void> closeAll() async {
    final clients = List<McpClient>.from(_clients.values);
    _clients.clear();
    _bindings.clear();
    _configs.clear();

    for (final client in clients) {
      try {
        await client.close();
      } catch (_) {}
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(closeAll());
  }

  Future<void> _connect(
    McpServerConfig config,
    String workspaceRoot,
  ) async {
    late final Transport transport;
    if (config.transport == 'stdio') {
      transport = StdioClientTransport(
        StdioServerParameters(
          command: config.command!,
          args: config.args,
          workingDirectory: config.workingDirectory ?? workspaceRoot,
        ),
      );
    } else {
      transport = StreamableHttpClientTransport(Uri.parse(config.url!));
    }

    final client = McpClient(
      const Implementation(name: 'hiide', version: '1.0.0'),
      options: const McpClientOptions(protocol: McpProtocol.stable),
    );

    try {
      await client.connect(transport);
      final toolResult = await client.listTools();

      for (final tool in toolResult.tools) {
        final fullName = _uniqueToolName(config.id, tool.name);
        _bindings[fullName] = McpToolBinding(
          fullName: fullName,
          serverId: config.id,
          toolName: tool.name,
          definition: <String, dynamic>{
            'type': 'function',
            'function': <String, dynamic>{
              'name': fullName,
              'description':
                  '[MCP ' + config.id + '] ' +
                  (tool.description ?? tool.name),
              'parameters': tool.inputSchema.toJson(),
            },
          },
        );
      }
      _clients[config.id] = client;
      _configs[config.id] = config;
    } catch (_) {
      await client.close();
      rethrow;
    }
  }

  String _uniqueToolName(String serverId, String toolName) {
    final base = 'mcp_' + _sanitize(serverId) + '_' + _sanitize(toolName);
    final bounded = base.length <= 64 ? base : base.substring(0, 64);
    if (!_bindings.containsKey(bounded)) return bounded;

    var suffix = 1;
    var candidate = bounded;
    while (_bindings.containsKey(candidate) && suffix < 1000) {
      final suffixText = '_' + suffix.toString();
      final prefixLength = 64 - suffixText.length;
      candidate = bounded.substring(0, prefixLength) + suffixText;
      suffix++;
    }
    return candidate;
  }

  String _sanitize(String value) {
    final sanitized = value.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return sanitized.isEmpty ? 'tool' : sanitized;
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('MCP manager is disposed.');
  }
}