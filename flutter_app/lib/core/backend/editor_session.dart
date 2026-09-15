import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'backend_service.dart';
import 'line_diff.dart';

/// Bridges one open editor tab to the native Zig engine buffer.
///
/// The UI keeps a plain [TextEditingController] for fast local editing, but
/// every change is translated into minimal `editor.delete`/`editor.insert`
/// ops and applied to the engine's gap buffer (the authoritative document
/// state). Ops are serialized on an internal queue so the engine buffer never
/// observes out-of-order edits, even when keystrokes arrive faster than the
/// IPC round-trips. When the engine is unreachable the session degrades
/// gracefully: the tab keeps working and saving uses the local content.
class EditorSession {
  EditorSession({
    required this.tabId,
    required this.backend,
    required String content,
  })  : controller = TextEditingController(text: content),
        _lastContent = content,
        diskContent = content;

  final String tabId;
  final BackendService backend;
  final TextEditingController controller;

  /// Opaque engine handle; null until `init()` succeeds.
  int? engineHandle;

  String _lastContent;

  /// The on-disk reference the gutter diff is computed against: what was
  /// loaded from disk (or last saved), refreshed by external reloads.
  String diskContent;

  Future<void> _queue = Future<void>.value();

  String get lastContent => _lastContent;

  /// Loads the tab's content into the engine buffer.
  Future<void> init() async {
    try {
      engineHandle = await backend.editorLoad(controller.text);
    } catch (e) {
      debugPrint(
          'EditorSession: engine load failed for $tabId, offline mode: $e');
      engineHandle = null;
    }
  }

  /// Reconciles an external content update (e.g. the native watcher reloaded
  /// a file that changed on disk, or a search result opened a different
  /// version) with this session. The engine buffer is reconciled too, so a
  /// later save (`engineText()`) writes the fresh content, not the stale one.
  ///
  /// Returns true when an update was actually applied (the caller can then
  /// refresh gutter diff state).
  bool updateFromExternal(String content) {
    if (content == controller.text) return false;
    controller.text = content;
    _lastContent = content;
    // An external update is by definition the new on-disk baseline.
    diskContent = content;
    final handle = engineHandle;
    if (handle == null) return true;
    _queue = _queue.then((_) async {
      await backend.editorApplyText(handle, content);
    }).catchError((Object e) {
      debugPrint('EditorSession: engine sync failed for $tabId: $e');
    });
    return true;
  }

  /// Records that the buffer was just saved as [content]; the gutter diff
  /// against the new disk state is now empty.
  void markSaved(String content) {
    diskContent = content;
    _lastContent = content;
  }

  /// Line-based diff of the current buffer against [diskContent], computed by
  /// the engine (native Myers); falls back to the Dart algorithm offline.
  Future<List<EditorDiffRegion>> diffAgainstDisk() async {
    await _queue;
    final handle = engineHandle;
    if (handle != null) {
      try {
        return await backend.editorDiffLines(handle, diskContent);
      } catch (e) {
        debugPrint('EditorSession: engine diff failed for $tabId: $e');
      }
    }
    return computeLineDiff(diskContent, controller.text);
  }

  /// Applies a UI change to the engine buffer.
  ///
  /// The engine computes the minimal single-region edit natively (longest
  /// common prefix/suffix in UTF-8 bytes) and applies it in one call — no
  /// Dart-side diff and no code-unit → byte offset conversion.
  void syncChange(String newContent) {
    final old = _lastContent;
    _lastContent = newContent;
    final handle = engineHandle;
    if (handle == null || old == newContent) return;

    _queue = _queue.then((_) async {
      await backend.editorApplyText(handle, newContent);
    }).catchError((Object e) {
      debugPrint('EditorSession: engine sync failed for $tabId: $e');
    });
  }

  /// Waits until every queued op has been applied to the engine buffer.
  Future<void> syncToEngine() => _queue;

  /// The authoritative document text as the engine holds it (falls back to
  /// the local content when offline).
  Future<String> engineText() async {
    if (engineHandle == null) return _lastContent;
    await _queue;
    return backend.editorGetText(engineHandle!);
  }

  /// Releases the engine buffer and the text controller.
  Future<void> dispose() async {
    await _queue;
    final handle = engineHandle;
    engineHandle = null;
    if (handle != null) {
      try {
        await backend.editorDestroy(handle);
      } catch (_) {
        // Engine already gone — nothing to do.
      }
    }
    controller.dispose();
  }
}
