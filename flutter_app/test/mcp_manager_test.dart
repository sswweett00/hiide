import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiide_flutter/core/backend/mcp_manager.dart';

void main() {
  test('accepts a valid stdio MCP server configuration', () {
    final config = McpServerConfig.fromJson({
      'id': 'filesystem',
      'transport': 'stdio',
      'command': 'node',
      'args': ['server.js'],
      'workingDirectory': '/workspace/project',
    });

    expect(config, isNotNull);
    expect(config!.id, 'filesystem');
    expect(config.transport, 'stdio');
    expect(config.command, 'node');
    expect(config.args, ['server.js']);
  });

  test('accepts a valid Streamable HTTP MCP server configuration', () {
    final config = McpServerConfig.fromJson({
      'id': 'remote-tools',
      'transport': 'streamable-http',
      'url': 'https://mcp.example.com/mcp',
      'bearerTokenEnv': 'HIIDE_MCP_TOKEN',
    });

    expect(config, isNotNull);
    expect(config!.transport, 'streamable-http');
    expect(config.url, 'https://mcp.example.com/mcp');
    expect(config.bearerTokenEnv, 'HIIDE_MCP_TOKEN');
  });

  test('rejects unsafe or malformed MCP server configurations', () {
    expect(
      McpServerConfig.fromJson({
        'id': 'bad server',
        'transport': 'stdio',
        'command': 'node',
      }),
      isNull,
    );

    expect(
      McpServerConfig.fromJson({
        'id': 'remote',
        'transport': 'streamable-http',
        'url': 'file:///tmp/tool',
      }),
      isNull,
    );

    expect(
      McpServerConfig.fromJson({
        'id': 'missing-command',
        'transport': 'stdio',
      }),
      isNull,
    );
  });

  test('accepts explicit environment references and rejects unsafe names', () {
    final config = McpServerConfig.fromJson({
      'id': 'env-test',
      'transport': 'stdio',
      'command': 'node',
      'environment': {
        'NODE_ENV': 'production',
        'API_TOKEN': r'\$env:HIIDE_MCP_TOKEN',
      },
    });

    expect(config, isNotNull);
    expect(config!.environment['NODE_ENV'], 'production');
    expect(config.environment['API_TOKEN'], r'\$env:HIIDE_MCP_TOKEN');

    expect(
      McpServerConfig.fromJson({
        'id': 'bad-env',
        'transport': 'stdio',
        'command': 'node',
        'environment': {'BAD-NAME': 'x'},
      }),
      isNull,
    );
  });

  test('rejects plaintext remote HTTP except loopback', () {
    expect(
      McpServerConfig.fromJson({
        'id': 'remote',
        'transport': 'streamable-http',
        'url': 'http://mcp.example.com/mcp',
      }),
      isNull,
    );
    expect(
      McpServerConfig.fromJson({
        'id': 'local',
        'transport': 'streamable-http',
        'url': 'http://127.0.0.1:8080/mcp',
      }),
      isNotNull,
    );
    expect(
      McpServerConfig.fromJson({
        'id': 'secure',
        'transport': 'streamable-http',
        'url': 'https://mcp.example.com/mcp',
      }),
      isNotNull,
    );
  });

  test('rejects MCP stdio working directories that escape the workspace', () async {
    final workspace = await Directory.systemTemp.createTemp('hiide_mcp_path_test_');
    addTearDown(() => workspace.delete(recursive: true));

    final configDir = Directory('${workspace.path}/.hiide')..createSync();
    await File('${configDir.path}/mcp.json').writeAsString(
      jsonEncode({
        'servers': [
          {
            'id': 'unsafe',
            'transport': 'stdio',
            'command': 'node',
            'args': ['server.js'],
            'workingDirectory': '../outside',
          },
        ],
      }),
    );

    final manager = HiideMcpManager();
    await expectLater(
      manager.loadWorkspace(
        workspace.path,
        approvalHandler: (_) async => true,
      ),
      throwsA(isA<StateError>()),
    );
    await manager.closeAll();
  });

  test('MCP result wrapper preserves success state', () {
    const success = McpToolCallResult(
      success: true,
      output: 'ok',
    );
    const failure = McpToolCallResult(
      success: false,
      output: 'failed',
    );

    expect(success.success, isTrue);
    expect(failure.success, isFalse);
  });
}
