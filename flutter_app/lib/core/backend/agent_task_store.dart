import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _redactSensitiveText(String value) {
  var sanitized = value;
  final patterns = <RegExp>[
    RegExp(
      r'''["']?(api[_-]?key|apikey|password|secret|access[_-]?token|refresh[_-]?token)["']?\s*[:=]\s*["']?[^\s,"'}]+''',
      caseSensitive: false,
    ),
    RegExp(
      r'bearer\s+[A-Za-z0-9._~+\-/]+=*',
      caseSensitive: false,
    ),
    RegExp(
      r'''-----BEGIN [A-Z ]+ PRIVATE KEY-----[\s\S]*?-----END [A-Z ]+ PRIVATE KEY-----''',
      caseSensitive: false,
    ),
  ];
  for (final pattern in patterns) {
    sanitized = sanitized.replaceAllMapped(pattern, (_) => '[REDACTED]');
  }
  return sanitized;
}

enum AgentTaskStatus { queued, planning, executing, verifying, waitingApproval, succeeded, succeededWithWarnings, failed, canceled }

extension AgentTaskStatusX on AgentTaskStatus {
  String get label => switch (this) {
        AgentTaskStatus.waitingApproval => 'Waiting approval',
        AgentTaskStatus.succeededWithWarnings => 'Succeeded with warnings',
        _ => name[0].toUpperCase() + name.substring(1),
      };

  bool get terminal =>
      this == AgentTaskStatus.succeeded ||
      this == AgentTaskStatus.succeededWithWarnings ||
      this == AgentTaskStatus.failed ||
      this == AgentTaskStatus.canceled;
}

enum AgentArtifactType { plan, report, verification, note }

class AgentArtifact {
  final String id;
  final AgentArtifactType type;
  final String title;
  final String content;
  final DateTime createdAt;
  const AgentArtifact({
    required this.id,
    required this.type,
    required this.title,
    required this.content,
    required this.createdAt,
  });
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'title': title,
        'content': content,
        'createdAt': createdAt.toIso8601String(),
      };
  factory AgentArtifact.fromJson(Map<String, dynamic> json) => AgentArtifact(
        id: json['id']?.toString() ?? '',
        type: AgentArtifactType.values.firstWhere(
          (v) => v.name == json['type'],
          orElse: () => AgentArtifactType.note,
        ),
        title: _redactSensitiveText(json['title']?.toString() ?? 'Artifact'),
        content: _redactSensitiveText(json['content']?.toString() ?? ''),
        createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? DateTime.now(),
      );
}

class AgentTimelineEvent {
  final String id;
  final String kind;
  final String title;
  final String detail;
  final DateTime createdAt;
  final bool success;
  const AgentTimelineEvent({
    required this.id,
    required this.kind,
    required this.title,
    this.detail = '',
    required this.createdAt,
    this.success = true,
  });
  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'title': title,
        'detail': detail,
        'createdAt': createdAt.toIso8601String(),
        'success': success,
      };
  factory AgentTimelineEvent.fromJson(Map<String, dynamic> json) => AgentTimelineEvent(
        id: json['id']?.toString() ?? '',
        kind: json['kind']?.toString() ?? 'event',
        title: _redactSensitiveText(json['title']?.toString() ?? ''),
        detail: _redactSensitiveText(json['detail']?.toString() ?? ''),
        createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? DateTime.now(),
        success: json['success'] != false,
      );
}

class AgentTaskRecord {
  final String id;
  final String objective;
  final String workspace;
  final String mode;
  final AgentTaskStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? summary;
  final String? error;
  final String? plan;
  final List<String> changedFiles;
  final List<String> verificationCommands;
  final List<AgentArtifact> artifacts;
  final List<AgentTimelineEvent> timeline;
  final List<Map<String, dynamic>> transcript;
  final int toolCalls;
  final bool? verificationPassed;

  const AgentTaskRecord({
    required this.id,
    required this.objective,
    required this.workspace,
    required this.mode,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.summary,
    this.error,
    this.plan,
    this.changedFiles = const [],
    this.verificationCommands = const [],
    this.artifacts = const [],
    this.timeline = const [],
    this.transcript = const [],
    this.toolCalls = 0,
    this.verificationPassed,
  });

  AgentTaskRecord copyWith({
    AgentTaskStatus? status,
    DateTime? updatedAt,
    String? summary,
    String? error,
    String? plan,
    List<String>? changedFiles,
    List<String>? verificationCommands,
    List<AgentArtifact>? artifacts,
    List<AgentTimelineEvent>? timeline,
    List<Map<String, dynamic>>? transcript,
    int? toolCalls,
    bool? verificationPassed,
    bool clearError = false,
  }) => AgentTaskRecord(
        id: id,
        objective: objective,
        workspace: workspace,
        mode: mode,
        status: status ?? this.status,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
        summary: summary ?? this.summary,
        error: clearError ? null : (error ?? this.error),
        plan: plan ?? this.plan,
        changedFiles: changedFiles ?? this.changedFiles,
        verificationCommands: verificationCommands ?? this.verificationCommands,
        artifacts: artifacts ?? this.artifacts,
        timeline: timeline ?? this.timeline,
        transcript: transcript ?? this.transcript,
        toolCalls: toolCalls ?? this.toolCalls,
        verificationPassed: verificationPassed ?? this.verificationPassed,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'objective': objective,
        'workspace': workspace,
        'mode': mode,
        'status': status.name,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'summary': summary,
        'error': error,
        'plan': plan,
        'changedFiles': changedFiles,
        'verificationCommands': verificationCommands,
        'artifacts': artifacts.map((e) => e.toJson()).toList(),
        'timeline': timeline.map((e) => e.toJson()).toList(),
        'transcript': transcript,
        'toolCalls': toolCalls,
        'verificationPassed': verificationPassed,
      };

  factory AgentTaskRecord.fromJson(Map<String, dynamic> json) {
    List<String> strings(dynamic value) => value is List
        ? value.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
        : <String>[];
    List<Map<String, dynamic>> maps(dynamic value) => value is List
        ? value.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : <Map<String, dynamic>>[];
    return AgentTaskRecord(
      id: json['id']?.toString() ?? '',
      objective: _redactSensitiveText(json['objective']?.toString() ?? ''),
      workspace: json['workspace']?.toString() ?? '',
      mode: json['mode']?.toString() ?? 'code',
      status: AgentTaskStatus.values.firstWhere(
        (v) => v.name == json['status'],
        orElse: () => AgentTaskStatus.failed,
      ),
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? '') ?? DateTime.now(),
      summary: json['summary'] == null
          ? null
          : _redactSensitiveText(json['summary'].toString()),
      error: json['error'] == null
          ? null
          : _redactSensitiveText(json['error'].toString()),
      plan: json['plan'] == null
          ? null
          : _redactSensitiveText(json['plan'].toString()),
      changedFiles: strings(json['changedFiles']),
      verificationCommands: strings(json['verificationCommands']),
      artifacts: (json['artifacts'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => AgentArtifact.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      timeline: (json['timeline'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => AgentTimelineEvent.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      transcript: maps(json['transcript']),
      toolCalls: (json['toolCalls'] as num?)?.toInt() ?? 0,
      verificationPassed: json['verificationPassed'] is bool
          ? json['verificationPassed'] as bool
          : null,
    );
  }
}

class AgentTaskStore {
  AgentTaskStore._(this._prefs, this._tasks);

  AgentTaskStore.inMemory() : _prefs = null, _tasks = <AgentTaskRecord>[];
  static const _prefsKey = 'hiide.agent_tasks.v1';
  static const _maxTasks = 50;
  static const _maxTimeline = 120;
  static const _maxTranscript = 80;
  static const _maxArtifacts = 16;
  static const _maxArtifactChars = 16000;

  final SharedPreferences? _prefs;
  List<AgentTaskRecord> _tasks;
  bool _persistRunning = false;
  bool _persistRequested = false;
  String? _persistenceError;
  Completer<void>? _persistWaiter;

  List<AgentTaskRecord> get tasks => List.unmodifiable(_tasks);
  String? get persistenceError => _persistenceError;
  bool get persistenceHealthy => _prefs != null && _persistenceError == null;

  static Future<AgentTaskStore> load() async {
    late final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      // Storage is optional for runtime operation. A platform/channel
      // failure must never prevent the IDE from starting.
      return AgentTaskStore.inMemory();
    }
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return AgentTaskStore._(prefs, <AgentTaskRecord>[]);
    try {
      final decoded = jsonDecode(raw);
      final tasks = decoded is List
          ? decoded.whereType<Map>().map((e) => AgentTaskRecord.fromJson(Map<String, dynamic>.from(e)))
              .where((e) => e.id.isNotEmpty).toList()
          : <AgentTaskRecord>[];
      tasks.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      final recovered = tasks.take(_maxTasks).map((task) {
        if (task.status.terminal) return task;
        return task.copyWith(
          status: AgentTaskStatus.canceled,
          error: 'Application restarted before this task reached a terminal state.',
          summary: task.summary ?? 'Interrupted by application restart.',
        );
      }).toList();
      final store = AgentTaskStore._(prefs, recovered);
      await store._persist();
      return store;
    } catch (_) {
      return AgentTaskStore._(prefs, <AgentTaskRecord>[]);
    }
  }

  AgentTaskRecord create({required String objective, required String workspace, required String mode}) {
    final now = DateTime.now();
    final task = AgentTaskRecord(
      id: 'task_' + now.microsecondsSinceEpoch.toString(),
      objective: _redactSensitiveText(objective),
      workspace: workspace,
      mode: mode,
      status: AgentTaskStatus.queued,
      createdAt: now,
      updatedAt: now,
    );
    _tasks = <AgentTaskRecord>[task, ..._tasks].take(_maxTasks).toList();
    _persist();
    return task;
  }

  AgentTaskRecord? byId(String id) => _find(id);

  AgentTaskRecord? update(
    String id, {
    AgentTaskStatus? status,
    String? summary,
    String? error,
    String? plan,
    List<String>? changedFiles,
    List<String>? verificationCommands,
    int? toolCalls,
    bool? verificationPassed,
    bool clearError = false,
  }) {
    final task = _find(id);
    if (task == null) return null;
    return _replace(task.copyWith(
      status: status,
      summary: summary == null ? null : _redactSensitiveText(summary),
      error: error == null ? null : _redactSensitiveText(error),
      plan: plan == null ? null : _redactSensitiveText(plan),
      changedFiles: changedFiles,
      verificationCommands: verificationCommands,
      toolCalls: toolCalls,
      verificationPassed: verificationPassed,
      clearError: clearError,
    ));
  }

  AgentTaskRecord? addArtifact(String id, AgentArtifact artifact) {
    final task = _find(id);
    if (task == null) return null;
    final content = artifact.content.length > _maxArtifactChars
        ? artifact.content.substring(0, _maxArtifactChars) + '\n…[truncated]'
        : artifact.content;
    final safe = AgentArtifact(
      id: artifact.id,
      type: artifact.type,
      title: _redactSensitiveText(
        artifact.title.length > 240
            ? artifact.title.substring(0, 240)
            : artifact.title,
      ),
      content: _redactSensitiveText(content),
      createdAt: artifact.createdAt,
    );
    return _replace(task.copyWith(
      artifacts: <AgentArtifact>[...task.artifacts, safe]
          .take(_maxArtifacts)
          .toList(),
    ));
  }

  AgentTaskRecord? addEvent(
    String id, {
    required String kind,
    required String title,
    String detail = '',
    bool success = true,
  }) {
    final task = _find(id);
    if (task == null) return null;
    final event = AgentTimelineEvent(
      id: 'event_' + DateTime.now().microsecondsSinceEpoch.toString(),
      kind: kind,
      title: _redactSensitiveText(title),
      detail: _redactSensitiveText(detail),
      createdAt: DateTime.now(),
      success: success,
    );
    return _replace(task.copyWith(
      timeline: <AgentTimelineEvent>[...task.timeline, event].take(_maxTimeline).toList(),
    ));
  }

  AgentTaskRecord? replaceTranscript(String id, List<Map<String, dynamic>> messages) {
    final task = _find(id);
    if (task == null) return null;
    final safe = messages.map(_sanitizeMessage).toList();
    final start = safe.length > _maxTranscript ? safe.length - _maxTranscript : 0;
    return _replace(task.copyWith(transcript: safe.sublist(start)));
  }

  /// Coalesces bursty task mutations into the smallest possible number of
  /// SharedPreferences writes. Agent tool events can arrive several times per
  /// second; serializing every intermediate snapshot creates stale queued work.
  Future<void> _persist() {
    _persistRequested = true;
    final waiter = _persistWaiter ??= Completer<void>();
    if (!_persistRunning) {
      unawaited(_drainPersistence());
    }
    return waiter.future;
  }

  Future<void> _drainPersistence() async {
    if (_persistRunning) return;
    _persistRunning = true;
    try {
      while (_persistRequested) {
        _persistRequested = false;
        final snapshot = jsonEncode(
          _tasks.map((e) => e.toJson()).toList(),
        );
        final prefs = _prefs;
        if (prefs != null) {
          try {
            await prefs.setString(_prefsKey, snapshot);
            _persistenceError = null;
          } catch (error) {
            _persistenceError = error.toString();
          }
        }
      }
    } finally {
      _persistRunning = false;
      final waiter = _persistWaiter;
      _persistWaiter = null;
      if (waiter != null && !waiter.isCompleted) waiter.complete();
      if (_persistRequested) {
        unawaited(_drainPersistence());
      }
    }
  }

  Future<void> flush() => _persist();

  AgentTaskRecord? _find(String id) {
    for (final task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  AgentTaskRecord? _replace(AgentTaskRecord next) {
    final index = _tasks.indexWhere((e) => e.id == next.id);
    if (index < 0) return null;
    _tasks = <AgentTaskRecord>[..._tasks]..[index] = next;
    _tasks.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _persist();
    return next;
  }

  Map<String, dynamic> _sanitizeMessage(Map<String, dynamic> message) {
    return message.map(
      (key, value) => MapEntry(key, _sanitizeValue(value, depth: 0)),
    );
  }

  dynamic _sanitizeValue(dynamic value, {required int depth}) {
    if (value is String) {
      const limit = 4000;
      final sanitized = _redactSensitiveText(value);
      if (sanitized.length <= limit) return sanitized;
      return sanitized.substring(0, limit) + '\n…[transcript-truncated]';
    }
    if (value is num || value is bool || value == null) return value;

    // Keep nested tool-call structures, but cap both depth and fan-out so one
    // large write_file request cannot explode SharedPreferences storage.
    if (depth >= 4) return value.toString();

    if (value is List) {
      return value
          .take(24)
          .map((item) => _sanitizeValue(item, depth: depth + 1))
          .toList();
    }

    if (value is Map) {
      final result = <String, dynamic>{};
      for (final entry in value.entries.take(24)) {
        result[entry.key.toString()] =
            _sanitizeValue(entry.value, depth: depth + 1);
      }
      return result;
    }

    return value.toString();
  }
}

final agentTaskStoreProvider = Provider<AgentTaskStore>((ref) => AgentTaskStore.inMemory());
final activeAgentTaskIdProvider = StateProvider<String?>((ref) => null);
final agentTaskVersionProvider = StateProvider<int>((ref) => 0);
