import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/backend/agent_task_store.dart';
import '../../shared/widgets/ai_widgets.dart';
import '../../shared/widgets/ide_shell.dart';

class OutputScreen extends ConsumerStatefulWidget {
  const OutputScreen({super.key});
  @override
  ConsumerState<OutputScreen> createState() => _OutputScreenState();
}

class _OutputScreenState extends ConsumerState<OutputScreen> {
  String _selectedChannel = 'main';
  @override
  Widget build(BuildContext context) {
    ref.watch(agentTaskVersionProvider);
    final tasks = ref.watch(agentTaskStoreProvider).tasks;
    final latest = tasks.isEmpty ? null : tasks.first;
    final events = <({AgentTimelineEvent event, String taskId})>[];
    for (final task in tasks) {
      for (final event in task.timeline) {
        if (_selectedChannel == 'task' && latest?.id != task.id) continue;
        if (_selectedChannel == 'build' && !const {'tool.start','tool.finish','verification','specialist.start','specialist.finish','completed','completed_with_failure','rollback','rollback_partial'}.contains(event.kind)) continue;
        events.add((event: event, taskId: task.id));
      }
    }
    events.sort((a, b) => b.event.createdAt.compareTo(a.event.createdAt));
    final visibleCount = events.length > 250 ? 250 : events.length;
    return IdeShell(showAiSidebar: true, child: Container(color: Theme.of(context).colorScheme.surface, child: Column(children: [
      AiPageHeader(icon: Icons.output, title: 'Output', actions: [
        DropdownButton<String>(value: _selectedChannel, items: const [
          DropdownMenuItem(value: 'main', child: Text('All activity')),
          DropdownMenuItem(value: 'task', child: Text('Latest task')),
          DropdownMenuItem(value: 'build', child: Text('Build & verify')),
        ], onChanged: (value) => setState(() => _selectedChannel = value ?? 'main')),
      ]),
      Expanded(child: latest == null
        ? const AiEmptyState(icon: Icons.output_outlined, title: 'No agent activity yet', subtitle: 'Agent output, tool calls and verification events will appear here.')
        : events.isEmpty
          ? const AiEmptyState(icon: Icons.output_outlined, title: 'No events for this channel', subtitle: 'Select another channel or run an agent task.')
          : ListView.builder(padding: const EdgeInsets.fromLTRB(16,8,16,24), itemCount: visibleCount, itemBuilder: (context,index) => _EventRow(event: events[index].event, taskId: events[index].taskId))),
    ])));
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event, required this.taskId});
  final AgentTimelineEvent event;
  final String taskId;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(padding: const EdgeInsets.only(bottom: 8), child: AiGlowCard(wash: false, child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(event.success ? Icons.check_circle_outline : Icons.error_outline, size: 16, color: event.success ? cs.primary : cs.error),
      const SizedBox(width: 8),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(event.title, style: TextStyle(color: cs.onSurface, fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 3),
        Text(event.kind + ' · ' + event.createdAt.toLocal().toIso8601String() + ' · task ' + taskId, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10)),
        if (event.detail.isNotEmpty) ...[
          const SizedBox(height: 5),
          Text(event.detail, maxLines: 8, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurface, fontFamily: 'JetBrains Mono', fontSize: 10, height: 1.35)),
        ],
      ])),
    ])));
  }
}