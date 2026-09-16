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
    if (!_scrollController.hasClients) return;
    final target = (_scrollController.offset + delta)
        .clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.animateTo(
      target,
      duration: DesignTokens.durationFast,
      curve: DesignTokens.curveStandard,
    );
  }

  void _closeTab(EditorTab tab) {
    final tabs = ref.read(openTabsProvider);
    final activeId = ref.read(activeTabIdProvider);
    final index = tabs.indexWhere((t) => t.id == tab.id);
    if (index < 0) return;

    final newTabs = tabs.where((t) => t.id != tab.id).toList();
    ref.read(openTabsProvider.notifier).state = newTabs;

    if (activeId == tab.id) {
      if (newTabs.isEmpty) {
        ref.read(activeTabIdProvider.notifier).state = null;
      } else {
        final nextIndex = index >= newTabs.length ? newTabs.length - 1 : index;
        ref.read(activeTabIdProvider.notifier).state = newTabs[nextIndex].id;
      }
    }
  }

  void _closeOthers(EditorTab tab) {
    final tabs = ref.read(openTabsProvider);
    if (!tabs.any((item) => item.id == tab.id)) return;
    ref.read(openTabsProvider.notifier).state = [tab];
    ref.read(activeTabIdProvider.notifier).state = tab.id;
  }

  void _closeToRight(EditorTab tab) {
    final tabs = ref.read(openTabsProvider);
    final index = tabs.indexWhere((item) => item.id == tab.id);
    if (index < 0) return;

    final remaining = tabs.sublist(0, index + 1);
    ref.read(openTabsProvider.notifier).state = remaining;
    if (!remaining.any((item) => item.id == ref.read(activeTabIdProvider))) {
      ref.read(activeTabIdProvider.notifier).state = tab.id;
    }
  }

  void _showContextMenu(BuildContext context, EditorTab tab, Offset position) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      items: const [
        PopupMenuItem(value: 'close', child: Text('Close')),
        PopupMenuItem(value: 'close_others', child: Text('Close Others')),
        PopupMenuItem(value: 'close_right', child: Text('Close to the Right')),
      ],
    ).then((value) {
      if (!mounted) return;
      switch (value) {
        case 'close':
          _closeTab(tab);
        case 'close_others':
          _closeOthers(tab);
        case 'close_right':
          _closeToRight(tab);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final tabs = ref.watch(openTabsProvider);
    final activeId = ref.watch(activeTabIdProvider);
    final cs = Theme.of(context).colorScheme;

    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.32),
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant, width: 1),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Scrollbar(
              controller: _scrollController,
              child: ListView.separated(
                controller: _scrollController,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(left: 2),
                itemCount: tabs.length,
                separatorBuilder: (_, __) => const SizedBox(width: 1),
                itemBuilder: (context, index) {
                  final tab = tabs[index];
                  return _TabItem(
                    tab: tab,
                    isActive: tab.id == activeId,
                    onClose: () => _closeTab(tab),
                    onContextMenu: (position) =>
                        _showContextMenu(context, tab, position),
                  );
                },
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: cs.outlineVariant)),
            ),
            child: Row(
              children: [
                _TabAction(
                  icon: Icons.chevron_left,
                  tooltip: 'Scroll tabs left',
                  onTap: () => _scrollTabs(-160),
                ),
                _TabAction(
                  icon: Icons.chevron_right,
                  tooltip: 'Scroll tabs right',
                  onTap: () => _scrollTabs(160),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TabItem extends StatefulWidget {
  final EditorTab tab;
  final bool isActive;
  final VoidCallback onClose;
  final ValueChanged<Offset> onContextMenu;

  const _TabItem({
    required this.tab,
    required this.isActive,
    required this.onClose,
    required this.onContextMenu,
  });

  @override
  State<_TabItem> createState() => _TabItemState();
}

class _TabItemState extends State<_TabItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ref = ProviderScope.containerOf(context);
    final active = widget.isActive;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () => ref.read(activeTabIdProvider.notifier).state = widget.tab.id,
        onSecondaryTapDown: (details) =>
            widget.onContextMenu(details.globalPosition),
        child: AnimatedContainer(
          duration: DesignTokens.durationFast,
          curve: DesignTokens.curveStandard,
          constraints: const BoxConstraints(minWidth: 128, maxWidth: 250),
          padding: const EdgeInsets.only(left: 12, right: 7),
          decoration: BoxDecoration(
            color: active
                ? cs.surface
                : (_hovered
                    ? cs.surfaceContainerHighest.withValues(alpha: 0.72)
                    : cs.surfaceContainerHighest.withValues(alpha: 0.30)),
            border: Border(
              top: BorderSide(
                color: active ? cs.primary : Colors.transparent,
                width: 2,
              ),
              right: BorderSide(
                  color: cs.outlineVariant.withValues(alpha: 0.55)),
            ),
          ),
          child: Row(
            children: [
              Icon(
                widget.tab.icon ?? Icons.description_outlined,
                size: 15,
                color: active ? cs.primary : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  widget.tab.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: DesignTokens.fontSizeSM,
                    color: active ? cs.onSurface : cs.onSurfaceVariant,
                    fontWeight: active
                        ? DesignTokens.fontWeightMedium
                        : DesignTokens.fontWeightRegular,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              if (widget.tab.isModified && !_hovered)
                Icon(Icons.circle, size: 6, color: cs.tertiary)
              else
                InkWell(
                  onTap: widget.onClose,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(
                      Icons.close,
                      size: 14,
                      color: _hovered || active
                          ? cs.onSurfaceVariant
                          : Colors.transparent,
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

class _TabAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _TabAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 30,
          height: 39,
          child: Icon(icon, size: 17, color: cs.onSurfaceVariant),
        ),
      ),
    );
  }
}
