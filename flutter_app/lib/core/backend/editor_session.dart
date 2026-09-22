import 'dart:async';

import 'package:flutter/widgets.dart';

import 'backend_service.dart';
import 'line_diff.dart';

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

  int? engineHandle;
  String _lastContent;
  String diskContent;
  Future<void> _queue = Future<void>.value();
  Future<void>? _initFuture;
  bool _engineHealthy = true;
  bool _disposed = false;

  String get lastContent => _lastContent;
  bool get engineHealthy => _engineHealthy && engineHandle != null;

  Future<void> init() {
    if (_disposed || engineHandle != null) return Future<void>.value();
    return _initFuture ??= _initInternal().whenComplete(() => _initFuture = null);
  }

  Future<void> _initInternal() async {
    try {
      final handle = await backend.editorLoad(controller.text);
      if (_disposed) {
        try { await backend.editorDestroy(handle); } catch (_) {}
        return;
      }
      engineHandle = handle;
      _engineHealthy = true;
    } catch (error) {
      _engineHealthy = false;
      engineHandle = null;
      debugPrint('EditorSession: engine load failed for $tabId: $error');
    }
  }

  bool updateFromExternal(String content) {
    if (_disposed || content == controller.text) return false;
    if (controller.text != diskContent && content != controller.text) {
      debugPrint('EditorSession: preserving unsaved local changes for $tabId');
      return false;
    }

    final selection = controller.selection;
    controller.value = controller.value.copyWith(
      text: content,
      selection: TextSelection.collapsed(offset: selection.baseOffset.clamp(0, content.length)),
      composing: TextRange.empty,
    );
    _lastContent = content;
    diskContent = content;
    _enqueueEngine((handle) => backend.editorApplyText(handle, content));
    return true;
  }

  void markSaved(String content) {
    if (_disposed) return;
    diskContent = content;
    _lastContent = content;
  }

  Future<List<EditorDiffRegion>> diffAgainstDisk() async {
    if (_disposed) return computeLineDiff(diskContent, controller.text);
    await _queue;
    final handle = engineHandle;
    if (handle != null && _engineHealthy) {
      try {
        return await backend.editorDiffLines(handle, diskContent);
      } catch (error) {
        _engineHealthy = false;
        engineHandle = null;
        debugPrint('EditorSession: engine diff failed for $tabId: $error');
      }
    }
    return computeLineDiff(diskContent, controller.text);
  }

  void syncChange(String newContent) {
    if (_disposed || newContent == _lastContent) return;
    _lastContent = newContent;
    _enqueueEngine((handle) => backend.editorApplyText(handle, newContent));
  }

  void _enqueueEngine(Future<void> Function(int handle) operation) {
    final handle = engineHandle;
    if (_disposed || handle == null || !_engineHealthy) return;
    _queue = _queue.then((_) async {
      if (_disposed || engineHandle != handle || !_engineHealthy) return;
      try {
        await operation(handle);
      } catch (error) {
        _engineHealthy = false;
        engineHandle = null;
        debugPrint('EditorSession: engine sync failed for $tabId: $error');
      }
    });
  }

  Future<void> syncToEngine() => _queue;

  Future<String> engineText() async {
    if (_disposed) return controller.text;
    await _queue;
    final handle = engineHandle;
    if (handle != null && _engineHealthy) {
      try {
        return await backend.editorGetText(handle);
      } catch (error) {
        _engineHealthy = false;
        engineHandle = null;
        debugPrint('EditorSession: engine read failed for $tabId: $error');
      }
    }
    return controller.text;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final handle = engineHandle;
    engineHandle = null;
    try {
      await _queue.timeout(const Duration(seconds: 2));
    } catch (_) {}
    if (handle != null) {
      try { await backend.editorDestroy(handle).timeout(const Duration(seconds: 2)); } catch (_) {}
    }
    controller.dispose();
  }
}
