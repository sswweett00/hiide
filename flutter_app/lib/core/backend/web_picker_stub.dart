import 'web_workspace.dart';

/// Non-web platforms have no browser picker — [pickWebDirectory] is a no-op.
Future<WebWorkspace?> pickWebDirectory() async => null;
