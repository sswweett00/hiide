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
