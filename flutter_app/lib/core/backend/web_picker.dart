import 'web_picker_stub.dart' if (dart.library.js_interop) 'web_picker_web.dart'
    as impl;
import 'web_workspace.dart';

export 'web_workspace.dart';

/// Opens the browser's native directory picker (web only) and returns the
/// chosen folder as a real, readable in-memory [WebWorkspace], registered as
/// the active web workspace. Returns null when the user cancels, the picker
/// is unavailable, or on non-web platforms.
Future<WebWorkspace?> pickWebDirectory() async {
  final ws = await impl.pickWebDirectory();
  return ws == null ? null : adoptWebWorkspace(ws);
}
