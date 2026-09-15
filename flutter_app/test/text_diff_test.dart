import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiide_flutter/core/backend/text_diff.dart';

void main() {
  group('computeTextEdit', () {
    test('no-op when texts are equal', () {
      final edit = computeTextEdit('abc', 'abc');
      expect(edit.isNoop, isTrue);
    });

    test('pure insertion in the middle', () {
      final edit = computeTextEdit('hello world', 'hello brave world');
      expect(edit.start, 6);
      expect(edit.removedLen, 0);
      expect(edit.inserted, 'brave ');
    });

    test('pure insertion at the start', () {
      final edit = computeTextEdit('world', 'hello world');
      expect(edit.start, 0);
      expect(edit.removedLen, 0);
      expect(edit.inserted, 'hello ');
    });

    test('pure insertion at the end', () {
      final edit = computeTextEdit('hello', 'hello world');
      expect(edit.start, 5);
      expect(edit.removedLen, 0);
      expect(edit.inserted, ' world');
    });

    test('pure deletion', () {
      final edit = computeTextEdit('hello world', 'helloworld');
      expect(edit.start, 5);
      expect(edit.removedLen, 1);
      expect(edit.inserted, '');
    });

    test('replace in the middle round-trips (may be non-minimal)', () {
      // The prefix/suffix heuristic is always correct but can be non-minimal
      // when repeated substrings appear on both sides of the edit point.
      String apply(String old, TextEdit edit) {
        final before = old.substring(0, edit.start);
        final after = old.substring(edit.start + edit.removedLen);
        return '$before${edit.inserted}$after';
      }

      const old = 'foo-bar-baz';
      const fresh = 'foo+bar+baz';
      final edit = computeTextEdit(old, fresh);
      expect(apply(old, edit), fresh);
      expect(edit.isNoop, isFalse);
    });

    test('apply edit round-trips old into new', () {
      String apply(String old, TextEdit edit) {
        final before = old.substring(0, edit.start);
        final after = old.substring(edit.start + edit.removedLen);
        return '$before${edit.inserted}$after';
      }

      const cases = [
        ('hello world', 'hello brave world'),
        ('a\nb\nc', 'a\nb\nc\nd'),
        ('dart code here', ''),
        ('', 'fresh file'),
        ('line one\nline two', 'line one\nLINE TWO'),
        ('xyz', 'x'),
      ];
      for (final (old, fresh) in cases) {
        final edit = computeTextEdit(old, fresh);
        expect(apply(old, edit), fresh, reason: '$old -> $fresh');
      }
    });

    test('multi-byte content uses code-unit offsets', () {
      final edit = computeTextEdit('merhaba dünya', 'merhaba güzel dünya');
      expect(edit.start, 8); // after 'merhaba ' (8 code units incl. space)
      expect(edit.removedLen, 0);
      expect(edit.inserted, 'güzel ');
    });

    test('toByteEdit converts code-unit offsets into UTF-8 byte offsets', () {
      const old = 'merhaba dünya';
      // Insert at the very end (code unit 13). 'ü' is 2 UTF-8 bytes, so the
      // byte offset is 14.
      final edit = toByteEdit(
          old, const TextEdit(start: 13, removedLen: 0, inserted: 'X'));
      expect(edit.start, utf8.encode(old).length);
      expect(edit.start, 14);
      expect(edit.removedLen, 0);
      expect(edit.inserted, 'X');
    });

    test('toByteEdit converts removed length to bytes', () {
      const old = 'abc ğxyz';
      // Delete 'ğ' (2 UTF-8 bytes) at code unit 4.
      final edit = toByteEdit(
          old, const TextEdit(start: 4, removedLen: 1, inserted: ''));
      expect(edit.start, 4);
      expect(edit.removedLen, 2);
    });

    test('toByteEdit is a no-op passthrough for ASCII and empty edits', () {
      const asciiOld = 'hello world';
      final edit = toByteEdit(
          asciiOld, const TextEdit(start: 5, removedLen: 1, inserted: '+'));
      expect(edit.start, 5);
      expect(edit.removedLen, 1);

      final noop = toByteEdit(
          asciiOld, const TextEdit(start: 0, removedLen: 0, inserted: ''));
      expect(noop.isNoop, isTrue);
    });
  });
}
