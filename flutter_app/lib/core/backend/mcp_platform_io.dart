import 'dart:io';

Future<String?> readWorkspaceMcpConfig(String workspaceRoot) async {
  final file = File(
    workspaceRoot +
        Platform.pathSeparator +
        '.hiide' +
        Platform.pathSeparator +
        'mcp.json',
  );
  if (!await file.exists()) return null;
  return file.readAsString();
}

String platformPathSeparator() => Platform.pathSeparator;

String? platformEnvironment(String name) => Platform.environment[name];
