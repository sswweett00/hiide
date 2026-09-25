import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/design_system/tokens.dart';
import '../../shared/models/file_tree_item.dart';
import '../../shared/models/editor_tab.dart';
import '../../shared/providers/editor_providers.dart';

class FileTree extends ConsumerWidget {
  const FileTree({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final treeAsync = ref.watch(fileTreeProvider);
    final expandedPaths = ref.watch(expandedPathsProvider);

    return treeAsync.when(
      data: (tree) => ListView(
        padding: const EdgeInsets.symmetric(horizontal: DesignTokens.space1),
        children: tree
            .map((item) =>
                _FileTreeView(item: item, expandedPaths: expandedPaths))
            .toList(),
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, stack) => Center(
        child: Text(
          'Failed to load files: $err',
          style: TextStyle(color: cs.error, fontSize: DesignTokens.fontSizeSM),
        ),
      ),
    );
  }
}

class _FileTreeView extends ConsumerWidget {
  final FileTreeItem item;
  final Set<String> expandedPaths;

  const _FileTreeView({required this.item, required this.expandedPaths});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isExpanded = expandedPaths.contains(item.path);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _FileTreeItemTile(
          item: item,
          isExpanded: isExpanded,
          onTap: () {
            if (item.isFile) {
              _openFile(context, ref, item);
            } else {
              _toggleExpand(context, ref, item);
            }
          },
        ),
        if (!item.isFile && isExpanded && item.children.isNotEmpty)
          ...item.children.map((child) => Padding(
                padding: EdgeInsets.only(left: DesignTokens.space2),
                child: _FileTreeView(item: child, expandedPaths: expandedPaths),
              )),
      ],
    );
  }

  void _toggleExpand(BuildContext context, WidgetRef ref, FileTreeItem item) {
    final expanded = ref.read(expandedPathsProvider);
    final newExpanded = Set<String>.from(expanded);
    if (newExpanded.contains(item.path)) {
      newExpanded.remove(item.path);
    } else {
      newExpanded.add(item.path);
    }
    ref.read(expandedPathsProvider.notifier).state = newExpanded;
  }

  Future<void> _openFile(
      BuildContext context, WidgetRef ref, FileTreeItem item) async {
    final existingTabs = ref.read(openTabsProvider);
    final existingIndex = existingTabs.indexWhere((t) => t.path == item.path);

    if (existingIndex >= 0) {
      ref.read(activeTabIdProvider.notifier).state =
          existingTabs[existingIndex].id;
    } else {
      final workspaceService = ref.read(workspaceServiceProvider);
      String content = '';
      try {
        content = await workspaceService.readFile(item.path);
      } catch (e) {
        content = '// Error reading file: $e';
      }
      if (!context.mounted) return;

      final newTab = EditorTab(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: item.name,
        path: item.path,
        content: content,
        icon: item.icon,
      );
      ref.read(openTabsProvider.notifier).state = [...existingTabs, newTab];
      ref.read(activeTabIdProvider.notifier).state = newTab.id;
    }
  }
}

class _FileTreeItemTile extends StatelessWidget {
  final FileTreeItem item;
  final bool isExpanded;
  final VoidCallback onTap;

  const _FileTreeItemTile(
      {required this.item, required this.isExpanded, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(
              horizontal: DesignTokens.space2, vertical: DesignTokens.space1),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(DesignTokens.radiusSM),
            color: Colors.transparent,
          ),
          child: Row(
            children: [
              if (!item.isFile)
                Icon(
                  isExpanded ? Icons.expand_more : Icons.chevron_right,
                  size: DesignTokens.iconXS,
                  color: cs.onSurfaceVariant,
                )
              else
                SizedBox(width: DesignTokens.iconXS + DesignTokens.space1),
              const SizedBox(width: DesignTokens.space1),
              Icon(
                item.icon,
                size: DesignTokens.iconSM,
                color: item.isFile ? cs.onSurfaceVariant : cs.primary,
              ),
              const SizedBox(width: DesignTokens.space2),
              Expanded(
                child: Text(
                  item.name,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: DesignTokens.fontSizeMD,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
