import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/design_system/tokens.dart';
import '../../core/backend/terminal_service.dart';
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

    return Column(
      children: [
        Container(
          height: 36,
          color: cs.surface,
          child: Row(
            children: [
              _PanelTab(label: 'TERMINAL', isSelected: selected == 'terminal'),
              _PanelTab(label: 'PROBLEMS', isSelected: selected == 'problems'),
              _PanelTab(label: 'OUTPUT', isSelected: selected == 'output'),
              _PanelTab(
                  label: 'DEBUG CONSOLE', isSelected: selected == 'debug'),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.close,
                    size: DesignTokens.iconSM, color: cs.onSurfaceVariant),
                onPressed: () =>
                    ref.read(selectedBottomPanelProvider.notifier).state = null,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: cs.surfaceContainerHighest,
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
    );
  }
}

class _PanelTab extends StatelessWidget {
  final String label;
  final bool isSelected;

  const _PanelTab({required this.label, required this.isSelected});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: () {
        ProviderScope.containerOf(context)
            .read(selectedBottomPanelProvider.notifier)
            .state = label.toLowerCase().replaceAll(' ', '');
      },
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: DesignTokens.space3, vertical: DesignTokens.space2),
        decoration: BoxDecoration(
          color: isSelected ? cs.surface : Colors.transparent,
          border: Border(
            bottom: BorderSide(
              color: isSelected ? cs.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: cs.onSurface,
            fontSize: DesignTokens.fontSizeSM,
            fontWeight: isSelected
                ? DesignTokens.fontWeightSemibold
                : DesignTokens.fontWeightRegular,
          ),
        ),
      ),
    );
  }
}

/// Compact inline output panel shown inside the bottom panel.
class _InlineOutputScreen extends StatelessWidget {
  const _InlineOutputScreen();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: const Color(0xFF0D1117),
      child: ListView(
        padding: const EdgeInsets.all(DesignTokens.space3),
        children: [
          Text('[info] Build output will appear here.',
              style: TextStyle(
                  color: const Color(0xFFE6EDF3),
                  fontFamily: 'JetBrains Mono',
                  fontSize: DesignTokens.fontSizeSM)),
        ],
      ),
    );
  }
}

/// Compact inline debug console shown inside the bottom panel.
class _InlineDebugScreen extends StatelessWidget {
  const _InlineDebugScreen();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0D1117),
      child: const Center(
        child: Text('Debug Console — start debugging to see output.',
            style: TextStyle(
                color: Color(0xFF8B949E),
                fontFamily: 'JetBrains Mono',
                fontSize: DesignTokens.fontSizeSM)),
      ),
    );
  }
}
