import 'dart:async';

/// A single match inside an open editor buffer (computed by the Zig engine).
class EditorSearchResult {
  final int line;
  final int col;
  final String text;

  const EditorSearchResult({
    required this.line,
    required this.col,
    required this.text,
  });
}

/// A single match across the workspace (computed by the Zig engine grep).
class WorkspaceSearchResult {
  final String path;
  final int line;
  final int col;
  final String text;

  const WorkspaceSearchResult({
    required this.path,
    required this.line,
    required this.col,
    required this.text,
  });
}

/// One node of the workspace tree as enumerated by the Zig engine.
class WorkspaceFile {
  final String name;
  final String path; // workspace-relative, '/' separated
  final bool isDirectory;
  final int size; // bytes; 0 for directories

  const WorkspaceFile({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size = 0,
  });
}

/// One line-based change region between the editor buffer and the on-disk
/// reference (computed by the Zig engine's native Myers diff).
class EditorDiffRegion {
  /// 0-based buffer line where the region starts. For `deleted` this is the
  /// buffer line at the deletion boundary (== buffer line count when the
  /// deletion sits at the end of the file).
  final int line;

  /// One of `modified`, `added`, `deleted`.
  final String kind;

  /// Number of affected buffer lines (`deleted`: number of removed disk
  /// lines, since the buffer has no line to mark).
  final int count;

  const EditorDiffRegion({
    required this.line,
    required this.kind,
    required this.count,
  });
}

/// One filesystem change detected by the native workspace watcher.
class FsChange {
  /// Workspace-relative path ('/' separated) of the affected entry.
  final String path;
  final bool isDirectory;

  /// One of `created`, `modified`, `deleted`.
  final String kind;

  const FsChange({
    required this.path,
    required this.isDirectory,
    required this.kind,
  });
}

/// Result of one agent tool invocation executed by the Zig engine.
class AgentToolResult {
  /// True when the tool ran and produced [output]; false when the tool
  /// reported a failure (message in [error]).
  final bool ok;
  final String output;
  final String error;

  const AgentToolResult({
    required this.ok,
    required this.output,
    this.error = '',
  });
}

/// Contract for the Hiide backend.
///
/// The production implementation ([HiideBackendService]) talks to the native
/// Zig engine over a newline-delimited JSON-RPC socket (127.0.0.1:4879).
/// Every method below maps 1:1 to a `method` on the Zig IPC server, so all
/// performance-critical work (gap buffer, search, highlighting) happens in
/// Zig, never in Dart.
abstract class BackendService {
  /// Connection lifecycle announcements (e.g. "Connected to ...").
  Stream<String> get outputStream;

  bool get isConnected;

  Future<void> connect();

  Future<void> disconnect();

  Future<String> ping();

  /// Creates an engine editor buffer and loads [text] into it.
  /// Returns the opaque engine handle used by every other editor.* call.
  Future<int> editorLoad(String text);

  /// Returns the full buffer content as the engine currently holds it.
  Future<String> editorGetText(int handle);

  /// Inserts [text] at byte offset [pos]; returns the new buffer size.
  Future<int> editorInsert(int handle, int pos, String text);

  /// Deletes [len] bytes at byte offset [pos]; returns the new buffer size.
  Future<int> editorDelete(int handle, int pos, int len);

  Future<void> editorUndo(int handle);

  Future<void> editorRedo(int handle);

  Future<int> editorLineCount(int handle);

  Future<int> editorSize(int handle);

  /// Case-insensitive search inside the engine buffer.
  Future<List<EditorSearchResult>> editorSearch(int handle, String query);

  /// Syntax highlighting of the buffer rendered as HTML spans.
  Future<String> editorHighlight(int handle, String lang);

  /// Frees the engine buffer.
  Future<void> editorDestroy(int handle);

  /// Reconciles the engine buffer with [text] using a single minimal edit
  /// computed natively (common prefix/suffix in UTF-8 bytes). Replaces the
  /// Dart-side diff + code-unit→byte conversion for the keystroke path.
  Future<void> editorApplyText(int handle, String text);

  /// Line-based diff of the engine buffer against [diskText] (the on-disk
  /// reference), computed natively (Myers). Returns sparse change regions for
  /// the gutter: `{line (0-based buffer line), kind, count}`.
  Future<List<EditorDiffRegion>> editorDiffLines(int handle, String diskText);

  /// Recursive, case-insensitive grep across [root], executed in Zig.
  Future<List<WorkspaceSearchResult>> workspaceSearch(
    String root,
    String query, {
    int maxResults = 200,
  });

  /// Enumerates the workspace in a single native pass: flat, sorted
  /// directory-first entries with workspace-relative paths and file sizes.
  /// Junk directories (`.git`, `node_modules`, ...) are skipped.
  Future<List<WorkspaceFile>> workspaceTree(
    String root, {
    int maxEntries = 50000,
  });

  /// Executes an agent tool through the engine's tool framework. [input] is
  /// the JSON object passed to the tool (e.g. `{'path': 'src/main.zig'}` for
  /// `file.read`). Paths are workspace-relative; the engine sandbox rejects
  /// anything escaping [workspaceRoot]. Supported tool ids: `file.read`,
  /// `file.write`, `file.delete`, `file.mkdir`, `file.apply_diff`, `file.list`,
  /// `process.run`, `workspace.search`.
  Future<AgentToolResult> executeAgentTool(
    String toolId,
    Map<String, dynamic> input, {
    String? workspaceRoot,
    Duration? timeout,
  });

  /// Events pushed by the native file watcher (`watch.subscribe`): created /
  /// modified / deleted changes with workspace-relative paths. Broadcast.
  Stream<FsChange> get fsChangeStream;

  /// Starts watching [root] (the engine's inotify + snapshot-diff watcher) and
  /// pushes changes onto [fsChangeStream]. Idempotent per connection.
  Future<void> watchWorkspace(String root);

  /// Stops watching; the engine drops this connection's subscription.
  Future<void> unwatchWorkspace();

  void dispose();
}
