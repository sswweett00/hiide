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
      width: 52,
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          cs.surfaceContainerHighest.withValues(alpha: 0.30),
          cs.surface,
        ),
        border: Border(right: BorderSide(color: cs.outlineVariant)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 7),
          const _ActivityBrandMark(),
          const SizedBox(height: 9),
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: ActivityItem.values.length,
              itemBuilder: (context, index) {
                final item = ActivityItem.values[index];
                return _ActivityBarItem(
                  item: item,
                  isSelected: item.id == selected,
                  onTap: () {
                    ref.read(selectedActivityProvider.notifier).state = item.id;
                    if (item.route != null) context.go(item.route!.path);
                  },
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _ActivityBarItem(
              item: ActivityItem.settings,
              isSelected: selected == 'settings',
              onTap: () {
                ref.read(selectedActivityProvider.notifier).state = 'settings';
                context.go(RoutePath.settings.path);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ActivityBrandMark extends StatelessWidget {
  const _ActivityBrandMark();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Hiide',
      child: Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(9),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [cs.primary, cs.tertiary],
          ),
          boxShadow: [
            BoxShadow(
              color: cs.primary.withValues(alpha: 0.24),
              blurRadius: 16,
              spreadRadius: -4,
            ),
          ],
        ),
        child: const Text(
          'H',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _ActivityBarItem extends StatefulWidget {
  final ActivityItem item;
  final bool isSelected;
  final VoidCallback onTap;

  const _ActivityBarItem({
    required this.item,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_ActivityBarItem> createState() => _ActivityBarItemState();
}

class _ActivityBarItemState extends State<_ActivityBarItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tooltip = switch (widget.item) {
      ActivityItem.files => 'Explorer',
      ActivityItem.search => 'Search',
      ActivityItem.sourceControl => 'Source Control',
      ActivityItem.debug => 'Run & Debug',
      ActivityItem.extensions => 'Extensions',
      ActivityItem.ai => 'AI',
      ActivityItem.settings => 'Settings',
    };

    return Tooltip(
      message: tooltip,
      preferBelow: false,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: SizedBox(
            height: 47,
            child: Stack(
              alignment: Alignment.center,
              children: [
                AnimatedContainer(
                  duration: DesignTokens.durationFast,
                  curve: DesignTokens.curveStandard,
                  margin: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    color: widget.isSelected
                        ? cs.primary.withValues(alpha: 0.14)
                        : _hovered
                            ? cs.onSurface.withValues(alpha: 0.06)
                            : Colors.transparent,
                  ),
                ),
                Icon(
                  widget.isSelected ? widget.item.activeIcon : widget.item.icon,
                  size: 20,
                  color: widget.isSelected
                      ? cs.primary
                      : cs.onSurfaceVariant.withValues(alpha: _hovered ? 0.95 : 0.72),
                ),
                AnimatedPositioned(
                  duration: DesignTokens.durationFast,
                  curve: DesignTokens.curveStandard,
                  left: 3,
                  top: widget.isSelected ? 11 : 20,
                  height: widget.isSelected ? 25 : 7,
                  width: 2,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: cs.primary,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
