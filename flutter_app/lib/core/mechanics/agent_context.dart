import 'dart:convert';

/// Deterministic context compaction for long-running agent conversations.
///
/// Tool-call conversations are structurally coupled:
/// assistant(tool_calls) must stay adjacent to the corresponding tool results.
/// Compaction therefore removes whole message segments rather than arbitrary
/// suffixes, preventing malformed API history.
class AgentContextCompactor {
  const AgentContextCompactor({
    this.maxMessages = 48,
    this.maxCharacters = 120000,
  })  : assert(maxMessages >= 4),
        assert(maxCharacters >= 4096);

  final int maxMessages;
  final int maxCharacters;

  List<Map<String, dynamic>> compact(List<Map<String, dynamic>> messages) {
    if (messages.length <= maxMessages &&
        _encodedSize(messages) <= maxCharacters) {
      return List<Map<String, dynamic>>.from(messages);
    }

    final system = <Map<String, dynamic>>[];
    final body = <Map<String, dynamic>>[];
    for (final message in messages) {
      if (message['role'] == 'system') {
        system.add(message);
      } else {
        body.add(message);
      }
    }

    final segments = _segments(body);
    final selected = <List<Map<String, dynamic>>>[];
    var count = system.length;
    var chars = _encodedSize(system);

    for (var i = segments.length - 1; i >= 0; i--) {
      final segment = segments[i];
      final segmentCount = segment.length;
      final segmentChars = _encodedSize(segment);

      if (selected.isNotEmpty &&
          (count + segmentCount > maxMessages ||
              chars + segmentChars > maxCharacters)) {
        break;
      }

      selected.add(segment);
      count += segmentCount;
      chars += segmentChars;

      // Never discard the newest segment solely because it is large. Keeping
      // its structural integrity is more important than a soft context cap.
      if (selected.length == 1 && segmentCount + system.length > maxMessages) {
        break;
      }
      if (count >= maxMessages || chars >= maxCharacters) break;
    }

    final ordered = selected.reversed.toList();
    return <Map<String, dynamic>>[
      ...system,
      ...ordered.expand((segment) => segment),
    ];
  }

  List<List<Map<String, dynamic>>> _segments(
      List<Map<String, dynamic>> body) {
    final segments = <List<Map<String, dynamic>>>[];

    for (var i = 0; i < body.length; i++) {
      final message = body[i];
      final role = message['role']?.toString();

      if (role == 'assistant' && _hasToolCalls(message)) {
        final segment = <Map<String, dynamic>>[message];
        var j = i + 1;
        while (j < body.length && body[j]['role'] == 'tool') {
          segment.add(body[j]);
          j++;
        }
        segments.add(segment);
        i = j - 1;
        continue;
      }

      if (role == 'tool') {
        // Orphaned tool messages should never be emitted into a compacted
        // request. The normal agent loop always attaches them above.
        continue;
      }

      segments.add(<Map<String, dynamic>>[message]);
    }

    return segments;
  }

  bool _hasToolCalls(Map<String, dynamic> message) {
    final calls = message['tool_calls'];
    return calls is List && calls.isNotEmpty;
  }

  int _encodedSize(List<Map<String, dynamic>> messages) {
    return utf8.encode(jsonEncode(messages)).length;
  }
}
