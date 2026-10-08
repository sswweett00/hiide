import 'dart:async';

import 'agent_controller.dart';
import 'agent_orchestrator.dart';
import 'agent_profile.dart';
import 'agent_task_store.dart';
import 'ai_chat_client.dart';
import 'ai_memory/memory_store.dart';
import 'backend_service.dart';

class AgentApprovalRequest {
  const AgentApprovalRequest({
    required this.id,
    required this.taskId,
    required this.toolName,
    required this.arguments,
  });

  final String id;
  final String taskId;
  final String toolName;
  final Map<String, dynamic> arguments;
}

class AgentRunHandle {
  const AgentRunHandle({
    required this.taskId,
    required this.events,
    required this.done,
    required this._stop,
  });

  final String taskId;
  final Stream<AgentEvent> events;
  final Future<void> done;
  final void Function() _stop;

  void stop() => _stop();
}

/// Owns agent execution outside the widget tree.
///
/// A screen may subscribe to [AgentRunHandle.events], navigate away, or be
/// rebuilt without terminating the underlying agent task. Persistent task
/// state is checkpointed through [AgentTaskStore].
class AgentRunManager {
  AgentRunManager({
    required this.ai,
    required this.backend,
    required this.taskStore,
    required this.mcpManager,
    this.onChanged,
  });

  final AiChatClient ai;
  final BackendService backend;
  final AgentTaskStore taskStore;
  final HiideMcpManager mcpManager;
  final void Function()? onChanged;

  final Map<String, AgentController> _controllers = <String, AgentController>{};
  final Map<String, String> _workspaceByTask = <String, String>{};
  final Map<String, Future<void>> _runs = <String, Future<void>>{};
  final Map<String, Completer<bool>> _approvalWaiters =
      <String, Completer<bool>>{};
  final Map<String, AgentApprovalRequest> _pendingApprovals =
      <String, AgentApprovalRequest>{};

  final StreamController<AgentApprovalRequest> _approvalController =
      StreamController<AgentApprovalRequest>.broadcast();

  Stream<AgentApprovalRequest> get approvalRequests =>
      _approvalController.stream;

  bool isRunning(String taskId) => _runs.containsKey(taskId);

  void _changed() => onChanged?.call();

  List<AgentApprovalRequest> get pendingApprovals =>
      List.unmodifiable(_pendingApprovals.values);

  Future<AgentRunHandle> startBuild({
    required String taskId,
    required String objective,
    required List<Map<String, dynamic>> history,
    required String workspaceRoot,
    required String model,
    required AgentProfile profile,
  }) async {
    if (isRunning(taskId)) {
      throw StateError('Agent task is already running: ' + taskId);
    }

    final activeRoots = _workspaceByTask.values.toSet();
    if (activeRoots.any((root) => root != workspaceRoot)) {
      throw StateError(
        'Cannot start an MCP-enabled task in another workspace while a background task is active.',
      );
    }
    try {
      await mcpManager.loadWorkspace(
        workspaceRoot,
        approvalHandler: (config) => _requestMcpServerApproval(
          taskId,
          config,
        ),
      );
    } catch (error) {
      taskStore.update(
        taskId,
        status: AgentTaskStatus.failed,
        error: error.toString(),
        summary: 'MCP server initialization failed.',
      );
      taskStore.addEvent(
        taskId,
        kind: 'mcp.error',
        title: 'MCP initialization failed',
        detail: error.toString(),
        success: false,
      );
      _changed();
      rethrow;
    }
    _workspaceByTask[taskId] = workspaceRoot;

    taskStore.update(
      taskId,
      status: AgentTaskStatus.executing,
      clearError: true,
    );
    taskStore.addEvent(
      taskId,
      kind: 'execution',
      title: 'Agent runtime started',
      detail: 'Execution is owned by the task manager, not the chat widget.',
    );
    _changed();

    final controller = AgentController(
      ai: ai,
      backend: backend,
      workspaceRoot: workspaceRoot,
      model: model,
      systemPrompt: profile.systemPrompt,
      maxIterations: profile.maxIterations,
      allowedTools: profile.allowedTools,
      mcpManager: mcpManager,
      approvalHandler: (toolName, arguments) =>
          _requestApproval(taskId, toolName, arguments),
    );

    _controllers[taskId] = controller;

    final eventController = StreamController<AgentEvent>();
    final run = _consumeBuild(
      taskId: taskId,
      objective: objective,
      workspaceRoot: workspaceRoot,
      model: model,
      history: history,
      controller: controller,
      output: eventController,
    );

    _runs[taskId] = run;

    run.whenComplete(() {
      _runs.remove(taskId);
      _controllers.remove(taskId);
      _workspaceByTask.remove(taskId);
    });

    return AgentRunHandle(
      taskId: taskId,
      events: eventController.stream,
      done: run,
      controller.stop,
    );
  }

  void stop(String taskId) {
    _controllers[taskId]?.stop();
    final pending = <String>[];
    for (final entry in _approvalWaiters.entries) {
      if (entry.key.startsWith(taskId + ':')) pending.add(entry.key);
    }
    for (final requestId in pending) {
      final waiter = _approvalWaiters.remove(requestId);
      if (waiter != null && !waiter.isCompleted) waiter.complete(false);
      _pendingApprovals.remove(requestId);
    }
    if (pending.isNotEmpty) _changed();
  }

  Future<void> resolveApproval(String requestId, bool approved) async {
    final waiter = _approvalWaiters.remove(requestId);
    if (waiter == null || waiter.isCompleted) return;

    waiter.complete(approved);
    _pendingApprovals.remove(requestId);

    final taskId = _taskIdForApproval(requestId);
    if (taskId != null) {
      taskStore.update(
        taskId,
        status: approved
            ? AgentTaskStatus.executing
            : AgentTaskStatus.failed,
        error: approved ? null : 'User rejected the requested command.',
        clearError: approved,
      );
      taskStore.addEvent(
        taskId,
        kind: 'approval.resolved',
        title: approved ? 'Approval granted' : 'Approval rejected',
        detail: requestId,
        success: approved,
      );
      _changed();
    }
  }

  Future<bool> _requestMcpServerApproval(
    String taskId,
    McpServerConfig config,
  ) async {
    final detail = config.transport == 'stdio'
        ? config.command.toString() + ' ' + config.args.join(' ')
        : (config.url ?? config.id);
    return _requestApproval(
      taskId,
      'mcp_server.start',
      <String, dynamic>{
        'server_id': config.id,
        'transport': config.transport,
        'detail': detail,
      },
    );
  }

  Future<bool> _requestApproval(
    String taskId,
    String toolName,
    Map<String, dynamic> arguments,
  ) {
    final requestId =
        taskId + ':' + DateTime.now().microsecondsSinceEpoch.toString();
    final waiter = Completer<bool>();
    _approvalWaiters[requestId] = waiter;

    taskStore.update(
      taskId,
      status: AgentTaskStatus.waitingApproval,
    );
    taskStore.addEvent(
      taskId,
      kind: 'approval.requested',
      title: 'User approval required',
      detail: _detailForTool(toolName, arguments),
      success: false,
    );

    final request = AgentApprovalRequest(
      id: requestId,
      taskId: taskId,
      toolName: toolName,
      arguments: Map<String, dynamic>.from(arguments),
    );
    _pendingApprovals[requestId] = request;
    _approvalController.add(request);
    _changed();

    return waiter.future;
  }

  Future<void> _consumeBuild({
    required String taskId,
    required String objective,
    required String workspaceRoot,
    required String model,
    required List<Map<String, dynamic>> history,
    required AgentController controller,
    required StreamController<AgentEvent> output,
  }) async {
    try {
      await for (final event in controller.run(history)) {
        _checkpointEvent(taskId, controller, event);

        switch (event) {
          case AgentDoneEvent(:final text):
            await _finalizeBuild(
              taskId: taskId,
              objective: objective,
              workspaceRoot: workspaceRoot,
              model: model,
              summary: text,
            );
            output.add(event);
          case AgentErrorEvent(:final message, :final rollback):
            output.add(event);
            _recordRollback(taskId, rollback);
            taskStore.update(
              taskId,
              status: AgentTaskStatus.failed,
              error: message,
              summary: 'Agent execution failed.',
            );
          case AgentStoppedEvent(:final rollback):
            output.add(event);
            _recordRollback(taskId, rollback);
            taskStore.update(
              taskId,
              status: AgentTaskStatus.canceled,
              summary: 'Agent stopped by user.',
            );
          case AgentIterationLimitEvent(:final iterations, :final reason, :final rollback):
            output.add(event);
            _recordRollback(taskId, rollback);
            final message = reason + ' (iteration ' + iterations.toString() + ').';
            taskStore.update(
              taskId,
              status: AgentTaskStatus.failed,
              error: message,
              summary: 'Agent budget limit reached.',
            );
          case AgentTextTokenEvent():
            output.add(event);
          case AgentToolStartedEvent():
            output.add(event);
          case AgentToolFinishedEvent():
            output.add(event);

        }

        taskStore.replaceTranscript(taskId, controller.workingMessages);
        _changed();
      }
    } catch (error) {
      taskStore.update(
        taskId,
        status: AgentTaskStatus.failed,
        error: error.toString(),
        summary: 'Agent runtime failed unexpectedly.',
      );
      taskStore.addEvent(
        taskId,
        kind: 'error',
        title: 'Agent runtime failure',
        detail: error.toString(),
        success: false,
      );
    } finally {
      taskStore.replaceTranscript(taskId, controller.workingMessages);
      await taskStore.flush();
      _changed();
      await output.close();
    }
  }

  void _recordRollback(String taskId, AgentRollbackReport? rollback) {
    if (rollback == null || !rollback.hasChanges) return;
    final detail = <String>[
      'Restored: ' + rollback.restored.toString(),
      'Skipped: ' + rollback.skipped.toString(),
      if (rollback.errors.isNotEmpty)
        'Details: ' + rollback.errors.join(' | '),
    ].join('\\n');
    taskStore.addEvent(
      taskId,
      kind: rollback.complete ? 'rollback' : 'rollback_partial',
      title: rollback.complete
          ? 'Agent changes rolled back'
          : 'Rollback completed with conflicts',
      detail: detail,
      success: rollback.complete,
    );
    _changed();
  }

  void _checkpointEvent(
    String taskId,
    AgentController controller,
    AgentEvent event,
  ) {
    if (event is AgentToolFinishedEvent) {
      final tool = event.toolCall;
      final current = taskStore.byId(taskId);
      final path = tool.arguments['path']?.toString();
      final changed = <String>[
        ...(current?.changedFiles ?? const <String>[]),
      ];

      if (tool.status == AgentToolStatus.success &&
          path != null &&
          path.isNotEmpty &&
          (tool.name == 'write_file' ||
              tool.name == 'apply_diff' ||
              tool.name == 'delete_file') &&
          !changed.contains(path)) {
        changed.add(path);
      }

      final command = tool.name == 'run_command'
          ? tool.arguments['command']?.toString() ?? ''
          : '';
      final verification = <String>[
        ...(current?.verificationCommands ?? const <String>[]),
      ];
      final isVerification = command.isNotEmpty &&
          _isVerificationCommand(command);

      if (isVerification && !verification.contains(command)) {
        verification.add(command);
      }

      taskStore.update(
        taskId,
        toolCalls: (current?.toolCalls ?? 0) + 1,
        changedFiles: changed,
        verificationCommands: verification,
        verificationPassed: isVerification
            ? tool.status == AgentToolStatus.success
            : current?.verificationPassed,
        status: isVerification ? AgentTaskStatus.verifying : null,
      );

      taskStore.addEvent(
        taskId,
        kind: isVerification ? 'verification' : 'tool.finish',
        title: tool.name,
        detail: _truncate(tool.result ?? 'No output'),
        success: tool.status == AgentToolStatus.success,
      );
      _changed();
    } else if (event is AgentToolStartedEvent) {
      taskStore.addEvent(
        taskId,
        kind: 'tool.start',
        title: event.toolCall.name,
        detail: _detailForTool(
          event.toolCall.name,
          event.toolCall.arguments,
        ),
      );
      _changed();
    }
  }

  Future<void> _finalizeBuild({
    required String taskId,
    required String objective,
    required String workspaceRoot,
    required String model,
    required String summary,
  }) async {
    final current = taskStore.byId(taskId);
    final verificationFailed = current?.verificationPassed == false;
    final changedFiles =
        List<String>.from(current?.changedFiles ?? const <String>[]);

    var specialistResults = const <AgentSpecialistResult>[];

    if (!verificationFailed) {
      taskStore.update(taskId, status: AgentTaskStatus.verifying);
      taskStore.addEvent(
        taskId,
        kind: 'specialist.start',
        title: 'Read-only specialist review started',
        detail: 'Explorer + Reviewer + Security run in parallel.',
      );

      final specialists = AgentOrchestrator(
        ai: ai,
        backend: backend,
        workspaceRoot: workspaceRoot,
        model: model,
      );

      specialistResults = await specialists.runParallelReadOnlyReview(
        objective: objective,
        changedFiles: changedFiles,
      );

      for (final result in specialistResults) {
        taskStore.addArtifact(
          taskId,
          AgentArtifact(
            id: 'artifact_' +
                result.profile.id.name +
                '_' +
                DateTime.now().microsecondsSinceEpoch.toString(),
            type: AgentArtifactType.report,
            title: result.profile.label + ' specialist report',
            content: result.output,
            createdAt: DateTime.now(),
          ),
        );
        taskStore.addEvent(
          taskId,
          kind: 'specialist.finish',
          title: result.profile.label + ' completed',
          detail: result.output,
          success: result.success,
        );
      }
    }

    final specialistFailed = specialistResults.any((result) => !result.success);
    final finalStatus = verificationFailed
        ? AgentTaskStatus.failed
        : specialistFailed
            ? AgentTaskStatus.succeededWithWarnings
            : AgentTaskStatus.succeeded;

    final finalSummary = verificationFailed
        ? 'Agent completed but verification failed.'
        : specialistFailed
            ? 'Agent completed with incomplete specialist verification.'
            : summary;

    taskStore.update(
      taskId,
      status: finalStatus,
      summary: finalSummary,
    );

    taskStore.addArtifact(
      taskId,
      AgentArtifact(
        id: 'artifact_report_' +
            DateTime.now().microsecondsSinceEpoch.toString(),
        type: AgentArtifactType.report,
        title: 'Execution report',
        content: _buildReport(
          objective,
          changedFiles,
          current,
          specialistResults,
          summary,
        ),
        createdAt: DateTime.now(),
      ),
    );

    taskStore.addEvent(
      taskId,
      kind: verificationFailed ? 'completed_with_failure' : 'completed',
      title: verificationFailed
          ? 'Task ended with verification failure'
          : specialistFailed
              ? 'Task completed with warnings'
              : 'Task completed successfully',
      success: !verificationFailed && !specialistFailed,
    );

    unawaited(
      aiMemoryStore
          .storeConversationSummary(
            workspaceRoot: workspaceRoot,
            summary: finalSummary,
            topics: _keywords(objective),
          )
          .catchError((_) {}),
    );
  }

  String _buildReport(
    String objective,
    List<String> changedFiles,
    AgentTaskRecord? task,
    List<AgentSpecialistResult> specialists,
    String summary,
  ) {
    final review = specialists.isEmpty
        ? 'Specialist review: not run.'
        : specialists
            .map(
              (result) =>
                  result.profile.label +
                  ': ' +
                  (result.success ? 'completed' : 'failed'),
            )
            .join(' | ');

    return <String>[
      'Objective: ' + objective,
      'Changed files: ' +
          (changedFiles.isEmpty ? 'none' : changedFiles.join(', ')),
      'Verification: ' +
          ((task?.verificationCommands ?? const <String>[]).isEmpty
              ? 'none recorded'
              : task!.verificationCommands.join(' | ')),
      'Verification result: ' +
          (task?.verificationPassed == null
              ? 'not recorded'
              : (task!.verificationPassed! ? 'passed' : 'failed')),
      review,
      '',
      summary.trim(),
    ].join('\n');
  }

  String _detailForTool(String toolName, Map<String, dynamic> arguments) {
    final command = arguments['command']?.toString();
    if (command != null && command.isNotEmpty) return command;
    final path = arguments['path']?.toString();
    if (path != null && path.isNotEmpty) return path;
    final query = arguments['query']?.toString();
    if (query != null && query.isNotEmpty) return query;
    final detail = arguments['detail']?.toString();
    if (detail != null && detail.isNotEmpty) return detail;
    return toolName;
  }

  bool _isVerificationCommand(String command) {
    final lower = command.toLowerCase();
    const markers = <String>[
      'test',
      'build',
      'analyze',
      'lint',
      'typecheck',
      'type-check',
      'check',
      'verify',
      'compile',
      'fmt',
    ];
    return markers.any(lower.contains);
  }

  String _truncate(String value) {
    const max = 500;
    if (value.length <= max) return value;
    return value.substring(0, max) + '\n…[truncated]';
  }

  List<String> _keywords(String text) {
    return text
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9_\-]+'))
        .where((word) => word.length >= 4)
        .take(8)
        .toList();
  }

  String? _taskIdForApproval(String requestId) {
    final index = requestId.indexOf(':');
    return index <= 0 ? null : requestId.substring(0, index);
  }

  Future<void> dispose() async {
    for (final controller in _controllers.values) {
      controller.stop();
    }
    for (final waiter in _approvalWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.complete(false);
      }
    }
    _approvalWaiters.clear();
    _pendingApprovals.clear();

    final active = List<Future<void>>.from(_runs.values);
    if (active.isNotEmpty) {
      try {
        await Future.wait(active).timeout(const Duration(seconds: 5));
      } catch (_) {}
    }

    await mcpManager.closeAll();
    _workspaceByTask.clear();
    await _approvalController.close();
  }
}
