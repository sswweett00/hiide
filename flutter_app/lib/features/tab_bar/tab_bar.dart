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

  void _setTabs(List<EditorTab> tabs) {
    ref.read(openTabsProvider.notifier).state = tabs;
    final activeId = ref.read(activeTabIdProvider);
    if (tabs.isEmpty) {
      ref.read(activeTabIdProvider.notifier).state = null;
    } else if (activeId == null || !tabs.any((tab) => tab.id == activeId)) {
      ref.read(activeTabIdProvider.notifier).state = tabs.last.id;
    }
  }

  void _closeTab(EditorTab tab) {
    final tabs = ref.read(openTabsProvider);
    final index = tabs.indexWhere((t) => t.id == tab.id);
    final activeId = ref.read(activeTabIdProvider);
    if (index < 0) return;

    final nextTabs = [...tabs]..removeAt(index);
    ref.read(openTabsProvider.notifier).state = nextTabs;

    if (activeId == tab.id) {
      if (nextTabs.isEmpty) {
        ref.read(activeTabIdProvider.notifier).state = null;
      } else {
        final nextIndex = (index - 1).clamp(0, nextTabs.length - 1);
        ref.read(activeTabIdProvider.notifier).state = nextTabs[nextIndex].id;
      }
    }
  }

  void _showContextMenu(BuildContext context, EditorTab tab) {
    final tabs = ref.read(openTabsProvider);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      builder: (sheetContext) {
        final cs = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(tab.icon ?? Icons.description_outlined),
                title: Text(tab.title, overflow: TextOverflow.ellipsis),
                subtitle: tab.isModified ? const Text('Unsaved changes') : null,
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.close),
                title: const Text('Close'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _closeTab(tab);
                },
              ),
              ListTile(
                leading: const Icon(Icons.layers_clear_outlined),
                title: const Text('Close Others'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _setTabs([tab]);
                },
              ),
              ListTile(
                leading: const Icon(Icons.last_page_outlined),
                title: const Text('Close to the Right'),
                enabled: tabs.indexOf(tab) < tabs.length - 1,
                textColor: cs.onSurface,
                onTap: () {
                  final index = tabs.indexOf(tab);
                  if (index < 0) return;
                  Navigator.pop(sheetContext);
                  _setTabs(tabs.sublist(0, index + 1));
                },
              ),
            ],
          ),
        );
      },
    );
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
              thumbVisibility: false,
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
                    onContextMenu: () => _showContextMenu(context, tab),
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
  final VoidCallback onContextMenu;

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
    final active = widget.isActive;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () => ProviderScope.containerOf(context)
            .read(activeTabIdProvider.notifier)
            .state = widget.tab.id,
        onSecondaryTap: widget.onContextMenu,
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
                    : cs.surfaceContainerHighest.withValues(alpha: 0.3)),
            border: Border(
              top: BorderSide(
                color: active ? cs.primary : Colors.transparent,
                width: 2,
              ),
              right: BorderSide(
                color: cs.outlineVariant.withValues(alpha: 0.55),
              ),
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
              if (widget.tab.isModified && !(_hovered || active))
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
