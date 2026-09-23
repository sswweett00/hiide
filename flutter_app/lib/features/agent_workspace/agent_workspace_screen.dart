import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/backend/agent_mode.dart';
import '../../core/backend/agent_task_store.dart';
import '../../core/design_system/tokens.dart';
import '../../shared/models/chat_message.dart';
import '../../shared/providers/editor_providers.dart';
import '../../shared/widgets/ai_widgets.dart';
import 'ai_chat_sidebar.dart';

class AgentWorkspaceScreen extends ConsumerWidget {
  const AgentWorkspaceScreen({super.key});

  void _newTask(WidgetRef ref) {
    ref.read(chatMessagesProvider.notifier).state = [];
    ref.read(agentMessagesProvider.notifier).state = [];
    ref.read(streamingMessageProvider.notifier).state = '';
    ref.read(lastPlanProvider.notifier).state = null;
    ref.read(activeAgentTaskIdProvider.notifier).state = null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final workspace = ref.watch(workspaceRootProvider);
    final mode = ref.watch(agentModeProvider);
    final messages = ref.watch(chatMessagesProvider);
    final isThinking = ref.watch(isAiThinkingProvider);
    final lastPlan = ref.watch(lastPlanProvider);
    ref.watch(agentTaskVersionProvider);
    final taskStore = ref.watch(agentTaskStoreProvider);
    final activeTaskId = ref.watch(activeAgentTaskIdProvider);
    final activeTask = activeTaskId == null ? null : taskStore.byId(activeTaskId);

    final userTasks = taskStore.tasks.take(12).toList();
    final toolCount = messages.where((m) => m.role == ChatRole.tool).length;
    final completedAssistant =
        messages.where((m) => m.role == ChatRole.assistant).length;

    return Scaffold(
      backgroundColor: cs.surface,
      body: SafeArea(
        child: Column(
          children: [
            _AgentTopBar(
              workspace: workspace,
              isThinking: isThinking,
              onNewTask: () => _newTask(ref),
              onOpenEditor: () => context.go('/editor'),
              onWorkspace: () => context.go('/workspace-picker'),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 1080;
                  final minimal = constraints.maxWidth < 820;
                  return Row(
                    children: [
                      if (!minimal) ...[
                        SizedBox(
                          width: compact ? 210 : 250,
                          child: _MissionRail(
                            mode: mode,
                            isThinking: isThinking,
                            tasks: userTasks,
                            activeTaskId: activeTaskId,
                            toolCount: toolCount,
                            completedAssistant: completedAssistant,
                            onSelect: (task) => _selectTask(ref, task),
                          ),
                        ),
                        const VerticalDivider(width: 1),
                      ],
                      const Expanded(
                        child: Padding(
                          padding: EdgeInsets.all(10),
                          child: AiChatSidebar(),
                        ),
                      ),
                      if (!compact) ...[
                        const VerticalDivider(width: 1),
                        SizedBox(
                          width: 300,
                          child: _AgentContextRail(
                            mode: mode,
                            workspace: workspace,
                            isThinking: isThinking,
                            lastPlan: lastPlan,
                            activeTab: _activeTab(ref),
                            toolCount: toolCount,
                            task: activeTask,
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _selectTask(WidgetRef ref, AgentTaskRecord task) {
    ref.read(activeAgentTaskIdProvider.notifier).state = task.id;
    ref.read(lastPlanProvider.notifier).state = task.plan;
    final restored = <ChatMessage>[];
    for (final message in task.transcript) {
      final role = message['role']?.toString();
      final content = message['content']?.toString() ?? '';
      if (content.isEmpty) continue;
      final chatRole = switch (role) {
        'user' => ChatRole.user,
        'assistant' => ChatRole.assistant,
        'tool' => ChatRole.tool,
        'system' => ChatRole.system,
        _ => ChatRole.system,
      };
      restored.add(ChatMessage(role: chatRole, content: content, timestamp: DateTime.now()));
    }
    if (restored.isEmpty) {
      restored.add(ChatMessage(
        role: ChatRole.system,
        content: task.summary ?? 'Bu görev için henüz konuşma kaydı yok.',
        timestamp: DateTime.now(),
      ));
    }
    ref.read(chatMessagesProvider.notifier).state = restored;
    ref.read(agentMessagesProvider.notifier).state = List<Map<String, dynamic>>.from(task.transcript);
    ref.read(streamingMessageProvider.notifier).state = '';
  }

  EditorTabView? _activeTab(WidgetRef ref) {
    final id = ref.read(activeTabIdProvider);
    final tabs = ref.read(openTabsProvider);
    if (id == null || tabs.isEmpty) return null;
    final tab = tabs.firstWhere(
      (t) => t.id == id,
      orElse: () => tabs.first,
    );
    return EditorTabView(path: tab.path ?? tab.title);
  }
}

class EditorTabView {
  final String path;
  const EditorTabView({required this.path});
}

class _AgentTopBar extends StatelessWidget {
  final String workspace;
  final bool isThinking;
  final VoidCallback onNewTask;
  final VoidCallback onOpenEditor;
  final VoidCallback onWorkspace;

  const _AgentTopBar({
    required this.workspace,
    required this.isThinking,
    required this.onNewTask,
    required this.onOpenEditor,
    required this.onWorkspace,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: cs.outlineVariant)),
      ),
      child: Row(
        children: [
          const AiOrb(icon: Icons.auto_awesome, size: 34, iconSize: 18),
          const SizedBox(width: 12),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Hiide Agent Workspace',
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(
                width: 420,
                child: Text(
                  workspace,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
                ),
              ),
            ],
          ),
          const Spacer(),
          if (isThinking)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
                  ),
                  const SizedBox(width: 7),
                  Text('Agent çalışıyor', style: TextStyle(color: cs.primary, fontSize: 12)),
                ],
              ),
            ),
          IconButton(
            onPressed: onWorkspace,
            icon: const Icon(Icons.folder_open_rounded, size: 19),
            tooltip: 'Çalışma alanını değiştir',
          ),
          IconButton(
            onPressed: onOpenEditor,
            icon: const Icon(Icons.code_rounded, size: 19),
            tooltip: 'Kod yüzeyini aç',
          ),
          const SizedBox(width: 5),
          FilledButton.icon(
            onPressed: isThinking ? null : onNewTask,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Yeni görev'),
          ),
        ],
      ),
    );
  }
}

class _MissionRail extends StatelessWidget {
  final AgentMode mode;
  final bool isThinking;
  final List<AgentTaskRecord> tasks;
  final String? activeTaskId;
  final int toolCount;
  final int completedAssistant;
  final ValueChanged<AgentTaskRecord> onSelect;

  const _MissionRail({
    required this.mode,
    required this.isThinking,
    required this.tasks,
    required this.activeTaskId,
    required this.toolCount,
    required this.completedAssistant,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.surfaceContainerLowest,
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('MISSIONS', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1)),
          const SizedBox(height: 10),
          AiGlowCard(
            wash: false,
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(mode.icon, size: 18, color: cs.primary),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Active mode', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10)),
                      Text(mode.label, style: TextStyle(color: cs.onSurface, fontSize: 14, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
                if (isThinking) const _PulseDot(),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _Metric(label: 'Tools', value: toolCount.toString())),
              const SizedBox(width: 8),
              Expanded(child: _Metric(label: 'Replies', value: completedAssistant.toString())),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(child: Text('RECENT TASKS', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1))),
              Text(tasks.length.toString(), style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10)),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: tasks.isEmpty
                ? Center(
                    child: Text(
                      'Henüz görev yok.\nBir hedef ver ve agent\nçalışmaya başlasın.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12, height: 1.5),
                    ),
                  )
                : ListView.separated(
                    itemCount: tasks.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final task = tasks[index];
                      final selected = task.id == activeTaskId;
                      return InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => onSelect(task),
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: selected ? cs.primaryContainer.withValues(alpha: 0.45) : cs.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: selected ? cs.primary : cs.outlineVariant),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(_taskIcon(task.status), size: 15, color: _taskColor(context, task.status)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      task.objective.replaceAll('\n', ' '),
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(color: cs.onSurface, fontSize: 11.5, height: 1.35),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      task.status.label + ' · ' + _relativeTaskTime(task.updatedAt),
                                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 9.5),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  static IconData _taskIcon(AgentTaskStatus status) => switch (status) {
        AgentTaskStatus.queued => Icons.schedule_rounded,
        AgentTaskStatus.planning => Icons.account_tree_outlined,
        AgentTaskStatus.executing => Icons.bolt_rounded,
        AgentTaskStatus.verifying => Icons.fact_check_outlined,
        AgentTaskStatus.waitingApproval => Icons.pan_tool_outlined,
        AgentTaskStatus.succeeded => Icons.check_circle_outline,
        AgentTaskStatus.failed => Icons.error_outline,
        AgentTaskStatus.canceled => Icons.stop_circle_outlined,
      };

  static Color _taskColor(BuildContext context, AgentTaskStatus status) {
    final cs = Theme.of(context).colorScheme;
    return switch (status) {
      AgentTaskStatus.succeeded => cs.primary,
      AgentTaskStatus.failed => cs.error,
      AgentTaskStatus.canceled => cs.onSurfaceVariant,
      _ => cs.primary,
    };
  }

  static String _relativeTaskTime(DateTime value) {
    final delta = DateTime.now().difference(value);
    if (delta.inSeconds < 60) return 'now';
    if (delta.inMinutes < 60) return delta.inMinutes.toString() + 'm';
    if (delta.inHours < 24) return delta.inHours.toString() + 'h';
    return delta.inDays.toString() + 'd';
  }
}

class _AgentContextRail extends StatelessWidget {
  final AgentMode mode;
  final String workspace;
  final bool isThinking;
  final String? lastPlan;
  final EditorTabView? activeTab;
  final int toolCount;
  final AgentTaskRecord? task;

  const _AgentContextRail({
    required this.mode,
    required this.workspace,
    required this.isThinking,
    required this.lastPlan,
    required this.activeTab,
    required this.toolCount,
    required this.task,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final current = task;
    return Container(
      color: cs.surfaceContainerLowest,
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
      child: ListView(
        children: [
          Text('AGENT CONTEXT', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1)),
          const SizedBox(height: 10),
          _InfoCard(icon: Icons.folder_copy_outlined, title: 'Workspace', value: workspace),
          const SizedBox(height: 8),
          _InfoCard(icon: mode.icon, title: 'Mode', value: mode.label + (isThinking ? ' · working' : ' · ready')),
          const SizedBox(height: 8),
          _InfoCard(icon: Icons.description_outlined, title: 'Active file', value: activeTab?.path ?? 'No file selected'),
          const SizedBox(height: 8),
          _InfoCard(icon: Icons.flag_outlined, title: 'Task status', value: current?.status.label ?? 'No task selected'),
          const SizedBox(height: 8),
          _InfoCard(icon: Icons.build_circle_outlined, title: 'Tool activity', value: (current?.toolCalls ?? toolCount).toString() + ' calls'),
          if (current != null) ...[
            const SizedBox(height: 16),
            Text('OBJECTIVE', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1)),
            const SizedBox(height: 8),
            _InfoCard(icon: Icons.track_changes, title: 'Goal', value: current.objective),
            const SizedBox(height: 16),
            Text('ARTIFACTS', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1)),
            const SizedBox(height: 8),
            if (current.artifacts.isEmpty)
              Text('Henüz artifact üretilmedi.', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11))
            else
              ...current.artifacts.reversed.take(5).map((artifact) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: AiGlowCard(
                      wash: false,
                      padding: const EdgeInsets.all(10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(_artifactIcon(artifact.type), size: 16, color: cs.primary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(artifact.title, style: TextStyle(color: cs.onSurface, fontSize: 11.5, fontWeight: FontWeight.w700)),
                                const SizedBox(height: 3),
                                Text(artifact.content.replaceAll('\n', ' '), maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10.5, height: 1.4)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  )),
            const SizedBox(height: 8),
            Text('CHANGES', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1)),
            const SizedBox(height: 8),
            if (current.changedFiles.isEmpty)
              Text('Değiştirilen dosya yok.', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11))
            else
              ...current.changedFiles.take(10).map((path) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(path, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurface, fontFamily: 'JetBrains Mono', fontSize: 10)),
                  )),
            const SizedBox(height: 12),
            Text('VERIFICATION', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1)),
            const SizedBox(height: 8),
            if (current.verificationCommands.isEmpty)
              Text('Henüz doğrulama komutu kaydedilmedi.', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11))
            else
              ...current.verificationCommands.take(8).map((command) => Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text(command, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurface, fontFamily: 'JetBrains Mono', fontSize: 9.5, height: 1.35)),
                  )),
            const SizedBox(height: 14),
            Text('TIMELINE', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1)),
            const SizedBox(height: 8),
            ...current.timeline.reversed.take(8).map((event) => Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(event.success ? Icons.check_circle_outline : Icons.error_outline, size: 14, color: event.success ? cs.primary : cs.error),
                      const SizedBox(width: 7),
                      Expanded(child: Text(event.title + (event.detail.isEmpty ? '' : ' · ' + event.detail), maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 9.8, height: 1.35))),
                    ],
                  ),
                )),
          ] else ...[
            const SizedBox(height: 18),
            Text('ARTIFACTS', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1)),
            const SizedBox(height: 8),
            AiGlowCard(
              wash: false,
              padding: const EdgeInsets.all(12),
              child: Text(
                lastPlan == null ? 'Görev seçildiğinde plan, değişiklikler ve doğrulama burada görünür.' : 'Son plan hazır. Code modunda “Son planı uygula” ile yürütülebilir.',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11, height: 1.4),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static IconData _artifactIcon(AgentArtifactType type) => switch (type) {
        AgentArtifactType.plan => Icons.account_tree_outlined,
        AgentArtifactType.report => Icons.summarize_outlined,
        AgentArtifactType.verification => Icons.fact_check_outlined,
        AgentArtifactType.note => Icons.sticky_note_2_outlined,
      };
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  const _InfoCard({required this.icon, required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 9.5)),
                const SizedBox(height: 2),
                Text(value, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurface, fontSize: 11.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  const _Metric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 9)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(color: cs.onSurface, fontSize: 15, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _PulseDot extends StatelessWidget {
  const _PulseDot();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
    );
  }
}