import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/backend/agent_task_store.dart';
import '../../core/design_system/tokens.dart';
import '../../shared/widgets/ai_widgets.dart';
import '../../shared/widgets/ide_shell.dart';

class NotificationCenterScreen extends ConsumerWidget {
  const NotificationCenterScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(agentTaskVersionProvider);
    final tasks = ref.watch(agentTaskStoreProvider).tasks;
    return IdeShell(
      showAiSidebar: true,
      child: Container(
        color: Theme.of(context).colorScheme.surface,
        child: Column(children: [
          const AiPageHeader(icon: Icons.notifications_outlined, title: 'Notifications'),
          Expanded(
            child: tasks.isEmpty
                ? const AiEmptyState(icon: Icons.notifications_none_outlined, title: 'No notifications', subtitle: 'Agent approvals, failures and completion events will appear here.')
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: tasks.length,
                    itemBuilder: (context, index) => _TaskNotification(task: tasks[index]),
                  ),
          ),
        ]),
      ),
    );
  }
}

class _TaskNotification extends StatelessWidget {
  const _TaskNotification({required this.task});
  final AgentTaskRecord task;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (icon, color) = switch (task.status) {
      AgentTaskStatus.succeeded => (Icons.check_circle_outline, cs.primary),
      AgentTaskStatus.succeededWithWarnings => (Icons.warning_amber_outlined, cs.tertiary),
      AgentTaskStatus.failed => (Icons.error_outline, cs.error),
      AgentTaskStatus.waitingApproval => (Icons.pan_tool_outlined, cs.tertiary),
      AgentTaskStatus.canceled => (Icons.stop_circle_outlined, cs.onSurfaceVariant),
      _ => (Icons.auto_awesome, cs.primary),
    };
    final lastEvent = task.timeline.isEmpty ? null : task.timeline.last;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AiGlowCard(
        wash: false,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 19, color: color),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(task.status.label, style: TextStyle(color: cs.onSurface, fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text(task.objective.replaceAll('\n', ' '), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurface, fontSize: 12)),
            if (lastEvent != null) ...[
              const SizedBox(height: 4),
              Text(lastEvent.detail.isEmpty ? lastEvent.title : lastEvent.detail, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10)),
            ],
          ])),
        ]),
      ),
    );
  }
}