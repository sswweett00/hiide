import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/design_system/tokens.dart';
import '../problems/todo_panel.dart';
import '../terminal/terminal_screen.dart';
import '../output/output_screen.dart';
import '../debug/debug_screen.dart';

final selectedBottomPanelProvider = StateProvider<String?>((ref) => null);
final bottomPanelHeightProvider = StateProvider<double>((ref) => 220);

class BottomPanel extends ConsumerWidget {
  const BottomPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedBottomPanelProvider);
    final cs = Theme.of(context).colorScheme;
    if (selected == null) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 34,
            child: Row(
              children: [
                const SizedBox(width: 8),
                _PanelTab(label: 'TERMINAL', value: 'terminal', selected: selected),
                _PanelTab(label: 'PROBLEMS', value: 'problems', selected: selected),
                _PanelTab(label: 'OUTPUT', value: 'output', selected: selected),
                _PanelTab(label: 'DEBUG CONSOLE', value: 'debug', selected: selected),
                const Spacer(),
                Tooltip(
                  message: 'Close panel',
                  child: IconButton(
                    icon: Icon(Icons.close, size: 16, color: cs.onSurfaceVariant),
                    onPressed: () => ref.read(selectedBottomPanelProvider.notifier).state = null,
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.28),
                border: Border(top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.55))),
              ),
              child: switch (selected) {
                'problems' => const TodoIssuesPanel(),
                'terminal' => const TerminalScreen(),
                'output' => const _InlineOutputScreen(),
                'debug' => const _InlineDebugScreen(),
                _ => const SizedBox.shrink(),
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PanelTab extends StatelessWidget {
  final String label;
  final String value;
  final String selected;

  const _PanelTab({required this.label, required this.value, required this.selected});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isSelected = selected == value;
    final ref = ProviderScope.containerOf(context);

    return InkWell(
      onTap: () => ref.read(selectedBottomPanelProvider.notifier).state = value,
      child: AnimatedContainer(
        duration: DesignTokens.durationFast,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        height: 34,
        decoration: BoxDecoration(
          color: isSelected ? cs.surfaceContainerHighest.withValues(alpha: 0.48) : Colors.transparent,
          border: Border(
            bottom: BorderSide(color: isSelected ? cs.primary : Colors.transparent, width: 2),
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? cs.onSurface : cs.onSurfaceVariant,
            fontSize: 10,
            letterSpacing: 0.7,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _InlineOutputScreen extends StatelessWidget {
  const _InlineOutputScreen();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        Row(
          children: [
            Icon(Icons.terminal_outlined, size: 15, color: cs.primary),
            const SizedBox(width: 8),
            Text('Build Output', style: TextStyle(color: cs.onSurface, fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          '[info] Build output will appear here.',
          style: TextStyle(color: cs.onSurfaceVariant, fontFamily: 'JetBrains Mono', fontSize: 12),
        ),
      ],
    );
  }
}

class _InlineDebugScreen extends StatelessWidget {
  const _InlineDebugScreen();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bug_report_outlined, size: 16, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(
            'Debug Console — start debugging to see output.',
            style: TextStyle(color: cs.onSurfaceVariant, fontFamily: 'JetBrains Mono', fontSize: 12),
          ),
        ],
      ),
    );
  }
}
