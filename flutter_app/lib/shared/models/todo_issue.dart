/// One TODO / FIXME / HACK / BUG marker found inside a workspace file.
class TodoIssue {
  final String file;
  final int line;
  final String kind;
  final String text;

  const TodoIssue({
    required this.file,
    required this.line,
    required this.kind,
    required this.text,
  });
}

/// Marker keywords the workspace scanner looks for, mapped to the label shown
/// in the UI. Case-insensitive on the keyword itself.
const todoKeywords = {
  'TODO': 'TODO',
  'FIXME': 'FIXME',
  'HACK': 'HACK',
  'BUG': 'BUG',
  'XXX': 'TODO',
};

/// Extracts TODO/FIXME/HACK/BUG markers from [content] with 1-based line
/// numbers. Pure function so it is trivially unit-testable; the workspace
/// scan feeds it one file at a time.
List<TodoIssue> extractTodos(String content) {
  final matches = <TodoIssue>[];
  final lines = content.split('\n');
  final pattern =
      RegExp(r'\b(TODO|FIXME|HACK|BUG|XXX)\b', caseSensitive: false);

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final match = pattern.firstMatch(line);
    if (match == null) continue;
    final raw = match.group(1)!;
    final kind = todoKeywords[raw.toUpperCase()] ?? raw.toUpperCase();
    // Everything after the marker, trimmed, with a leading `:`/`;` separator
    // stripped (keeps the comment prefix out).
    var rest = line.substring(match.end).trim();
    rest = rest.replaceFirst(RegExp(r'^[:;]\s*'), '');
    matches.add(TodoIssue(file: '', line: i + 1, kind: kind, text: rest));
  }
  return matches;
}
