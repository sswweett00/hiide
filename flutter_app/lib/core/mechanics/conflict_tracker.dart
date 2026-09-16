class FileConflict {
  final String path;
  final DateTime detectedAt;
  final String diskContent;
  final String editorContent;

  const FileConflict({
    required this.path,
    required this.detectedAt,
    required this.diskContent,
    required this.editorContent,
  });
}

/// Tracks unsaved files changed externally. A conflict stays explicit until
/// the editor resolves it, preventing silent overwrite of newer disk content.
class ConflictTracker {
  final Map<String, FileConflict> _conflicts = <String, FileConflict>{};

  List<FileConflict> get conflicts =>
      List<FileConflict>.unmodifiable(_conflicts.values);

  bool has(String path) => _conflicts.containsKey(path);

  void detect({
    required String path,
    required String diskContent,
    required String editorContent,
  }) {
    if (diskContent == editorContent) {
      _conflicts.remove(path);
      return;
    }
    _conflicts[path] = FileConflict(
      path: path,
      detectedAt: DateTime.now(),
      diskContent: diskContent,
      editorContent: editorContent,
    );
  }

  void resolve(String path) => _conflicts.remove(path);
  void clear() => _conflicts.clear();
}
