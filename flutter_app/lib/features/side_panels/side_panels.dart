import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/design_system/tokens.dart';

final selectedSidePanelProvider = StateProvider<String?>((ref) => null);

class SidePanel extends ConsumerWidget {
  const SidePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedSidePanelProvider);
    final cs = Theme.of(context).colorScheme;

    return Row(
      children: [
        if (selected != null)
          Container(
            width: 48,
            color: cs.surface,
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _SidePanelNav(
                  icon: Icons.search,
                  label: 'Search',
                  isSelected: selected == 'search',
                  onTap: () => context.go('/search'),
                ),
                _SidePanelNav(
                  icon: Icons.commit,
                  label: 'Source Control',
                  isSelected: selected == 'source',
                  onTap: () => context.go('/source-control'),
                ),
                _SidePanelNav(
                  icon: Icons.play_arrow,
                  label: 'Run and Debug',
                  isSelected: selected == 'run',
                  onTap: () => context.go('/debug'),
                ),
                _SidePanelNav(
                  icon: Icons.extension,
                  label: 'Extensions',
                  isSelected: selected == 'extensions',
                  onTap: () => context.go('/extensions'),
                ),
              ],
            ),
          ),
        Expanded(
          child: Container(
            width: selected != null ? null : 0,
            color: cs.surfaceContainerHighest,
            child: selected == null
                ? const Center(child: Text('Select a side panel'))
                : _SidePanelContent(panelId: selected),
          ),
        ),
      ],
    );
  }
}

class _SidePanelNav extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _SidePanelNav({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: DesignTokens.durationFast,
        width: double.infinity,
        height: 48,
        decoration: BoxDecoration(
          color: isSelected
              ? cs.primary.withValues(alpha: DesignTokens.opacitySelected)
              : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: isSelected ? cs.primary : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: DesignTokens.space2),
            Icon(icon,
                size: DesignTokens.iconMD,
                color: isSelected ? cs.primary : cs.onSurfaceVariant),
            if (isSelected) ...[
              const SizedBox(width: DesignTokens.space2),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: DesignTokens.fontSizeMD,
                    fontWeight: DesignTokens.fontWeightMedium,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SidePanelContent extends StatelessWidget {
  final String panelId;

  const _SidePanelContent({required this.panelId});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(DesignTokens.space4),
          child: Text(
            panelId == 'search'
                ? 'Search'
                : panelId == 'source'
                    ? 'Source Control'
                    : panelId == 'run'
                        ? 'Run and Debug'
                        : 'Extensions',
            style: TextStyle(
              color: cs.onSurface,
              fontSize: DesignTokens.fontSizeLG,
              fontWeight: DesignTokens.fontWeightSemibold,
            ),
          ),
        ),
        Expanded(
          child: Center(
            child: Text(
              '$panelId content',
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ),
        ),
      ],
    );
  }
}
