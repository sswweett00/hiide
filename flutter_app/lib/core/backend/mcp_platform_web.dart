Future<String?> readWorkspaceMcpConfig(String workspaceRoot) async {
  // Browser builds do not have direct access to arbitrary local workspace
  // files. Remote MCP configuration can be supplied by a future settings/
  // workspace provider without introducing dart:io into the web binary.
  return null;
}

String platformPathSeparator() => '/';

String? platformEnvironment(String name) => null;
