import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/design_system/tokens.dart';
import '../../shared/models/todo_issue.dart';
import '../../shared/providers/editor_providers.dart';
import '../../shared/widgets/ai_widgets.dart';

/// Lists the workspace's TODO/FIXME/HACK/BUG markers (scanned by
/// [todoScanProvider]) with a refresh action; tapping an entry opens the
/// file at that line. Used by the Problems bottom panel and the Problems
/// screen.
class TodoIssuesPanel extends ConsumerWidget {
  const TodoIssuesPanel({super.key});

  static const Map<String, Color> _kindColors = {
    'TODO': Color(0xFF58A6FF),
    'FIXME': Color(0xFFD29922),
    'HACK': Color(0xFFF472B6),
    'BUG': Color(0xFFF85149),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final scan = ref.watch(todoScanProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: DesignTokens.space3),
          color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
          child: Row(
            children: [
              Icon(Icons.fact_check_outlined,
                  size: DesignTokens.iconSM, color: cs.onSurfaceVariant),
              const SizedBox(width: DesignTokens.space2),
              Text(
                'TODO / FIXME',
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: DesignTokens.fontSizeSM,
                  fontWeight: DesignTokens.fontWeightSemibold,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh, size: DesignTokens.iconSM),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                onPressed: () => ref.invalidate(todoScanProvider),
                tooltip: 'Yeniden tara',
              ),
            ],
          ),
        ),
        Expanded(
          child: scan.when(
            loading: () => const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
            error: (err, _) => Center(
              child: Text('Tarama hatası: $err',
                  style: TextStyle(
                      color: cs.error, fontSize: DesignTokens.fontSizeSM)),
            ),
            data: (issues) {
              if (issues.isEmpty) {
                return const AiEmptyState(
                  icon: Icons.task_alt,
                  title: 'Temiz!',
                  subtitle: 'Çalışma alanında TODO/FIXME/HACK/BUG bulunamadı.',
                );
              }
              return ListView.builder(
                padding:
                    const EdgeInsets.symmetric(vertical: DesignTokens.space1),
                itemCount: issues.length,
                itemBuilder: (context, index) {
                  final issue = issues[index];
                  return _TodoTile(
                      issue: issue,
                      color: _kindColors[issue.kind] ?? cs.primary);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _TodoTile extends ConsumerWidget {
  final TodoIssue issue;
  final Color color;

  const _TodoTile({required this.issue, required this.color});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final parts = issue.file.split(RegExp(r'[\\/]'));
    final shortFile = parts.isEmpty ? issue.file : parts.last;

    return InkWell(
      onTap: () => openFileInTabs(ref, issue.file),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: DesignTokens.space3, vertical: DesignTokens.space2),
        decoration: BoxDecoration(
          border: Border(
              bottom: BorderSide(
                  color: cs.outlineVariant,
                  width: DesignTokens.borderWidthThin)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 3),
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: DesignTokens.space2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    issue.text.isEmpty ? issue.kind : issue.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: cs.onSurface, fontSize: DesignTokens.fontSizeMD),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$shortFile:${issue.line}  ·  ${issue.kind}',
                    style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: DesignTokens.fontSizeXS,
                        fontFamily: 'JetBrains Mono'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
