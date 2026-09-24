import 'dart:convert';

/// Runtime budget and anti-loop policy for an autonomous agent run.
///
/// The guard is intentionally transport-agnostic: it protects the agent loop
/// regardless of which model/provider is selected.
class AgentRunBudget {
  const AgentRunBudget({
    this.maxToolCalls = 64,
    this.maxRunDuration = const Duration(minutes: 10),
    this.maxRepeatedToolCalls = 2,
    this.maxFingerprintChars = 4096,
  })  : assert(maxToolCalls > 0),
        assert(maxRunDuration > Duration.zero),
        assert(maxRepeatedToolCalls > 0),
        assert(maxFingerprintChars >= 256);

  final int maxToolCalls;
  final Duration maxRunDuration;
  final int maxRepeatedToolCalls;
  final int maxFingerprintChars;
}

class AgentRunGuard {
  AgentRunGuard({this.budget = const AgentRunBudget()})
      : _startedAt = DateTime.now();

  final AgentRunBudget budget;
  final DateTime _startedAt;
  final Map<String, int> _toolFingerprints = <String, int>{};

  int _toolCalls = 0;
  String? _budgetFailure;

  int get toolCalls => _toolCalls;
  String? get failureReason => _budgetFailure;
  Duration get elapsed => DateTime.now().difference(_startedAt);

  /// Checks hard runtime limits before another model/tool action starts.
  String? checkRunBudget({int? iterations}) {
    if (_budgetFailure != null) return _budgetFailure;

    if (iterations != null && iterations < 0) {
      _budgetFailure = 'Invalid negative iteration count.';
      return _budgetFailure;
    }

    if (elapsed >= budget.maxRunDuration) {
      _budgetFailure =
          'Agent runtime budget exceeded (${budget.maxRunDuration.inSeconds}s).';
      return _budgetFailure;
    }

    if (_toolCalls >= budget.maxToolCalls) {
      _budgetFailure =
          'Agent tool-call budget exceeded (${budget.maxToolCalls} calls).';
      return _budgetFailure;
    }

    return null;
  }

  /// Reserves one tool invocation.
  ///
  /// Duplicate calls with semantically identical arguments are allowed up to
  /// [maxRepeatedToolCalls], then blocked to prevent accidental infinite loops.
  /// The tool call counter is still incremented when a reservation is denied,
  /// making the hard budget monotonic.
  String? reserveTool(String name, Map<String, dynamic> arguments) {
    if (_budgetFailure != null) return _budgetFailure;

    if (elapsed >= budget.maxRunDuration) {
      _budgetFailure =
          'Agent runtime budget exceeded (${budget.maxRunDuration.inSeconds}s).';
      return _budgetFailure;
    }

    _toolCalls++;
    if (_toolCalls > budget.maxToolCalls) {
      _budgetFailure =
          'Agent tool-call budget exceeded (${budget.maxToolCalls} calls).';
      return _budgetFailure;
    }

    final fingerprint = _fingerprint(name, arguments);
    final count = (_toolFingerprints[fingerprint] ?? 0) + 1;
    _toolFingerprints[fingerprint] = count;

    if (count > budget.maxRepeatedToolCalls) {
      return 'Repeated tool call blocked: $name was requested '
          '$count times with identical arguments. Change strategy or inspect '
          'the latest tool result before retrying.';
    }

    return null;
  }

  String _fingerprint(String name, Map<String, dynamic> arguments) {
    final normalized = _normalize(arguments);
    var encoded = '$name:${jsonEncode(normalized)}';
    if (encoded.length > budget.maxFingerprintChars) {
      encoded = encoded.substring(0, budget.maxFingerprintChars);
    }
    return encoded;
  }

  dynamic _normalize(dynamic value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return <String, dynamic>{
        for (final key in keys) key: _normalize(value[key]),
      };
    }
    if (value is Iterable) {
      return value.map(_normalize).toList();
    }
    if (value is num || value is bool || value is String || value == null) {
      return value;
    }
    return value.toString();
  }
}

enum AgentReadOnlyTool {
  readFile('read_file'),
  listDirectory('list_directory'),
  searchWorkspace('search_workspace');

  const AgentReadOnlyTool(this.name);

  final String name;

  static bool contains(String name) {
    return AgentReadOnlyTool.values.any((tool) => tool.name == name);
  }
}
