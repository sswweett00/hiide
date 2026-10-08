import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/backend/agent_task_store.dart';
import '../../core/design_system/tokens.dart';
import '../../shared/providers/workspace_providers.dart';
import '../../shared/widgets/ai_widgets.dart';
import '../../shared/widgets/ide_shell.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(agentTaskVersionProvider);
    final store = ref.watch(agentTaskStoreProvider);
    final tasks = store.tasks;
    final workspace = ref.watch(workspaceRootProvider);
    final running = tasks.where((task) => !task.status.terminal).length;
    final succeeded = tasks.where((task) =>
        task.status == AgentTaskStatus.succeeded ||
        task.status == AgentTaskStatus.succeededWithWarnings).length;
    final failed = tasks.where((task) => task.status == AgentTaskStatus.failed).length;
    final changedFiles = tasks.expand((task) => task.changedFiles).toSet().take(12).toList();

    return IdeShell(
      showAiSidebar: true,
      child: Container(
        color: Theme.of(context).colorScheme.surface,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            AiPageHeader(
              icon: Icons.dashboard_outlined,
              title: 'Dashboard',
              actions: [
                FilledButton.icon(
                  onPressed: () => context.go('/agent'),
                  icon: const Icon(Icons.auto_awesome, size: 17),
                  label: const Text('Agent Workspace'),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AiGlowCard(
                    wash: false,
                    child: Row(
                      children: [
                        const AiOrb(icon: Icons.folder_copy_outlined, size: 42, iconSize: 21),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Active workspace', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
                              const SizedBox(height: 3),
                              Text(
                                workspace.isEmpty ? 'No workspace selected' : workspace,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 18, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                        OutlinedButton(onPressed: () => context.go('/workspace-picker'), child: const Text('Change')),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _Metric(label: 'Tasks', value: tasks.length, icon: Icons.list_alt_outlined),
                      _Metric(label: 'Running', value: running, icon: Icons.bolt_outlined),
                      _Metric(label: 'Succeeded', value: succeeded, icon: Icons.check_circle_outline),
                      _Metric(label: 'Failed', value: failed, icon: Icons.error_outline),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Text('AI WORKFLOW', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ActionChip(avatar: const Icon(Icons.auto_awesome, size: 16), label: const Text('Start a task'), onPressed: () => context.go('/agent')),
                      ActionChip(avatar: const Icon(Icons.search, size: 16), label: const Text('Search workspace'), onPressed: () => context.go('/search')),
                      ActionChip(avatar: const Icon(Icons.folder_outlined, size: 16), label: const Text('Inspect files'), onPressed: () => context.go('/explorer')),
                      ActionChip(avatar: const Icon(Icons.account_tree_outlined, size: 16), label: const Text('Review source control'), onPressed: () => context.go('/source-control')),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Text('RECENT TASKS', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1)),
                  const SizedBox(height: 8),
                  if (tasks.isEmpty)
                    const AiEmptyState(
                      icon: Icons.auto_awesome,
                      title: 'Ready for your first mission',
                      subtitle: 'Describe a goal in Agent Workspace. Hiide will inspect, change, run verification and report the result.',
                    )
                  else
                    ...tasks.take(8).map((task) => _TaskRow(task: task)),
                  if (changedFiles.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text('RECENT CHANGES', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1)),
                    const SizedBox(height: 8),
                    AiGlowCard(
                      wash: false,
                      child: Column(
                        children: changedFiles.map((path) => ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: const Icon(Icons.description_outlined), title: Text(path, maxLines: 1, overflow: TextOverflow.ellipsis))).toList(),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, required this.icon});
  final String label;
  final int value;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(width: 150, child: AiGlowCard(wash: false, child: Row(children: [Icon(icon, size: 18, color: cs.primary), const SizedBox(width: 10), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(value.toString(), style: TextStyle(color: cs.onSurface, fontSize: 20, fontWeight: FontWeight.w700)), Text(label, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11))])])));
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task});
  final AgentTaskRecord task;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = switch (task.status) {
      AgentTaskStatus.succeeded => cs.primary,
      AgentTaskStatus.succeededWithWarnings => cs.tertiary,
      AgentTaskStatus.failed => cs.error,
      AgentTaskStatus.canceled => cs.onSurfaceVariant,
      _ => cs.primary,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AiGlowCard(
        wash: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.auto_awesome, size: 17, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(task.objective.replaceAll('\n', ' '), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurface, fontSize: 12, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(task.status.label + ' · ' + task.changedFiles.length.toString() + ' changed files · ' + task.toolCalls.toString() + ' tool calls', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}