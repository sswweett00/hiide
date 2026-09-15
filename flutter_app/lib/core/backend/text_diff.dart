import 'dart:convert';

/// A minimal single-region text edit: delete `removedLen` units at `start`,
/// then insert `inserted` at the same position.
class TextEdit {
  final int start;
  final int removedLen;
  final String inserted;

  const TextEdit({
    required this.start,
    required this.removedLen,
    required this.inserted,
  });

  bool get isNoop => removedLen == 0 && inserted.isEmpty;
}

/// Computes the single-region edit that transforms [oldText] into [newText].
///
/// Uses the longest-common-prefix / longest-common-suffix heuristic, which is
/// exact for the single-cursor flows of a code editor (typing, deleting,
/// pasting in one spot) and cheap: O(n) worst case with no allocations for
/// the comparison itself. The result maps directly onto the Zig engine's
/// `editor.delete` + `editor.insert` ops.
TextEdit computeTextEdit(String oldText, String newText) {
  if (oldText == newText) {
    return const TextEdit(start: 0, removedLen: 0, inserted: '');
  }

  final oldLen = oldText.length;
  final newLen = newText.length;

  // Longest common prefix.
  var prefix = 0;
  final maxPrefix = oldLen < newLen ? oldLen : newLen;
  while (prefix < maxPrefix &&
      oldText.codeUnitAt(prefix) == newText.codeUnitAt(prefix)) {
    prefix++;
  }

  // Longest common suffix (anchored after the prefix).
  var oldSuffix = oldLen;
  var newSuffix = newLen;
  while (oldSuffix > prefix &&
      newSuffix > prefix &&
      oldText.codeUnitAt(oldSuffix - 1) == newText.codeUnitAt(newSuffix - 1)) {
    oldSuffix--;
    newSuffix--;
  }

  return TextEdit(
    start: prefix,
    removedLen: oldSuffix - prefix,
    inserted: newText.substring(prefix, newSuffix),
  );
}

/// Converts a code-unit edit into an equivalent byte edit against [oldText].
///
/// The Zig engine's gap buffer addresses positions in UTF-8 **bytes**, while
/// Dart strings address positions in UTF-16 code units. For pure-ASCII text
/// the two are identical; for non-ASCII content (Turkish, CJK, emoji, ...)
/// they diverge. This performs the exact conversion needed before sending
/// `editor.delete` / `editor.insert` ops to the engine.
TextEdit toByteEdit(String oldText, TextEdit edit) {
  if (edit.isNoop) return edit;
  // Encode the full old text once and slice the resulting byte array to
  // find byte offsets — avoids the previous double-utf8.encode that
  // re-encoded the prefix for every call.
  final encoded = utf8.encode(oldText);
  final byteStart = _byteOffset(encoded, oldText, edit.start);
  final byteEnd = _byteOffset(encoded, oldText, edit.start + edit.removedLen);
  return TextEdit(
      start: byteStart,
      removedLen: byteEnd - byteStart,
      inserted: edit.inserted);
}

/// Given a single [encoded] byte array for [text], returns the byte offset
/// corresponding to the code-unit position [cuPos] without re-encoding.
int _byteOffset(List<int> encoded, String text, int cuPos) {
  if (cuPos <= 0) return 0;
  if (cuPos >= text.length) return encoded.length;
  // Walk the encoded bytes, consuming UTF-16 code units as we go.
  var byteIdx = 0;
  var cuIdx = 0;
  while (cuIdx < cuPos && byteIdx < encoded.length) {
    final b = encoded[byteIdx];
    // Determine how many bytes this UTF-8 sequence consumes.
    int seqLen;
    if (b < 0x80) {
      seqLen = 1;
    } else if (b < 0xE0) {
      seqLen = 2;
    } else if (b < 0xF0) {
      seqLen = 3;
    } else {
      seqLen = 4;
    }
    byteIdx += seqLen;
    // A BMP character (<= U+FFFF) is 1 UTF-16 code unit;
    // a supplementary character (> U+FFFF) is 2 UTF-16 code units.
    cuIdx += (seqLen <= 3) ? 1 : 2;
  }
  return byteIdx;
}
