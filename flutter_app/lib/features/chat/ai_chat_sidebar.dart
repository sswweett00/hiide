import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/backend/agent_controller.dart';
import '../../core/backend/agent_run_manager.dart';
import '../../core/backend/agent_run_manager_provider.dart';
import '../../core/backend/agent_profile.dart';
import '../../core/backend/skill_registry.dart';
import '../../core/backend/ai_agents/planning_agent.dart';
import '../../core/backend/agent_mode.dart';
import '../../core/backend/agent_task_store.dart';
import '../../core/backend/ai_memory/memory_store.dart';
import '../../core/design_system/tokens.dart';
import '../../core/providers/backend_provider.dart';
import '../../core/backend/ai_providers/provider_manager.dart';
import '../../shared/models/chat_message.dart';
import '../../shared/widgets/ai_widgets.dart';
import '../../shared/providers/workspace_providers.dart';

final chatMessagesProvider = StateProvider<List<ChatMessage>>((ref) => []);
final chatInputProvider = StateProvider<String>((ref) => '');
final streamingMessageProvider = StateProvider<String>((ref) => '');

/// Canonical conversation history in OpenAI chat format. Persisted across
/// turns so the agent loop can continue a multi-step task.
final agentMessagesProvider =
    StateProvider<List<Map<String, dynamic>>>((ref) => []);

/// One-shot prompt injected by the agent workspace or quick actions.
/// sidebar watches this and sends it automatically.
final aiPromptProvider = StateProvider<String?>((ref) => null);

/// Optional selected workspace path; the agent reads file contents itself.
const _maxVisibleChatMessages = 300;
const _maxAgentHistoryMessages = 160;

List<ChatMessage> _boundedChatMessages(Iterable<ChatMessage> messages) {
  final values = messages.toList(growable: false);
  if (values.length <= _maxVisibleChatMessages) {
    return List<ChatMessage>.from(values);
  }
  return values.sublist(values.length - _maxVisibleChatMessages);
}

List<Map<String, dynamic>> _boundedAgentMessages(
    Iterable<Map<String, dynamic>> messages) {
  final values = messages
      .map((message) => Map<String, dynamic>.from(message))
      .toList(growable: false);
  if (values.length <= _maxAgentHistoryMessages) {
    return values;
  }

  // Drop oldest messages by complete user turns. This keeps tool-call
  // conversations structurally valid while bounding long-lived UI state.
  final firstKept = values.length - _maxAgentHistoryMessages;
  var start = firstKept;
  while (start < values.length &&
      values[start]['role'] != 'user' &&
      start < values.length - 1) {
    start++;
  }
  return values.sublist(start);
}

class AiChatSidebar extends ConsumerStatefulWidget {
  const AiChatSidebar({super.key});

  @override
  ConsumerState<AiChatSidebar> createState() => _AiChatSidebarState();
}

class _AiChatSidebarState extends ConsumerState<AiChatSidebar> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  VoidCallback? _stopActiveAgent;
  Timer? _streamFlushTimer;
  StreamSubscription<AgentApprovalRequest>? _agentApprovalSubscription;
  final StringBuffer _streamBuffer = StringBuffer();

  @override
  void initState() {
    super.initState();
    final manager = ref.read(agentRunManagerProvider);
    _agentApprovalSubscription = manager.approvalRequests.listen(
      _showAgentApprovalRequest,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final request in manager.pendingApprovals) {
        unawaited(_showAgentApprovalRequest(request));
      }
    });
  }

  @override
  void dispose() {
    _streamFlushTimer?.cancel();
    _streamFlushTimer = null;
    _streamBuffer.clear();
    _agentApprovalSubscription?.cancel();
    _agentApprovalSubscription = null;
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if (animate) {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(target);
      }
    });
  }

  /// Coalesces high-frequency model tokens into bounded UI updates.
  ///
  /// Providers can emit dozens of token events per frame. Updating Riverpod
  /// state and starting a new scroll animation for each token forces repeated
  /// layout/paint work and creates visible jank on long generations.
  void _queueStreamingToken(String token) {
    if (token.isEmpty) return;
    _streamBuffer.write(token);
    if (_streamFlushTimer?.isActive ?? false) return;
    _streamFlushTimer =
        Timer(const Duration(milliseconds: 33), _flushStreamingText);
  }

  void _flushStreamingText() {
    _streamFlushTimer = null;
    if (!mounted || _streamBuffer.isEmpty) return;

    final chunk = _streamBuffer.toString();
    _streamBuffer.clear();
    final current = ref.read(streamingMessageProvider);
    ref.read(streamingMessageProvider.notifier).state = current + chunk;
    _scrollToBottom(animate: false);
  }

  void _finishStreamingText() {
    _streamFlushTimer?.cancel();
    _streamFlushTimer = null;
    _flushStreamingText();
  }

  void _resetStreamingText() {
    _streamFlushTimer?.cancel();
    _streamFlushTimer = null;
    _streamBuffer.clear();
    ref.read(streamingMessageProvider.notifier).state = '';
  }

  void _addMessage(ChatMessage msg) {
    final next = [
      ...ref.read(chatMessagesProvider),
      msg,
    ];
    ref.read(chatMessagesProvider.notifier).state = _boundedChatMessages(next);
    _scrollToBottom();
  }

  List<String> _memoryKeywords(String text) {
    final words = RegExp(r'[A-Za-zÇĞİÖŞÜçğıöşü0-9_-]{4,}')
        .allMatches(text.toLowerCase())
        .map((match) => match.group(0)!)
        .where((word) => !_memoryStopWords.contains(word))
        .toSet()
        .take(12)
        .toList();
    return words;
  }

  Future<String> _memoryContext(String request, String workspaceRoot) async {
    try {
      return await aiMemoryStore.buildContext(
        workspaceRoot: workspaceRoot,
        keywords: _memoryKeywords(request),
        maxChars: 8000,
      );
    } catch (error) {
      debugPrint('AI memory context unavailable: $error');
      return '';
    }
  }

  static const _memoryStopWords = <String>{
    'this',
    'that',
    'with',
    'from',
    'then',
    'only',
    'have',
    'your',
    'bunu',
    'şunu',
    'için',
    'olan',
    'sonra',
    'gibi',
    'daha',
    'olanı',
  };

  String _buildAgentPrompt(String message) {
    final selectedPath = ref.read(selectedWorkspacePathProvider);
    if (selectedPath == null || selectedPath.trim().isEmpty) return message;
    return message +
        '\n\n--- Selected workspace context target ---\n' +
        selectedPath +
        '\n--- End selected target ---\n' +
        'Read the target yourself with read_file before making conclusions.';
  }

  Future<void> _sendMessage([String? preset]) async {
    final text = (preset ?? _inputController.text).trim();
    if (text.isEmpty || ref.read(isAiThinkingProvider)) return;
    _inputController.clear();
    _addMessage(ChatMessage(role: ChatRole.user, content: text, timestamp: DateTime.now()));

    final mode = ref.read(agentModeProvider);
    final workspace = ref.read(workspaceServiceProvider).rootPath;
    final store = ref.read(agentTaskStoreProvider);
    final task = store.create(
      objective: text,
      workspace: workspace,
      mode: mode.name,
    );
    ref.read(activeAgentTaskIdProvider.notifier).state = task.id;
    store.addEvent(
      task.id,
      kind: 'task',
      title: 'Görev kabul edildi',
      detail: text,
    );
    ref.read(agentTaskVersionProvider.notifier).state++;
    ref.read(isAiThinkingProvider.notifier).state = true;
    ref.read(streamingMessageProvider.notifier).state = '';
    try {
      if (mode == AgentMode.plan) {
        await _runPlanMode(text);
      } else {
        await _runCodeMode(text);
      }
    } catch (e) {
      if (!mounted) return;
      _finishStreamingText();
      ref.read(streamingMessageProvider.notifier).state = '';
      final taskId = ref.read(activeAgentTaskIdProvider);
      if (taskId != null) {
        final store = ref.read(agentTaskStoreProvider);
        store.update(taskId, status: AgentTaskStatus.failed, error: e.toString());
        store.addEvent(taskId, kind: 'error', title: 'Görev beklenmeyen hata ile sonlandı', detail: e.toString(), success: false);
        ref.read(agentTaskVersionProvider.notifier).state++;
      }
      _addMessage(ChatMessage(role: ChatRole.error, content: 'Error: ' + e.toString(), timestamp: DateTime.now()));
    } finally {
      _stopActiveAgent = null;
      if (mounted) {
        _finishStreamingText();
        ref.read(streamingMessageProvider.notifier).state = '';
        ref.read(isAiThinkingProvider.notifier).state = false;
      }
    }
  }

  Future<void> _runPlanMode(String text) async {
    final taskId = ref.read(activeAgentTaskIdProvider);
    final store = ref.read(agentTaskStoreProvider);
    if (taskId != null) {
      store.update(taskId, status: AgentTaskStatus.planning, clearError: true);
      store.addEvent(taskId, kind: 'planning', title: 'Workspace inceleniyor ve plan oluşturuluyor');
      ref.read(agentTaskVersionProvider.notifier).state++;
    }
    final providerManager = ref.read(providerManagerProvider);
    final ai = providerManager;
    final workspace = ref.read(workspaceServiceProvider);
    final backend = ref.read(backendServiceProvider);
    var userContent = _buildAgentPrompt(text);
    final memory = await _memoryContext(text, workspace.rootPath);
    if (!mounted) return;
    if (memory.isNotEmpty) {
      userContent +=
          '\n\n--- Hiide reference memory (untrusted context) ---\n' +
          memory +
          '\n--- End reference memory ---';
    }
    final skillContext = await const HiideSkillRegistry().contextFor(
      workspace.rootPath,
      text,
      maxSkills: 3,
      maxChars: 9000,
    );
    if (!mounted) return;
    if (skillContext.isNotEmpty) {
      userContent += '\n\n' + skillContext;
    }
    final planner = PlanningAgent(ai: ai, backend: backend, workspaceRoot: workspace.rootPath);
    _stopActiveAgent = planner.stop;
    String? createdPlan;
    final history = _boundedAgentMessages([
      ...ref.read(agentMessagesProvider),
      {'role': 'user', 'content': userContent},
    ]);

    await for (final event in planner.run(userContent)) {
      if (!mounted) break;
      switch (event) {
        case PlanCreatedEvent(:final steps, :final document):
          if (taskId != null) {
            store.update(taskId, status: AgentTaskStatus.planning, plan: document.toMarkdown());
            store.addArtifact(
              taskId,
              AgentArtifact(
                id: 'artifact_plan_' + DateTime.now().microsecondsSinceEpoch.toString(),
                type: AgentArtifactType.plan,
                title: document.title.isEmpty ? 'Implementation plan' : document.title,
                content: document.toMarkdown(),
                createdAt: DateTime.now(),
              ),
            );
            store.addEvent(
              taskId,
              kind: 'plan',
              title: 'Plan oluşturuldu',
              detail: steps.length.toString() + ' adım',
            );
            ref.read(agentTaskVersionProvider.notifier).state++;
          }
          _addMessage(ChatMessage(
            role: ChatRole.system,
            content: 'Plan hazırlandı: ' + steps.length.toString() +
                ' bağımlı adım. Plan modu hiçbir dosyayı değiştirmez.',
            timestamp: DateTime.now(),
          ));
        case PlanStepStartedEvent(:final step):
          if (taskId != null) {
            store.addEvent(taskId, kind: 'plan.step', title: step.title, detail: 'Adım başladı');
            ref.read(agentTaskVersionProvider.notifier).state++;
          }
        case PlanStepCompletedEvent(:final step):
          if (taskId != null) {
            store.addEvent(taskId, kind: 'plan.step', title: step.title, detail: step.result ?? 'Adım tamamlandı', success: step.error == null);
            ref.read(agentTaskVersionProvider.notifier).state++;
          }
        case PlanStoppedEvent():
          _finishStreamingText();
          ref.read(streamingMessageProvider.notifier).state = '';
          if (taskId != null) {
            store.update(
              taskId,
              status: AgentTaskStatus.canceled,
              summary: 'Planlama kullanıcı tarafından durduruldu.',
            );
            store.addEvent(
              taskId,
              kind: 'canceled',
              title: 'Planlama durduruldu',
              detail: 'Kullanıcı durdurdu.',
              success: false,
            );
            ref.read(agentTaskVersionProvider.notifier).state++;
          }
          _addMessage(
            ChatMessage(
              role: ChatRole.system,
              content: 'Planlama kullanıcı tarafından durduruldu.',
              timestamp: DateTime.now(),
            ),
          );
        case PlanTextTokenEvent(:final token):
          _queueStreamingToken(token);
        case PlanDoneEvent(:final summary, :final document):
          _finishStreamingText();
          ref.read(streamingMessageProvider.notifier).state = '';
          createdPlan = summary;
          ref.read(lastPlanProvider.notifier).state = document.toMarkdown();
          unawaited(
            aiMemoryStore
                .storeConversationSummary(
                  workspaceRoot: workspace.rootPath,
                  summary: summary,
                  topics: _memoryKeywords(text),
                )
                .catchError((_) {}),
          );
          if (taskId != null) {
            store.update(taskId, status: AgentTaskStatus.succeeded, summary: summary, plan: document.toMarkdown());
            store.addArtifact(
              taskId,
              AgentArtifact(
                id: 'artifact_plan_final_' + DateTime.now().microsecondsSinceEpoch.toString(),
                type: AgentArtifactType.report,
                title: 'Plan result',
                content: summary,
                createdAt: DateTime.now(),
              ),
            );
            store.addEvent(taskId, kind: 'completed', title: 'Plan hazır ve doğrulandı');
            ref.read(agentTaskVersionProvider.notifier).state++;
          }
          _addMessage(ChatMessage(role: ChatRole.assistant, content: summary, timestamp: DateTime.now()));
        case PlanErrorEvent(:final message):
          _finishStreamingText();
          ref.read(streamingMessageProvider.notifier).state = '';
          if (taskId != null) {
            store.update(taskId, status: AgentTaskStatus.failed, error: message);
            store.addEvent(taskId, kind: 'error', title: 'Plan oluşturulamadı', detail: message, success: false);
            ref.read(agentTaskVersionProvider.notifier).state++;
          }
          _addMessage(ChatMessage(role: ChatRole.error, content: 'Plan oluşturulamadı: ' + message, timestamp: DateTime.now()));
      }
    }

    if (!mounted) return;
    final plan = createdPlan;
    final planHistory = _boundedAgentMessages([
      ...history,
      if (plan != null && plan.trim().isNotEmpty)
        {'role': 'assistant', 'content': plan},
    ]);
    ref.read(agentMessagesProvider.notifier).state = planHistory;
    if (taskId != null) {
      store.replaceTranscript(taskId, planHistory);
      ref.read(agentTaskVersionProvider.notifier).state++;
    }
  }

  Future<void> _runCodeMode(String text) async {
    final taskId = ref.read(activeAgentTaskIdProvider);
    if (taskId == null) return;

    final store = ref.read(agentTaskStoreProvider);
    final providerManager = ref.read(providerManagerProvider);
    final workspace = ref.read(workspaceServiceProvider);

    var userContent = _buildAgentPrompt(text);
    final memory = await _memoryContext(text, workspace.rootPath);
    if (!mounted) return;
    if (memory.isNotEmpty) {
      userContent +=
          '\n\n--- Hiide reference memory (untrusted context) ---\n' +
          memory +
          '\n--- End reference memory ---';
    }

    final lastPlan = ref.read(lastPlanProvider);
    if (lastPlan != null &&
        lastPlan.trim().isNotEmpty &&
        _looksLikePlanExecutionRequest(text)) {
      userContent +=
          '\n\n--- Latest Hiide Plan ---\n' +
          lastPlan +
          '\n--- End Latest Hiide Plan ---';
    }

    final skillContext = await const HiideSkillRegistry().contextFor(
      workspace.rootPath,
      text,
      maxSkills: 3,
      maxChars: 9000,
    );
    if (!mounted) return;
    if (skillContext.isNotEmpty) {
      userContent += '\n\n' + skillContext;
    }

    final history = <Map<String, dynamic>>[
      ...ref.read(agentMessagesProvider),
      {'role': 'user', 'content': userContent},
    ];

    final manager = ref.read(agentRunManagerProvider);
    final handle = await manager.startBuild(
      taskId: taskId,
      objective: text,
      history: history,
      workspaceRoot: workspace.rootPath,
      model: providerManager.activeModel,
      profile: AgentProfile.build,
    );
    _stopActiveAgent = handle.stop;

    await for (final event in handle.events) {
      if (!mounted) break;

      switch (event) {
        case AgentTextTokenEvent(:final token):
          _queueStreamingToken(token);
        case AgentToolStartedEvent(:final toolCall):
          _addToolBubble(toolCall);
        case AgentToolFinishedEvent(:final toolCall):
          _updateToolBubble(toolCall);
          ref.invalidate(fileTreeProvider);
          final changedPath = toolCall.arguments['path']?.toString();
          if (changedPath != null && changedPath.isNotEmpty) {
            ref.read(selectedWorkspacePathProvider.notifier).state =
                changedPath;
          }
          if (toolCall.name == 'run_command') {
            final command = toolCall.arguments['command']?.toString() ?? '';
            if (command.isNotEmpty) {
              ref.read(terminalServiceProvider).logAgentRun(
                    command,
                    toolCall.result ?? '',
                  );
            }
          }
        case AgentDoneEvent(:final text):
          _finishStreamingText();
          ref.read(streamingMessageProvider.notifier).state = '';
          if (text.trim().isNotEmpty) {
            _addMessage(
              ChatMessage(
                role: ChatRole.assistant,
                content: text,
                timestamp: DateTime.now(),
              ),
            );
          }
        case AgentErrorEvent(:final message):
          _finishStreamingText();
          ref.read(streamingMessageProvider.notifier).state = '';
          _addMessage(
            ChatMessage(
              role: ChatRole.error,
              content: 'Error: ' + message,
              timestamp: DateTime.now(),
            ),
          );
        case AgentStoppedEvent():
          _finishStreamingText();
          ref.read(streamingMessageProvider.notifier).state = '';
          _addMessage(
            ChatMessage(
              role: ChatRole.system,
              content: '⏹ Stopped by user.',
              timestamp: DateTime.now(),
            ),
          );
        case AgentIterationLimitEvent(
            :final iterations,
            :final reason,
          ):
          _finishStreamingText();
          ref.read(streamingMessageProvider.notifier).state = '';
          _addMessage(
            ChatMessage(
              role: ChatRole.error,
              content:
                  reason + ' (iteration ' + iterations.toString() + ').',
              timestamp: DateTime.now(),
            ),
          );
      }
    }

    final saved = store.byId(taskId);
    if (mounted && saved != null) {
      ref.read(agentMessagesProvider.notifier).state =
          _boundedAgentMessages(saved.transcript);
    }
  }



  bool _looksLikePlanExecutionRequest(String text) {
    final lower = text.toLowerCase();
    const markers = <String>[
      'planı uygula', 'plani uygula', 'planı gerçekleştir', 'plani gerceklestir',
      'execute plan', 'apply plan', 'implement plan', 'do the plan',
      'uygula', 'gerçekleştir', 'gerceklestir',
    ];
    return markers.any(lower.contains);
  }
  Future<void> _showAgentApprovalRequest(
    AgentApprovalRequest request,
  ) async {
    if (!mounted) return;

    final manager = ref.read(agentRunManagerProvider);
    final command = request.arguments['command']?.toString() ?? '';
    final detail = command.isNotEmpty
        ? command
        : request.arguments['path']?.toString() ?? request.toolName;

    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final cs = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          title: const Text('Agent approval required'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The agent requested a protected operation.',
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  detail,
                  style: const TextStyle(
                    fontFamily: 'JetBrains Mono',
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'This decision applies only to this exact request.',
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Reject'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Approve'),
            ),
          ],
        );
      },
    );

    await manager.resolveApproval(request.id, approved == true);
  }

  void _stopAgent() {
    _stopActiveAgent?.call();
  }

  // ─── Tool call bubbles ────────────────────────────────────────────────────

  void _addToolBubble(AgentToolCall call) {
    _addMessage(ChatMessage(
      role: ChatRole.tool,
      content: '',
      timestamp: DateTime.now(),
      toolCall: ToolCallInfo(
        id: call.id,
        toolName: call.name,
        arguments: call.arguments,
        isRunning: true,
      ),
    ));
  }

  void _updateToolBubble(AgentToolCall call) {
    final messages = ref.read(chatMessagesProvider);
    final index = messages.indexWhere(
        (m) => m.role == ChatRole.tool && m.toolCall?.id == call.id);
    if (index < 0) return;
    final updated = messages[index].copyWith(
      toolCall: messages[index].toolCall!.copyWith(
            result: call.result,
            isRunning: false,
            isError: call.status == AgentToolStatus.error,
          ),
    );
    ref.read(chatMessagesProvider.notifier).state =
        List<ChatMessage>.from(messages)..[index] = updated;
    _scrollToBottom();
  }

  void _clearChat() {
    ref.read(chatMessagesProvider.notifier).state = [];
    ref.read(agentMessagesProvider.notifier).state = [];
    _resetStreamingText();
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(chatMessagesProvider);
    final isThinking = ref.watch(isAiThinkingProvider);
    final streamingText = ref.watch(streamingMessageProvider);
    final agentMode = ref.watch(agentModeProvider);
    final lastPlan = ref.watch(lastPlanProvider);
    final cs = Theme.of(context).colorScheme;

    // Editor "Ask AI" actions inject a one-shot prompt here.
    ref.listen<String?>(aiPromptProvider, (prev, next) {
      if (next == null || next.isEmpty) return;
      ref.read(aiPromptProvider.notifier).state = null;
      if (mounted) _sendMessage(next);
    });

    final providerManager = ref.watch(providerManagerProvider);
    final modelLabel = providerManager.active.displayName +
        ' · ' + providerManager.activeModel;
    final providerKey = ref.read(aiProviderKeysProvider)[providerManager.active.id] ?? '';
    final providerConfigured = !providerManager.active.requiresApiKey ||
        providerKey.trim().isNotEmpty;
    final statusLabel = providerConfigured ? 'Ready' : 'API key required';
    final dotColor = !providerConfigured
        ? cs.error
        : isThinking
            ? cs.primary
            : cs.tertiary;

    return Container(
      color: cs.surface,
      child: Column(
        children: [
          // ─── Header ────────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: DesignTokens.space4, vertical: DesignTokens.space3),
            decoration: BoxDecoration(
              border: Border(
                  bottom: BorderSide(
                      color: cs.outlineVariant,
                      width: DesignTokens.borderWidthThin)),
            ),
            child: Row(
              children: [
                const AiOrb(
                  icon: Icons.auto_awesome,
                  size: DesignTokens.space7,
                  iconSize: DesignTokens.iconMD,
                ),
                const SizedBox(width: DesignTokens.space2),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Hiide AI',
                        style: TextStyle(
                          color: cs.onSurface,
                          fontSize: DesignTokens.fontSizeMD,
                          fontWeight: DesignTokens.fontWeightSemibold,
                        ),
                      ),
                      Text(
                        '$modelLabel · $statusLabel',
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: DesignTokens.fontSizeXS,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                if (isThinking) ...[
                  // Stop button
                  IconButton(
                    icon: const Icon(Icons.stop_circle_outlined,
                        size: DesignTokens.iconSM),
                    color: cs.error,
                    onPressed: _stopAgent,
                    tooltip: 'Stop agent',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 24, minHeight: 24),
                  ),
                  const SizedBox(width: DesignTokens.space2),
                ],
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 4),
                Text(statusLabel,
                    style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: DesignTokens.fontSizeXS)),
                const SizedBox(width: DesignTokens.space2),
                IconButton(
                  icon: Icon(Icons.delete_outline,
                      size: DesignTokens.iconSM, color: cs.onSurfaceVariant),
                  onPressed: isThinking ? null : _clearChat,
                  tooltip: 'Clear chat',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 24, minHeight: 24),
                ),
              ],
            ),
          ),

          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(
              color: cs.surfaceContainerLow,
              border: Border(bottom: BorderSide(color: cs.outlineVariant)),
            ),
            child: SegmentedButton<AgentMode>(
              segments: AgentMode.values.map((mode) => ButtonSegment<AgentMode>(
                value: mode, icon: Icon(mode.icon, size: 16), label: Text(mode.label),
              )).toList(),
              selected: {agentMode},
              onSelectionChanged: isThinking ? null : (selection) {
                if (selection.isNotEmpty) ref.read(agentModeProvider.notifier).state = selection.first;
              },
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(children: [
              Icon(agentMode.icon, size: 16, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(agentMode.description, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: DesignTokens.fontSizeXS))),
            ]),
          ),

          if (!providerConfigured && !isThinking)
            _OfflineBanner(
              message: 'Configure an API key for ${providerManager.active.displayName} in Settings.',
              onRetry: () => setState(() {}),
            ),

          // ─── Messages (or welcome panel on first run) ─────────────────────
          Expanded(
            child: messages.isEmpty && streamingText.isEmpty
                ? _WelcomePanel(onPrompt: _sendMessage)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(DesignTokens.space3),
                    itemCount:
                        messages.length + (streamingText.isNotEmpty ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == messages.length &&
                          streamingText.isNotEmpty) {
                        return _StreamingBubble(text: streamingText);
                      }
                      return _ChatBubble(message: messages[index]);
                    },
                  ),
          ),

          // ─── AI Thinking Indicator ─────────────────────────────────────────
          if (isThinking && streamingText.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: DesignTokens.space4,
                  vertical: DesignTokens.space2),
              child: Row(
                children: [
                  const _ThinkingDots(),
                  const SizedBox(width: DesignTokens.space2),
                  Text(
                    'Agent is working...',
                    style: TextStyle(
                        color: cs.primary, fontSize: DesignTokens.fontSizeXS),
                  ),
                ],
              ),
            ),

          if (!isThinking && agentMode == AgentMode.code && lastPlan != null && lastPlan.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _sendMessage('Son oluşturulan planı uygula ve doğrula.'),
                  icon: const Icon(Icons.play_arrow_rounded, size: 16),
                  label: const Text('Son planı uygula'),
                ),
              ),
            ),

          // ─── Input Bar ────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(DesignTokens.space3),
            decoration: BoxDecoration(
              border: Border(
                  top: BorderSide(
                      color: cs.outlineVariant,
                      width: DesignTokens.borderWidthThin)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius:
                          BorderRadius.circular(DesignTokens.radiusMD),
                      border: Border.all(color: cs.outlineVariant),
                    ),
                    child: TextField(
                      controller: _inputController,
                      maxLines: 4,
                      minLines: 1,
                      style: TextStyle(
                          color: cs.onSurface,
                          fontSize: DesignTokens.fontSizeMD),
                      decoration: InputDecoration(
                        hintText: agentMode == AgentMode.plan
    ? 'Plan modu: kapsamı, adımları, riskleri ve doğrulamayı çıkar…'
    : 'Code modu: geliştir, düzelt, test et veya planı uygula…',
                        hintStyle: TextStyle(color: cs.onSurfaceVariant),
                        border: InputBorder.none,
                        contentPadding:
                            const EdgeInsets.all(DesignTokens.space3),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                ),
                const SizedBox(width: DesignTokens.space2),
                AnimatedContainer(
                  duration: DesignTokens.durationFast,
                  child: IconButton.filled(
                    onPressed: isThinking ? null : _sendMessage,
                    icon: isThinking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send, size: DesignTokens.iconSM),
                    tooltip: 'Send (Enter)',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Offline banner ───────────────────────────────────────────────────────────

class _OfflineBanner extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _OfflineBanner({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final short =
        message.length > 100 ? '${message.substring(0, 100)}…' : message;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
          DesignTokens.space3, DesignTokens.space2, DesignTokens.space3, 0),
      padding: const EdgeInsets.symmetric(
          horizontal: DesignTokens.space3, vertical: DesignTokens.space1),
      decoration: BoxDecoration(
        color: cs.errorContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(DesignTokens.radiusMD),
        border: Border.all(color: cs.error.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: DesignTokens.iconXS, color: cs.error),
          const SizedBox(width: DesignTokens.space2),
          Expanded(
            child: Text(
              'AI provider unavailable: $short',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.onErrorContainer,
                fontSize: DesignTokens.fontSizeXS,
              ),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding:
                  const EdgeInsets.symmetric(horizontal: DesignTokens.space2),
            ),
            child: Text('Retry',
                style: TextStyle(
                    color: cs.error, fontSize: DesignTokens.fontSizeXS)),
          ),
        ],
      ),
    );
  }
}

// ─── Welcome panel (empty chat) ───────────────────────────────────────────────

class _WelcomePanel extends StatelessWidget {
  const _WelcomePanel({required this.onPrompt});

  final void Function(String prompt) onPrompt;

  static const List<(String, String)> _suggestions = [
    (
      'Explain the active file',
      'Explain what the active file does, its structure and how it fits the project.'
    ),
    (
      'Find and fix bugs',
      'Carefully review the active file for bugs and real issues. Fix them with apply_diff, then verify with a build or test command.'
    ),
    (
      'Write tests',
      'Write unit tests for the active file following the project conventions, then run them and report the results.'
    ),
    (
      'Optimize performance',
      'Review the active file for performance issues and apply concrete, verifiable optimizations.'
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(DesignTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: DesignTokens.space2),
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [cs.primary, cs.tertiary],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(DesignTokens.radiusXL),
            ),
            child: const Icon(Icons.auto_awesome,
                color: Colors.white, size: DesignTokens.iconLG),
          ),
          const SizedBox(height: DesignTokens.space3),
          Text(
            'Hiide AI',
            style: TextStyle(
              color: cs.onSurface,
              fontSize: DesignTokens.fontSize2XL,
              fontWeight: DesignTokens.fontWeightSemibold,
            ),
          ),
          const SizedBox(height: DesignTokens.space1),
          Text(
            'Build, fix or explain — the agent reads your files, edits them '
            'and runs commands in the workspace.',
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: DesignTokens.fontSizeMD,
              height: DesignTokens.lineHeightNormal,
            ),
          ),
          const SizedBox(height: DesignTokens.space5),
          Text(
            'Try asking',
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: DesignTokens.fontSizeXS,
              fontWeight: DesignTokens.fontWeightSemibold,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: DesignTokens.space2),
          Wrap(
            spacing: DesignTokens.space2,
            runSpacing: DesignTokens.space2,
            children: [
              for (final (label, prompt) in _suggestions)
                ActionChip(
                  label: Text(
                    label,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: DesignTokens.fontSizeSM,
                    ),
                  ),
                  avatar: Icon(Icons.auto_awesome,
                      size: DesignTokens.iconXS, color: cs.primary),
                  backgroundColor: cs.primary.withValues(alpha: 0.08),
                  side: BorderSide(color: cs.outlineVariant),
                  onPressed: () => onPrompt(prompt),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Streaming bubble ─────────────────────────────────────────────────────────

class _StreamingBubble extends StatelessWidget {
  final String text;
  const _StreamingBubble({required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: DesignTokens.space1),
        padding: const EdgeInsets.all(DesignTokens.space3),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(DesignTokens.radiusLG),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SelectableText(
                text,
                style: TextStyle(
                    color: cs.onSurface,
                    fontSize: DesignTokens.fontSizeMD,
                    height: 1.5),
              ),
            ),
            const SizedBox(width: 4),
            _BlinkingCursor(),
          ],
        ),
      ),
    );
  }
}

class _BlinkingCursor extends StatefulWidget {
  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _ctrl,
      child: Container(
        width: 2,
        height: 16,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

// ─── Thinking dots animation ──────────────────────────────────────────────────

class _ThinkingDots extends StatefulWidget {
  const _ThinkingDots();

  @override
  State<_ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<_ThinkingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final step = (_ctrl.value * 3).floor();
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: i <= step ? color : color.withValues(alpha: 0.3),
                shape: BoxShape.circle,
              ),
            );
          }),
        );
      },
    );
  }
}

// ─── Chat Bubble ─────────────────────────────────────────────────────────────

class _ChatBubble extends StatelessWidget {
  final ChatMessage message;
  const _ChatBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isUser = message.role == ChatRole.user;
    final isTool = message.role == ChatRole.tool;
    final isError = message.role == ChatRole.error;
    final isSystem = message.role == ChatRole.system;

    // Tool call result bubble
    if (isTool && message.toolCall != null) {
      final info = message.toolCall!;
      return _ToolBubble(info: info, cs: cs);
    }

    // System / informational bubble (e.g. "Stopped by user")
    if (isSystem) {
      return Align(
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: DesignTokens.space1),
          child: Text(
            message.content,
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: DesignTokens.fontSizeXS,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      );
    }

    final bubbleColor = isUser
        ? cs.primaryContainer
        : isError
            ? cs.errorContainer
            : cs.surfaceContainerHighest;

    final textColor = isUser
        ? cs.onPrimaryContainer
        : isError
            ? cs.onErrorContainer
            : cs.onSurface;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: DesignTokens.space1),
        constraints: const BoxConstraints(maxWidth: 280),
        padding: const EdgeInsets.all(DesignTokens.space3),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.circular(DesignTokens.radiusLG),
        ),
        child: SelectableText(
          message.content,
          style: TextStyle(
            color: textColor,
            fontSize: DesignTokens.fontSizeMD,
            height: 1.5,
          ),
        ),
      ),
    );
  }
}

/// A tool invocation card: shows a live spinner while running, then the
/// result with success/error styling.
class _ToolBubble extends StatelessWidget {
  final ToolCallInfo info;
  final ColorScheme cs;

  const _ToolBubble({required this.info, required this.cs});

  @override
  Widget build(BuildContext context) {
    final running = info.isRunning;
    final failed = info.isError;

    final (icon, iconColor) = running
        ? (Icons.hourglass_top, cs.primary)
        : failed
            ? (Icons.error_outline, cs.error)
            : (Icons.check_circle_outline, const Color(0xFF3FB950));

    return Container(
      margin: const EdgeInsets.symmetric(vertical: DesignTokens.space1),
      padding: const EdgeInsets.all(DesignTokens.space2),
      decoration: BoxDecoration(
        color: cs.secondaryContainer.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(DesignTokens.radiusMD),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (running)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(icon, size: DesignTokens.iconXS, color: iconColor),
              const SizedBox(width: DesignTokens.space1),
              Expanded(
                child: Text(
                  '⚙ ${info.toolName}',
                  style: TextStyle(
                    color: cs.secondary,
                    fontWeight: FontWeight.bold,
                    fontSize: DesignTokens.fontSizeXS,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (info.result != null && info.result!.isNotEmpty) ...[
            const SizedBox(height: DesignTokens.space1),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 160),
              padding: const EdgeInsets.all(DesignTokens.space2),
              decoration: BoxDecoration(
                color: cs.surface.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(DesignTokens.radiusSM),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  info.result!,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontFamily: 'JetBrains Mono',
                    fontSize: DesignTokens.fontSizeXS,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
