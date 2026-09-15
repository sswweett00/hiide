import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'web_workspace.dart';

/// Upper bound on how many picked files the web workspace will hold. A huge
/// directory pick would otherwise block the UI while every entry is wrapped;
/// beyond this cap the pick still succeeds but is truncated to stay smooth.
const int maxWebWorkspaceFiles = 20000;

// ─── Browser directory picker (web only) ─────────────────────────────────────
//
// Uses a hidden `<input type="file" webkitdirectory multiple>` — supported by
// every major browser — instead of the Chromium-only File System Access API,
// so the file manager works on web everywhere. Picked files arrive as real
// `File` objects with `webkitRelativePath`, read lazily via `File.text()`.

@JS('document')
external JSObject get _document;

@JS('window')
external JSObject get _window;

/// Opens the browser's native directory picker and returns the chosen folder
/// as a real, readable in-memory [WebWorkspace]. Returns null when the user
/// cancels or the picker cannot be opened. Desktop returns null immediately.
Future<WebWorkspace?> pickWebDirectory() async {
  if (!kIsWeb) return null;
  final body = _document['body'];
  if (body == null) return null;
  final bodyElement = body as JSObject;

  final completer = Completer<WebWorkspace?>();
  final input =
      _document.callMethod<JSObject>('createElement'.toJS, 'input'.toJS);
  input['type'] = 'file'.toJS;
  input['multiple'] = true.toJS;
  input.callMethod('setAttribute'.toJS, 'webkitdirectory'.toJS, ''.toJS);
  input['style'] = 'display:none'.toJS;
  bodyElement.callMethod('appendChild'.toJS, input);
  var attached = true;

  void removeInput() {
    if (!attached) return;
    attached = false;
    // Only touch the DOM when the input is still attached — a double close
    // (e.g. the native dialog closing while `change` also fired) must not
    // throw a NotFoundError from `removeChild`.
    if (input['parentNode'] != null) {
      bodyElement.callMethod('removeChild'.toJS, input);
    }
  }

  JSFunction? focusHandler;

  void completeFromInput() {
    removeInput();
    // Never let a browser quirk turn into a stuck or crashing UI: any
    // unexpected error simply resolves as a cancel.
    try {
      // The browser exposes the chosen path on the input (e.g.
      // `C:\fakepath\myproj` or `...\myproj\file.txt`); capture it before
      // the value is cleared so a file-less folder still gets a name.
      final valueHint = (input['value'] as JSString?)?.toDart ?? '';
      final filesAny = input['files'];
      if (filesAny == null) {
        if (!completer.isCompleted) completer.complete(null);
        return;
      }
      final fileList = filesAny as JSObject;
      final length = (fileList['length'] as JSNumber?)?.toDartInt ?? 0;

      var folderName = '';
      final entries = <WebFileEntry>[];
      for (var i = 0;
          i < length && entries.length < maxWebWorkspaceFiles;
          i++) {
        final file = fileList.callMethod<JSObject>('item'.toJS, i.toJS);
        final relPath = (file['webkitRelativePath'] as JSString?)?.toDart ?? '';
        final name = (file['name'] as JSString?)?.toDart ?? '';
        if (relPath.isEmpty) continue;
        final firstSlash = relPath.indexOf('/');
        if (firstSlash == -1) continue;
        final dirName = relPath.substring(0, firstSlash);
        final rel = relPath.substring(firstSlash + 1);
        if (rel.isEmpty) continue;
        folderName = dirName;
        final size = (file['size'] as JSNumber?)?.toDartInt ?? 0;
        entries.add(
          WebFileEntry(
            path: rel,
            name: name,
            size: size,
            read: () async {
              // A stalled or rejected File.text() must never block the flow
              // (it used to hang `activateWorkspace` mid-pick, so the picked
              // folder never opened). Bound the read and degrade to a
              // placeholder so navigation always proceeds.
              try {
                final text = await file
                    .callMethod<JSPromise<JSString>>('text'.toJS)
                    .toDart
                    .timeout(const Duration(seconds: 5));
                return text.toDart;
              } catch (e) {
                debugPrint('Web file read failed for $rel: $e');
                return '// (web: could not read $name)';
              }
            },
          ),
        );
      }
      input['value'] = ''.toJS; // allow re-picking the same folder
      _window.callMethod(
        'removeEventListener'.toJS,
        'focus'.toJS,
        focusHandler,
      );
      if (!completer.isCompleted) {
        // An empty folder (webkitdirectory yields zero files) still opens as
        // a real workspace — the IDE shows its (empty) tree instead of
        // silently treating the pick as a cancel. The name falls back to the
        // browser's path hint, or a neutral label when even that is missing.
        final name =
            folderName.isNotEmpty ? folderName : _fallbackFolderName(valueHint);
        completer.complete(WebWorkspace(name: name, files: entries));
      }
    } catch (_) {
      if (!completer.isCompleted) completer.complete(null);
    }
  }

  // The hidden input fires `change` only when something was picked; a
  // cancelled dialog instead just refocuses the window. Browsers fire
  // `change` before the focus event, but to be safe the deferred focus check
  // first inspects the input: if files are already present (the `change`
  // event simply hasn't been dispatched yet) the pick is processed, and only
  // a genuinely empty input is treated as a cancel.
  focusHandler = ((JSAny? _) {
    _window.callMethod(
      'setTimeout'.toJS,
      (() {
        if (completer.isCompleted) return;
        final filesAny = input['files'];
        var hasFiles = false;
        if (filesAny != null) {
          final fileList = filesAny as JSObject;
          final len = fileList['length'] as JSNumber?;
          hasFiles = (len?.toDartInt ?? 0) > 0;
        }
        if (hasFiles) {
          completeFromInput();
          return;
        }
        removeInput();
        _window.callMethod(
          'removeEventListener'.toJS,
          'focus'.toJS,
          focusHandler,
        );
        completer.complete(null);
      }).toJS,
      0.toJS,
    );
  }).toJS;
  _window.callMethod('addEventListener'.toJS, 'focus'.toJS, focusHandler);

  input.callMethod(
    'addEventListener'.toJS,
    'change'.toJS,
    ((JSAny? _) => completeFromInput()).toJS,
  );
  input.callMethod('click'.toJS);

  // Safety net for browsers that fire neither `change` nor a focus event
  // after a cancelled dialog; a plain cancel otherwise resolves on focus.
  return completer.future.timeout(
    const Duration(minutes: 3),
    onTimeout: () {
      _window.callMethod(
        'removeEventListener'.toJS,
        'focus'.toJS,
        focusHandler,
      );
      removeInput();
      return null;
    },
  );
}

/// Derives a display name for a pick that yielded no files (empty folder):
/// the browser's path hint's last segment, or a neutral label.
String _fallbackFolderName(String pathHint) {
  if (pathHint.isNotEmpty) {
    var t = pathHint;
    while (t.endsWith('/') || t.endsWith('\\')) {
      t = t.substring(0, t.length - 1);
    }
    final i = t.lastIndexOf(RegExp(r'[/\\]'));
    final segment = i == -1 ? t : t.substring(i + 1);
    if (segment.isNotEmpty) return segment;
  }
  return 'folder';
}
