import 'dart:async';
import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import 'mcp_platform.dart';
import 'secret_store.dart';

class McpServerConfig {
  const McpServerConfig({
    required this.id,
    required this.transport,
    this.command,
    this.args = const [],
    this.workingDirectory,
    this.url,
    this.bearerTokenEnv,
    this.bearerTokenSecret,
    this.environment = const <String, String>{},
    this.enabled = true,
  });

  final String id;
  final String transport;
  final String? command;
  final List<String> args;
  final String? workingDirectory;
  final String? url;
  final String? bearerTokenEnv;
  final String? bearerTokenSecret;
  final Map<String, String> environment;
  final bool enabled;

  static McpServerConfig? fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim() ?? '';
    final transport =
        json['transport']?.toString().trim().toLowerCase() ?? '';
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(id)) return null;
    if (transport != 'stdio' && transport != 'streamable-http') return null;

    final enabled = json['enabled'] is bool ? json['enabled'] as bool : true;
    final command = json['command']?.toString().trim();
    final url = json['url']?.toString().trim();
    final bearerTokenEnv = json['bearerTokenEnv']?.toString().trim();
    final bearerTokenSecret = json['bearerTokenSecret']?.toString().trim();
    final workingDirectory =
        json['workingDirectory']?.toString().trim();

    final rawEnvironment = json['environment'];
    final environment = <String, String>{};
    if (rawEnvironment != null) {
      if (rawEnvironment is! Map) return null;
      if (rawEnvironment.length > 64) return null;
      for (final entry in rawEnvironment.entries) {
        final key = entry.key.toString().trim();
        final value = entry.value.toString();
        if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$').hasMatch(key) ||
            value.length > 512) {
          return null;
        }
        environment[key] = value;
      }
    }

    final rawArgs = json['args'];
    if (rawArgs != null && rawArgs is! List) return null;
    if (rawArgs is List && rawArgs.length > 64) return null;
    final args = rawArgs is List
        ? rawArgs.map((value) => value.toString()).toList()
        : const <String>[];

    if (transport == 'stdio' &&
        (command == null || command.isEmpty || command.length > 512)) {
      return null;
    }
    if (workingDirectory != null && workingDirectory.length > 1024) {
      return null;
    }

    if (transport == 'streamable-http') {
      final parsed = url == null ? null : Uri.tryParse(url);
      if (parsed == null ||
          parsed.host.isEmpty ||
          parsed.path.length > 2048 ||
          (parsed.scheme != 'http' && parsed.scheme != 'https')) {
        return null;
      }
      if (parsed.scheme == 'http' &&
          parsed.host != '127.0.0.1' &&
          parsed.host != 'localhost' &&
          parsed.host != '::1') {
        return null;
      }
    }

    if (bearerTokenEnv != null &&
        !RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$').hasMatch(bearerTokenEnv)) {
      return null;
    }
    if (bearerTokenSecret != null &&
        !RegExp(r'^[A-Za-z0-9_.-]{1,128}$').hasMatch(bearerTokenSecret)) {
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
      bearerTokenEnv:
          bearerTokenEnv == null || bearerTokenEnv.isEmpty
              ? null
              : bearerTokenEnv,
      bearerTokenSecret:
          bearerTokenSecret == null || bearerTokenSecret.isEmpty
              ? null
              : bearerTokenSecret,
      environment: Map.unmodifiable(environment),
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
  const McpToolCallResult({
    required this.success,
    required this.output,
  });

  final bool success;
  final String output;
}

class HiideMcpManager {
  HiideMcpManager({SecretStore? secretStore})
      : _secretStore = secretStore ?? FlutterSecretStore();

  final SecretStore _secretStore;
  final Map<String, McpClient> _clients = <String, McpClient>{};
  final Map<String, McpToolBinding> _bindings =
      <String, McpToolBinding>{};
  final Map<String, McpServerConfig> _configs =
      <String, McpServerConfig>{};
  String? _loadedWorkspaceRoot;
  bool _disposed = false;

  List<McpServerConfig> get servers =>
      List.unmodifiable(_configs.values.where((server) => server.enabled));
  List<McpToolBinding> get tools =>
      List.unmodifiable(_bindings.values);

  Future<void> loadWorkspace(
    String workspaceRoot, {
    Future<bool> Function(McpServerConfig config)? approvalHandler,
  }) async {
    _ensureNotDisposed();
    if (_loadedWorkspaceRoot == workspaceRoot) return;
    await closeAll();

    final raw = await readWorkspaceMcpConfig(workspaceRoot);
    if (raw == null || raw.trim().isEmpty) return;
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
    if (rawServers.length > 32) {
      throw const FormatException('MCP server limit is 32.');
    }
    for (final rawServer in rawServers) {
      if (rawServer is! Map) {
        throw const FormatException('MCP server entries must be objects.');
      }
      final config =
          McpServerConfig.fromJson(Map<String, dynamic>.from(rawServer));
      if (config == null) {
        throw const FormatException('Invalid MCP server configuration.');
      }
      if (!config.enabled) continue;
      if (!seen.add(config.id)) {
        throw FormatException('Duplicate MCP server id: ${config.id}');
      }
      configs.add(config);
    }

    try {
      for (final config in configs) {
        if (approvalHandler == null || !await approvalHandler(config)) {
          throw StateError(
            'User approval is required before starting MCP server "' +
                config.id + '".',
          );
        }
        await _connect(config, workspaceRoot);
      }
      _loadedWorkspaceRoot = workspaceRoot;
    } catch (_) {
      await closeAll();
      rethrow;
    }
  }

  List<Map<String, dynamic>> openAiToolDefinitions() {
    const maxTools = 512;
    return List.unmodifiable(
      _bindings.values.take(maxTools).map((binding) => binding.definition),
    );
  }

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
          arguments: Map<String, dynamic>.from(arguments),
        ),
        options: const RequestOptions(
          timeout: Duration(seconds: 120),
        ),
      );
      return McpToolCallResult(
        success: !result.isError,
        output: _boundOutput(
          _redactSensitiveOutput(jsonEncode(result.toJson())),
        ),
      );
    } catch (error) {
      return McpToolCallResult(
        success: false,
        output: _boundOutput(
          _redactSensitiveOutput(
            'MCP tool call failed: ' + error.toString(),
          ),
        ),
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
          environment: _stdioEnvironment(config),
          includeParentEnvironment: false,
          workingDirectory: _stdioWorkingDirectory(
            config.workingDirectory,
            workspaceRoot,
          ),
          restartOnUnexpectedExit: true,
          maxIncomingMessageBytes: 2 * 1024 * 1024,
        ),
      );
    } else {
      final headers = <String, dynamic>{};
      final bearer = await _resolveBearerToken(config);
      if (bearer != null) {
        headers['Authorization'] = 'Bearer ' + bearer;
      }
      transport = headers.isEmpty
          ? StreamableHttpClientTransport(Uri.parse(config.url!))
          : StreamableHttpClientTransport(
              Uri.parse(config.url!),
              opts: StreamableHttpClientTransportOptions(
                requestInit: <String, dynamic>{'headers': headers},
              ),
            );
    }

    final client = McpClient(
      const Implementation(name: 'hiide', version: '1.0.0'),
      options: const McpClientOptions(protocol: McpProtocol.stable),
    );

    try {
      await client.connect(transport);
      final toolResult = await client.listTools();
      if (toolResult.tools.length > 512) {
        throw StateError(
          'MCP server "' + config.id + '" advertises more than 512 tools.',
        );
      }
      final pending = <McpToolBinding>[];
      for (final tool in toolResult.tools) {
        final name = tool.name.trim();
        if (name.isEmpty || name.length > 128) {
          throw StateError(
            'MCP server "' + config.id + '" returned an invalid tool name.',
          );
        }
        final fullName = _uniqueToolName(config.id, name);
        pending.add(
          McpToolBinding(
            fullName: fullName,
            serverId: config.id,
            toolName: name,
            definition: <String, dynamic>{
              'type': 'function',
              'function': <String, dynamic>{
                'name': fullName,
                'description':
                    '[MCP ' + config.id + '] ' +
                    (tool.description ?? name),
                'parameters': tool.inputSchema.toJson(),
              },
            },
          ),
        );
      }
      for (final binding in pending) {
        _bindings[binding.fullName] = binding;
      }
      _clients[config.id] = client;
      _configs[config.id] = config;
    } catch (_) {
      await client.close();
      rethrow;
    }
  }

  String _stdioWorkingDirectory(
    String? configured,
    String workspaceRoot,
  ) {
    if (configured == null || configured.isEmpty) return workspaceRoot;
    final normalized = configured.replaceAll('\\', '/');
    if (normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:/').hasMatch(normalized) ||
        normalized.split('/').contains('..')) {
      throw StateError(
        'MCP stdio workingDirectory must stay inside the workspace.',
      );
    }
    return workspaceRoot + '/' + normalized;
  }

  Map<String, String> _stdioEnvironment(McpServerConfig config) {
    const unsafeEnvironmentKeys = <String>{
      'LD_PRELOAD',
      'LD_LIBRARY_PATH',
      'DYLD_INSERT_LIBRARIES',
      'DYLD_LIBRARY_PATH',
      'NODE_OPTIONS',
      'NODE_PATH',
      'PYTHONPATH',
      'PYTHONHOME',
      'RUBYOPT',
      'PERL5OPT',
    };
    const safeKeys = <String>{
      'PATH',
      'HOME',
      'USER',
      'LOGNAME',
      'SHELL',
      'TMPDIR',
      'TEMP',
      'TMP',
      'LANG',
      'LC_ALL',
      'LC_CTYPE',
      'XDG_CONFIG_HOME',
      'XDG_DATA_HOME',
      'XDG_CACHE_HOME',
      'SYSTEMROOT',
      'COMSPEC',
      'USERPROFILE',
      'APPDATA',
      'LOCALAPPDATA',
      'PATHEXT',
    };
    final environment = <String, String>{};
    for (final key in safeKeys) {
      final value = platformEnvironment(key);
      if (value != null && value.isNotEmpty) {
        environment[key] = value;
      }
    }
    for (final entry in config.environment.entries) {
      if (unsafeEnvironmentKeys.contains(entry.key.toUpperCase())) {
        throw StateError(
          'MCP environment variable is not permitted: ' + entry.key,
        );
      }
      final raw = entry.value;
      if (raw.startsWith(r'$env:')) {
        final envName = raw.substring(5).trim();
        if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$').hasMatch(envName)) {
          throw FormatException(
            'Invalid environment reference for ' + entry.key,
          );
        }
        final value = platformEnvironment(envName);
        if (value == null) {
          throw StateError(
            'Configured MCP environment variable is unavailable: ' +
                envName,
          );
        }
        environment[entry.key] = value;
      } else {
        environment[entry.key] = raw;
      }
    }
    return environment;
  }

  Future<String?> _resolveBearerToken(McpServerConfig config) async {
    if (config.bearerTokenSecret != null) {
      final secretName = config.bearerTokenSecret!;
      final values = await _secretStore.readAll();
      final token = values['hiide.mcp.bearer.' + secretName]?.trim();
      if (token != null && token.isNotEmpty) return token;
      throw StateError(
        'Configured MCP bearer secret is unavailable: ' + secretName,
      );
    }
    if (config.bearerTokenEnv != null) {
      final envName = config.bearerTokenEnv!;
      final token = platformEnvironment(envName)?.trim();
      if (token != null && token.isNotEmpty) return token;
      throw StateError(
        'Configured MCP bearer environment variable is unavailable: ' +
            envName,
      );
    }
    return null;
  }

  String _boundOutput(String value) {
    const max = 12000;
    if (value.length <= max) return value;
    return value.substring(0, max) +
        '\n[MCP output truncated by Hiide after 12000 characters]';
  }

  String _redactSensitiveOutput(String output) {
    var value = output;
    final patterns = <RegExp>[
      RegExp(
        r'''["']?(api[_-]?key|apikey|password|secret|access[_-]?token|refresh[_-]?token)["']?\s*[:=]\s*["']?[^\s,"'}]+''',
        caseSensitive: false,
      ),
      RegExp(
        r'bearer\s+[A-Za-z0-9._~+\-/]+=*',
        caseSensitive: false,
      ),
      RegExp(
        r'-----BEGIN [A-Z ]+ PRIVATE KEY-----[\s\S]*?-----END [A-Z ]+ PRIVATE KEY-----',
        caseSensitive: false,
      ),
    ];
    for (final pattern in patterns) {
      value = value.replaceAllMapped(pattern, (_) => '[REDACTED]');
    }
    return value;
  }

  String _uniqueToolName(String serverId, String toolName) {
    final base = 'mcp_' + _sanitize(serverId) + '_' + _sanitize(toolName);
    final bounded = base.length <= 64 ? base : base.substring(0, 64);
    if (!_bindings.containsKey(bounded)) return bounded;
    for (var suffix = 1; suffix < 1000; suffix++) {
      final suffixText = '_' + suffix.toString();
      final prefixLength = 64 - suffixText.length;
      final candidate =
          bounded.substring(0, prefixLength) + suffixText;
      if (!_bindings.containsKey(candidate)) return candidate;
    }
    throw StateError('Could not allocate a unique MCP tool name.');
  }

  String _sanitize(String value) {
    final sanitized =
        value.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return sanitized.isEmpty ? 'tool' : sanitized;
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('MCP manager is disposed.');
  }
}