import 'package:flutter/material.dart';
import '../../shared/models/file_tree_item.dart';

/// A folder picked in the browser (web only). Browsers cannot read arbitrary
/// disk paths, but a directory chosen through the webkit directory input is
/// fully accessible for the page lifetime: every file is real and readable.
/// Edits land in [overlay] so Save / Apply-Diff behave within the session
/// (the browser cannot write back to the disk without user-per-file grants).
class WebWorkspace {
  WebWorkspace({required this.name, required this.files});

  /// Display name of the picked folder (first path segment).
  final String name;

  /// Folder-relative entries (e.g. `lib/main.dart`), sorted by path.
  final List<WebFileEntry> files;

  /// In-memory writes (relative path → content) layered over the picked
  /// files; [readText] prefers them so the editor reflects saves.
  final Map<String, String> overlay = {};

  /// Virtual root the rest of the IDE treats as the workspace path.
  String get rootPath => '/web/$name';

  /// Maps an absolute virtual path back to a folder-relative one, or null
  /// when it does not belong to this workspace.
  String? relOf(String absPath) {
    if (absPath == rootPath) return null;
    if (absPath.startsWith('$rootPath/')) {
      return absPath.substring(rootPath.length + 1);
    }
    return null;
  }

  Future<String> readText(String rel) async {
    final over = overlay[rel];
    if (over != null) return over;
    for (final f in files) {
      if (f.path == rel) return f.read();
    }
    throw Exception('File not found in web workspace: $rel');
  }

  void writeText(String rel, String content) => overlay[rel] = content;

  /// Same contract as `WorkspaceService.findWelcomeFile`, resolved against
  /// the picked files so a freshly opened web folder lands on its README.
  Future<({String path, String content})?> findWelcomeFile() async {
    for (final name in const [
      'README.md',
      'Readme.md',
      'readme.md',
      'README.txt',
    ]) {
      if (!files.any((f) => f.path == name)) continue;
      try {
        return (path: '$rootPath/$name', content: await readText(name));
      } catch (_) {}
    }
    return null;
  }
}

/// One picked file: folder-relative [path], display [name] and a lazy reader.
/// The underlying browser `File` object stays valid for the page lifetime, so
/// content is fetched on demand (and cached by the editor session).
class WebFileEntry {
  WebFileEntry({
    required this.path,
    required this.name,
    required this.read,
    this.size = 0,
  });

  final String path;
  final String name;
  final int size;
  final Future<String> Function() read;
}

/// Session store for the currently picked web folder. A global like
/// `settingsService` — the web IDE has exactly one active workspace.
class WebWorkspaceStore {
  WebWorkspace? workspace;
}

final webWorkspaceStore = WebWorkspaceStore();

/// Registers [ws] as the active web workspace (there is exactly one) and
/// returns it. Called by [pickWebDirectory] so the IDE's web branches in
/// `WorkspaceService` read the picked folder instead of the placeholder mock.
WebWorkspace adoptWebWorkspace(WebWorkspace ws) {
  webWorkspaceStore.workspace = ws;
  return ws;
}

IconData _webFileIcon(String name) {
  if (name.endsWith('.dart')) return Icons.flutter_dash;
  if (name.endsWith('.zig')) return Icons.bolt;
  if (name.endsWith('.rs')) return Icons.settings_applications;
  if (name.endsWith('.yaml') ||
      name.endsWith('.yml') ||
      name.endsWith('.json')) {
    return Icons.settings;
  }
  if (name.endsWith('.md')) return Icons.description;
  if (name.endsWith('.sh') || name.endsWith('.bash')) return Icons.terminal;
  return Icons.insert_drive_file_outlined;
}

/// Builds the explorer tree for a picked web folder: nested by relative
/// path, directories first, case-insensitive — mirroring the desktop walk.
List<FileTreeItem> buildWebFileTree(WebWorkspace ws) {
  final root = ws.rootPath;
  final files = [...ws.files]..sort((a, b) => a.path.compareTo(b.path));

  List<FileTreeItem> childrenOf(String relDir) {
    final items = <FileTreeItem>[];
    final seenDirs = <String>{};
    for (final f in files) {
      final rest = relDir.isEmpty
          ? f.path
          : (f.path.startsWith('$relDir/')
              ? f.path.substring(relDir.length + 1)
              : null);
      if (rest == null || rest.isEmpty) continue;
      if (!rest.contains('/')) {
        items.add(
          FileTreeItem(
            name: f.name,
            path: '$root/${f.path}',
            isFile: true,
            icon: _webFileIcon(f.name),
          ),
        );
      } else {
        final dirName = rest.substring(0, rest.indexOf('/'));
        if (seenDirs.add(dirName)) {
          final dirRel = relDir.isEmpty ? dirName : '$relDir/$dirName';
          items.add(
            FileTreeItem(
              name: dirName,
              path: '$root/$dirRel',
              isFile: false,
              icon: Icons.folder,
              children: childrenOf(dirRel),
            ),
          );
        }
      }
    }
    items.sort((a, b) {
      if (a.isFile != b.isFile) return a.isFile ? 1 : -1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return items;
  }

  return childrenOf('');
}
