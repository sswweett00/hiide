import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../shared/widgets/ide_shell.dart';
import '../../shared/widgets/ai_widgets.dart';
import 'todo_panel.dart';

class ProblemsScreen extends ConsumerWidget {
  const ProblemsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;

    return IdeShell(
      showAiSidebar: true,
      child: Container(
        color: cs.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AiPageHeader(icon: Icons.error_outline, title: 'Problems'),
            // The workspace TODO/FIXME scan (real markers, tap to open).
            const Expanded(child: TodoIssuesPanel()),
          ],
        ),
      ),
    );
  }
}
