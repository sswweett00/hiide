import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/design_system/tokens.dart';
import '../../core/routing/router.dart';
import '../../shared/models/activity_item.dart';

final selectedActivityProvider = StateProvider<String>((ref) => 'files');

class ActivityBar extends ConsumerWidget {
  const ActivityBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedActivityProvider);
    final cs = Theme.of(context).colorScheme;

    return Container(
      width: 48,
      color: cs.surface,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              children: ActivityItem.values.map((item) {
                final isSelected = item.id == selected;
                return _ActivityBarItem(
                  item: item,
                  isSelected: isSelected,
                  onTap: () {
                    ref.read(selectedActivityProvider.notifier).state = item.id;
                    if (item.route != null) {
                      context.go(item.route!.path);
                    }
                  },
                );
              }).toList(),
            ),
          ),
          _ActivityBarItem(
            item: ActivityItem.settings,
            isSelected: selected == 'settings',
            onTap: () => context.go(RoutePath.settings.path),
          ),
        ],
      ),
    );
  }
}

class _ActivityBarItem extends StatelessWidget {
  final ActivityItem item;
  final bool isSelected;
  final VoidCallback onTap;

  const _ActivityBarItem({
    required this.item,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: DesignTokens.durationFast,
          curve: DesignTokens.curveStandard,
          width: double.infinity,
          height: 48,
          decoration: BoxDecoration(
            color: isSelected
                ? cs.surfaceContainerHighest
                    .withValues(alpha: DesignTokens.opacitySelected)
                : Colors.transparent,
            border: Border(
              left: BorderSide(
                color: isSelected ? cs.primary : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Icon(
            item.icon,
            size: DesignTokens.iconLG,
            color: isSelected
                ? cs.primary
                : cs.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }
}
