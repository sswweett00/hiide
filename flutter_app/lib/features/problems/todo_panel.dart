import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_system/tokens.dart';
import '../../shared/models/todo_issue.dart';
import '../../shared/providers/workspace_providers.dart';
import '../../shared/widgets/ai_widgets.dart';

class TodoIssuesPanel extends ConsumerWidget {
  const TodoIssuesPanel({super.key});
  static const _kindColors = <String, Color>{
    'TODO': Color(0xFF58A6FF),
    'FIXME': Color(0xFFD29922),
    'HACK': Color(0xFFF472B6),
    'BUG': Color(0xFFF85149),
  };
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final scan = ref.watch(todoScanProvider);
    return Column(children: [
      Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
        child: Row(children: [
          Icon(Icons.fact_check_outlined, size: 16, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Text('TODO / FIXME', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11, fontWeight: FontWeight.w600)),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.refresh, size: 16),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            onPressed: () => ref.invalidate(todoScanProvider),
            tooltip: 'Rescan workspace',
          ),
        ]),
      ),
      Expanded(
        child: scan.when(
          loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          error: (err, _) => Center(child: Text('Scan error: ' + err.toString(), style: TextStyle(color: cs.error, fontSize: 11))),
          data: (issues) => issues.isEmpty
              ? const AiEmptyState(icon: Icons.task_alt, title: 'No markers found', subtitle: 'The current workspace has no TODO/FIXME/HACK/BUG markers.')
              : ListView.builder(
                  itemCount: issues.length,
                  itemBuilder: (context, index) => _TodoTile(issue: issues[index], color: _kindColors[issues[index].kind] ?? cs.primary),
                ),
        ),
      ),
    ]);
  }
}

class _TodoTile extends StatelessWidget {
  const _TodoTile({required this.issue, required this.color});
  final TodoIssue issue;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final shortFile = issue.file.split(RegExp(r'[\\/]')).last;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      leading: Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      title: Text(issue.text.isEmpty ? issue.kind : issue.text, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(shortFile + ':' + issue.line.toString() + ' · ' + issue.kind, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10, fontFamily: 'JetBrains Mono')),
    );
  }
}