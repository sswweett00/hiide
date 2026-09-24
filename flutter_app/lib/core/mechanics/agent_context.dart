import 'dart:convert';

/// Deterministic context compaction for long-running agent conversations.
///
/// Tool-call conversations contain structurally coupled messages
/// (assistant tool_calls + their tool results). Compaction works on whole user
/// turns so an API never receives an orphaned tool result.
class AgentContextCompactor {
  const AgentContextCompactor({
    this.maxMessages = 48,
    this.maxCharacters = 120000,
  })  : assert(maxMessages >= 4),
        assert(maxCharacters >= 4096);

  final int maxMessages;
  final int maxCharacters;

  List<Map<String, dynamic>> compact(
      List<Map<String, dynamic>> messages) {
    if (messages.length <= maxMessages &&
        _encodedSize(messages) <= maxCharacters) {
      return List<Map<String, dynamic>>.from(messages);
    }

    final system = messages.where((m) => m['role'] == 'system').toList();
    final body = messages
        .where((m) => m['role'] != 'system')
        .toList(growable: false);

    final turns = <List<Map<String, dynamic>>>[];
    var current = <Map<String, dynamic>>[];
    for (final message in body) {
      final role = message['role']?.toString();
      if (role == 'user' && current.isNotEmpty) {
        turns.add(current);
        current = <Map<String, dynamic>>[];
      }
      current.add(message);
    }
    if (current.isNotEmpty) turns.add(current);

    final selected = <List<Map<String, dynamic>>>[];
    var count = system.length;
    var chars = _encodedSize(system);

    for (var i = turns.length - 1; i >= 0; i--) {
      final turn = turns[i];
      final turnCount = turn.length;
      final turnChars = _encodedSize(turn);
      if (selected.isNotEmpty &&
          (count + turnCount > maxMessages ||
              chars + turnChars > maxCharacters)) {
        break;
      }
      if (selected.isEmpty &&
          turnChars > maxCharacters - chars &&
          turn.length > 2) {
        // Always keep the current turn, but trim large string fields so the
        // active tool interaction remains valid.
        final trimmed = _trimTurn(turn, maxCharacters - chars);
        selected.add(trimmed);
        count += trimmed.length;
        chars += _encodedSize(trimmed);
        break;
      }
      selected.add(turn);
      count += turnCount;
      chars += turnChars;
      if (count >= maxMessages || chars >= maxCharacters) break;
    }

    final orderedSelected = selected.reversed.toList();
    final result = <Map<String, dynamic>>[
      ...system,
      ...orderedSelected.expand((turn) => turn),
    ];

    return _trimToHardLimits(result);
  }

  List<Map<String, dynamic>> _trimToHardLimits(
      List<Map<String, dynamic>> messages) {
    if (messages.length <= maxMessages &&
        _encodedSize(messages) <= maxCharacters) {
      return messages;
    }

    final keep = <Map<String, dynamic>>[];
    for (final message in messages.reversed) {
      final next = <Map<String, dynamic>>[message, ...keep];
      if (next.length > maxMessages || _encodedSize(next) > maxCharacters) {
        break;
      }
      keep
        ..clear()
        ..addAll(next);
    }

    final system = messages.where((m) => m['role'] == 'system').toList();
    if (system.isNotEmpty && !keep.contains(system.first)) {
      if (keep.length == maxMessages) keep.removeAt(0);
      keep.insert(0, system.first);
    }
    return keep;
  }

  List<Map<String, dynamic>> _trimTurn(
      List<Map<String, dynamic>> turn, int budget) {
    if (budget <= 0) return const [];
    final result = <Map<String, dynamic>>[];
    var used = 0;
    for (final message in turn) {
      final copy = <String, dynamic>{...message};
      for (final key in ['content']) {
        final value = copy[key];
        if (value is String && value.length > 4000) {
          copy[key] = value.substring(0, 4000) + '\n…[context-compacted]';
        }
      }
      final size = _encodedSize([copy]);
      if (used + size > budget && result.isNotEmpty) break;
      if (used + size > budget) continue;
      result.add(copy);
      used += size;
    }
    return result;
  }

  int _encodedSize(List<Map<String, dynamic>> messages) {
    return utf8.encode(jsonEncode(messages)).length;
  }
}
