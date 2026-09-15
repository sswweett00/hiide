// Verifies the Dart fallback line diff (lib/core/backend/line_diff.dart) —
// the same contract the Zig engine's editor.diff_lines exposes, used offline
// and by MockBackendService.

import 'package:flutter_test/flutter_test.dart';
import 'package:hiide_flutter/core/backend/line_diff.dart';

List<(int, String, int)> _regions(String disk, String buffer) {
  return computeLineDiff(disk, buffer)
      .map((r) => (r.line, r.kind, r.count))
      .toList();
}

void main() {
  test('identical texts produce no regions', () {
    expect(_regions('alpha\nbeta\ngamma\n', 'alpha\nbeta\ngamma\n'), isEmpty);
    expect(_regions('', ''), isEmpty);
  });

  test('appended lines are added at the end', () {
    expect(_regions('a\nb\n', 'a\nb\nc\nd\n'), [(2, 'added', 2)]);
  });

  test('removed trailing lines are deleted at the boundary', () {
    expect(_regions('alpha\nbeta\ngamma\ndelta\n', 'alpha\nbeta\ngamma\n'),
        [(3, 'deleted', 1)]);
  });

  test('a middle edit is a modified region', () {
    expect(_regions('alpha\nbeta\ngamma\n', 'alpha\nBETA\ngamma\n'),
        [(1, 'modified', 1)]);
  });

  test('multiple regions keep exact line numbers', () {
    expect(
      _regions(
        'line0\none\ntwo\nthree\nend\n',
        'line0\nONE\ntwo\nend\ntail\n',
      ),
      [
        (1, 'modified', 1),
        (3, 'deleted', 1),
        (4, 'added', 1),
      ],
    );
  });

  test('empty buffer is all deletions; empty disk is all additions', () {
    expect(_regions('a\nb\nc\n', ''), [(0, 'deleted', 3)]);
    expect(_regions('', 'a\nb\nc\n'), [(0, 'added', 3)]);
  });

  test('trailing newline is a terminator, not a phantom line', () {
    expect(_regions('x\n', 'x'), isEmpty);
    expect(_regions('x\n', 'x\ny\n'), [(1, 'added', 1)]);
  });

  test('results agree with the Zig engine contract for the same input', () {
    // This case is covered end-to-end against the real engine in
    // hiide_backend_integration_test.dart; here we pin the Dart fallback to
    // the identical semantics.
    final regions = computeLineDiff('merhaba\niki\nüç\n', 'merhaba\nİKİ\nüç\n');
    expect(regions, hasLength(1));
    expect(regions.single.line, 1);
    expect(regions.single.kind, 'modified');
    expect(regions.single.count, 1);
  });
}
