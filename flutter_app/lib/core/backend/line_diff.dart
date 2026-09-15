import 'backend_service.dart';

/// Dart-side mirror of the Zig engine's `editor.diff_lines` (Myers line diff).
///
/// Used as the offline fallback when the engine is unreachable and by
/// [MockBackendService] so the gutter works without the binary. Same contract:
/// sparse `EditorDiffRegion`s with 0-based buffer line numbers.
List<EditorDiffRegion> computeLineDiff(String oldText, String newText,
    {int maxD = 1000, int maxLines = 60000}) {
  final a = _splitLines(oldText);
  final b = _splitLines(newText);

  final regions = <EditorDiffRegion>[];

  // Common prefix / suffix trim.
  var prefix = 0;
  final maxPrefix = a.length < b.length ? a.length : b.length;
  while (prefix < maxPrefix && a[prefix] == b[prefix]) {
    prefix++;
  }
  var aSuf = a.length;
  var bSuf = b.length;
  while (aSuf > prefix && bSuf > prefix && a[aSuf - 1] == b[bSuf - 1]) {
    aSuf--;
    bSuf--;
  }

  final midA = a.sublist(prefix, aSuf);
  final midB = b.sublist(prefix, bSuf);

  if (midA.isEmpty && midB.isEmpty) return regions;

  // Pure insertion / pure deletion (or inputs too big to diff precisely).
  if (midA.isEmpty || midB.isEmpty || midA.length + midB.length > maxLines) {
    regions.add(EditorDiffRegion(
      line: prefix,
      kind: midB.isEmpty ? 'deleted' : 'added',
      count: midB.isEmpty ? midA.length : midB.length,
    ));
    return regions;
  }

  final ops = _myers(midA, midB, maxD);
  if (ops == null) {
    regions.add(EditorDiffRegion(
      line: prefix,
      kind: 'modified',
      count: midB.length,
    ));
    return regions;
  }

  var bufferCursor = prefix;
  var i = 0;
  while (i < ops.length) {
    if (ops[i].kind == _OpKind.equal) {
      bufferCursor += ops[i].count;
      i++;
      continue;
    }
    var bufDelta = 0;
    var diskDelta = 0;
    while (i < ops.length && ops[i].kind != _OpKind.equal) {
      if (ops[i].kind == _OpKind.inserted) {
        bufDelta += ops[i].count;
      } else {
        diskDelta += ops[i].count;
      }
      i++;
    }
    final kind = (bufDelta > 0 && diskDelta > 0)
        ? 'modified'
        : (bufDelta > 0 ? 'added' : 'deleted');
    regions.add(EditorDiffRegion(
      line: bufferCursor,
      kind: kind,
      count: kind == 'deleted' ? diskDelta : bufDelta,
    ));
    bufferCursor += bufDelta;
  }
  return regions;
}

enum _OpKind { equal, deleted, inserted }

class _Op {
  final _OpKind kind;
  int count;

  _Op(this.kind, this.count);
}

/// Splits into lines; a trailing '\n' is a terminator, not a phantom line.
List<String> _splitLines(String text) {
  if (text.isEmpty) return const [];
  final lines = text.split('\n');
  if (text.endsWith('\n')) lines.removeLast();
  return lines;
}

/// Myers O((N+M)D); null when the edit distance exceeds [maxD].
List<_Op>? _myers(List<String> a, List<String> b, int maxD) {
  final n = a.length;
  final m = b.length;

  final vLen = 2 * maxD + 1;
  final v0 = maxD;
  final v = List<int>.filled(vLen, -1);
  v[v0 + 1] = 0;

  final trace = <List<int>>[];

  int? found;
  var d = 0;
  while (d <= maxD) {
    trace.add(List<int>.from(v));
    for (var k = -d; k <= d; k += 2) {
      var x = (k == -d || (k != d && v[v0 + k - 1] < v[v0 + k + 1]))
          ? v[v0 + k + 1]
          : v[v0 + k - 1] + 1;
      var y = x - k;
      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }
      v[v0 + k] = x;
      if (x >= n && y >= m) {
        found = d;
        break;
      }
    }
    if (found != null) break;
    d++;
  }

  if (found == null) return null;

  final ops = <_Op>[];
  var x = n;
  var y = m;
  for (var dd = found; dd > 0; dd--) {
    final snap = trace[dd];
    final k = x - y;
    final prevK = (k == -dd || (k != dd && snap[v0 + k - 1] < snap[v0 + k + 1]))
        ? k + 1
        : k - 1;
    final prevX = snap[v0 + prevK];
    final prevY = prevX - prevK;
    while (x > prevX && y > prevY) {
      ops.add(_Op(_OpKind.equal, 1));
      x--;
      y--;
    }
    if (x == prevX) {
      ops.add(_Op(_OpKind.inserted, 1));
      y--;
    } else {
      ops.add(_Op(_OpKind.deleted, 1));
      x--;
    }
  }
  while (x > 0 || y > 0) {
    if (x > 0 && y > 0) {
      ops.add(_Op(_OpKind.equal, 1));
      x--;
      y--;
    } else if (x > 0) {
      ops.add(_Op(_OpKind.deleted, 1));
      x--;
    } else {
      ops.add(_Op(_OpKind.inserted, 1));
      y--;
    }
  }
  final reversed = ops.reversed.toList();

  final merged = <_Op>[];
  for (final op in reversed) {
    if (merged.isNotEmpty && merged.last.kind == op.kind) {
      merged.last.count += op.count;
    } else {
      merged.add(_Op(op.kind, op.count));
    }
  }
  return merged;
}
