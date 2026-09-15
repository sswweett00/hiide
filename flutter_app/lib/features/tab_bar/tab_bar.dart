import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/design_system/tokens.dart';
import '../../shared/models/editor_tab.dart';
import '../../shared/providers/editor_providers.dart';

class TabBar extends ConsumerStatefulWidget {
  const TabBar({super.key});

  @override
  ConsumerState<TabBar> createState() => _TabBarState();
}

class _TabBarState extends ConsumerState<TabBar> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollTabs(double delta) {
    if (_scrollController.hasClients) {
      final target = (_scrollController.offset + delta)
          .clamp(0.0, _scrollController.position.maxScrollExtent);
      _scrollController.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tabs = ref.watch(openTabsProvider);
    final activeId = ref.watch(activeTabIdProvider);
    final cs = Theme.of(context).colorScheme;

    return Container(
      height: 36,
      color: cs.surface,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showScrollButtons =
              tabs.isNotEmpty && constraints.maxWidth >= 480;

          return Row(
            children: [
              Expanded(
                child: ListView(
                  controller: _scrollController,
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.zero,
                  children: tabs.map((tab) {
                    final isActive = tab.id == activeId;
                    return _TabItem(tab: tab, isActive: isActive);
                  }).toList(),
                ),
              ),
              if (showScrollButtons)
                Row(
                  children: [
                    IconButton(
                      icon: Icon(Icons.chevron_left,
                          size: DesignTokens.iconSM,
                          color: cs.onSurfaceVariant),
                      onPressed: () => _scrollTabs(-120),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 24, minHeight: 24),
                    ),
                    IconButton(
                      icon: Icon(Icons.chevron_right,
                          size: DesignTokens.iconSM,
                          color: cs.onSurfaceVariant),
                      onPressed: () => _scrollTabs(120),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 24, minHeight: 24),
                    ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  final EditorTab tab;
  final bool isActive;

  const _TabItem({required this.tab, required this.isActive});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ref = ProviderScope.containerOf(context);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => ref.read(activeTabIdProvider.notifier).state = tab.id,
        child: AnimatedContainer(
          duration: DesignTokens.durationFast,
          curve: DesignTokens.curveStandard,
          padding: const EdgeInsets.symmetric(
              horizontal: DesignTokens.space3, vertical: DesignTokens.space2),
          decoration: BoxDecoration(
            color: isActive
                ? cs.surface
                : cs.surfaceContainerHighest.withValues(alpha: 0.3),
            border: Border(
              bottom: BorderSide(
                color: isActive ? cs.primary : Colors.transparent,
                width: 2,
              ),
              right: BorderSide(
                  color: cs.outlineVariant.withValues(alpha: 0.3), width: 1),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                tab.icon ?? Icons.description_outlined,
                size: DesignTokens.iconSM,
                color: isActive ? cs.primary : cs.onSurfaceVariant,
              ),
              const SizedBox(width: DesignTokens.space1),
              Text(
                tab.title,
                style: TextStyle(
                  fontSize: DesignTokens.fontSizeMD,
                  color: isActive ? cs.onSurface : cs.onSurfaceVariant,
                  fontWeight: isActive
                      ? DesignTokens.fontWeightMedium
                      : DesignTokens.fontWeightRegular,
                ),
              ),
              if (tab.isModified)
                Padding(
                  padding: const EdgeInsets.only(left: DesignTokens.space1),
                  child: Icon(Icons.circle, size: 8, color: cs.tertiary),
                ),
              const SizedBox(width: DesignTokens.space1),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () {
                    final tabs = ref.read(openTabsProvider);
                    final activeId = ref.read(activeTabIdProvider);
                    final newTabs = tabs.where((t) => t.id != tab.id).toList();
                    ref.read(openTabsProvider.notifier).state = newTabs;
                    if (activeId == tab.id && newTabs.isNotEmpty) {
                      ref.read(activeTabIdProvider.notifier).state =
                          newTabs.last.id;
                    }
                  },
                  child: Icon(
                    Icons.close,
                    size: DesignTokens.iconSM,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
