import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/backend/web_picker.dart';
import '../../core/design_system/tokens.dart';
import '../../shared/widgets/ide_shell.dart';
import '../../shared/widgets/ai_widgets.dart';
import '../../shared/models/file_tree_item.dart';
import '../../shared/models/editor_tab.dart';
import '../../shared/providers/editor_providers.dart';

class ExplorerScreen extends ConsumerWidget {
  const ExplorerScreen({super.key});

  /// Web: opens the browser's directory picker and activates the picked
  /// folder so its real tree appears in the Explorer.
  Future<void> _browseFolder(BuildContext context, WidgetRef ref) async {
    final ws = await pickWebDirectory();
    if (ws == null) return;
    await activateWorkspace(ref, ws.rootPath);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final treeAsync = ref.watch(fileTreeProvider);
    final expandedPaths = ref.watch(expandedPathsProvider);

    return Container(
      color: cs.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AiPageHeader(
            icon: Icons.folder_outlined,
            title: 'Explorer',
            actions: [
              IconButton(
                icon: Icon(Icons.refresh,
                    size: DesignTokens.iconSM, color: cs.onSurfaceVariant),
                onPressed: () => ref.invalidate(fileTreeProvider),
                tooltip: 'Refresh Workspace',
              ),
            ],
          ),
          Expanded(
            child: treeAsync.when(
              data: (tree) {
                // Web first-run: no fake placeholder tree — prompt to pick
                // a real folder through the browser's directory picker.
                if (tree.isEmpty &&
                    kIsWeb &&
                    webWorkspaceStore.workspace == null) {
                  return AiEmptyState(
                    icon: Icons.folder_open,
                    title: 'Henüz çalışma alanı seçilmedi',
                    subtitle:
                        'Tarayıcıda bir klasör seçin; dosyaları IDE\'de '
                        'açalım.',
                    action: AiGradientButton(
                      onPressed: () => _browseFolder(context, ref),
                      label: 'Klasör Seç',
                      icon: Icons.folder_open,
                    ),
                  );
                }
                return ListView(
                  padding: const EdgeInsets.symmetric(
                      horizontal: DesignTokens.space2),
                  children: tree
                      .map((item) => _FileTreeView(
                          item: item, expandedPaths: expandedPaths))
                      .toList(),
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, stack) => Center(
                child: Text('Failed to load files: $err',
                    style: TextStyle(color: cs.error)),
              ),
            ),
          ),
        ],
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
                padding: const EdgeInsets.only(left: DesignTokens.space3),
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

class _FileTreeItemTile extends ConsumerWidget {
  final FileTreeItem item;
  final bool isExpanded;
  final VoidCallback onTap;

  const _FileTreeItemTile(
      {required this.item, required this.isExpanded, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      onSecondaryTapUp: (details) => _showContextMenu(context, ref, details),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: DesignTokens.space2, vertical: DesignTokens.space1),
        child: Row(
          children: [
            if (!item.isFile)
              Icon(
                isExpanded ? Icons.expand_more : Icons.chevron_right,
                size: DesignTokens.iconXS,
                color: cs.onSurfaceVariant,
              )
            else
              const SizedBox(width: DesignTokens.iconXS + DesignTokens.space1),
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
    );
  }

  void _showContextMenu(
      BuildContext context, WidgetRef ref, TapUpDetails details) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        details.globalPosition.dx,
        details.globalPosition.dy,
        details.globalPosition.dx + 1,
        details.globalPosition.dy + 1,
      ),
      items: [
        if (item.isFile) ...[
          const PopupMenuItem(
            value: 'open',
            child: ListTile(
              leading: Icon(Icons.open_in_new, size: 18),
              title: Text('Open'),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const PopupMenuItem(
            value: 'rename',
            child: ListTile(
              leading: Icon(Icons.edit, size: 18),
              title: Text('Rename'),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const PopupMenuItem(
            value: 'delete',
            child: ListTile(
              leading: Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
              title: Text('Delete', style: TextStyle(color: Colors.redAccent)),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ] else ...[
          const PopupMenuItem(
            value: 'new_file',
            child: ListTile(
              leading: Icon(Icons.note_add_outlined, size: 18),
              title: Text('New File'),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const PopupMenuItem(
            value: 'new_folder',
            child: ListTile(
              leading: Icon(Icons.create_new_folder_outlined, size: 18),
              title: Text('New Folder'),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const PopupMenuItem(
            value: 'rename',
            child: ListTile(
              leading: Icon(Icons.edit, size: 18),
              title: Text('Rename'),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const PopupMenuItem(
            value: 'delete',
            child: ListTile(
              leading: Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
              title: Text('Delete', style: TextStyle(color: Colors.redAccent)),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ],
    ).then((value) {
      if (value == null || !context.mounted) return;
      switch (value) {
        case 'open':
          onTap();
          break;
        case 'rename':
          _showRenameDialog(context, ref);
          break;
        case 'delete':
          _showDeleteConfirmation(context, ref);
          break;
        case 'new_file':
          _showNewFileDialog(context, ref);
          break;
        case 'new_folder':
          _showNewFolderDialog(context, ref);
          break;
      }
    });
  }

  void _showRenameDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController(text: item.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'New name',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final newName = controller.text.trim();
              if (newName.isNotEmpty && newName != item.name) {
                final parentPath = item.path.substring(
                    0, item.path.length - item.name.length);
                final newPath = '$parentPath$newName';
                final service = ref.read(workspaceServiceProvider);
                await service.renameEntity(item.path, newPath);
                ref.invalidate(fileTreeProvider);
              }
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
  }

  void _showDeleteConfirmation(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete'),
        content: Text('Are you sure you want to delete "${item.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              final service = ref.read(workspaceServiceProvider);
              await service.deleteEntity(item.path);
              ref.invalidate(fileTreeProvider);
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _showNewFileDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New File'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'File name',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                final parentPath = item.isFile
                    ? item.path.substring(
                        0, item.path.length - item.name.length)
                    : '${item.path}/';
                final filePath = '$parentPath$name';
                final service = ref.read(workspaceServiceProvider);
                await service.createFile(filePath);
                ref.invalidate(fileTreeProvider);
              }
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _showNewFolderDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Folder name',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                final parentPath = item.isFile
                    ? item.path.substring(
                        0, item.path.length - item.name.length)
                    : '${item.path}/';
                final dirPath = '$parentPath$name';
                final service = ref.read(workspaceServiceProvider);
                await service.createDirectory(dirPath);
                ref.invalidate(fileTreeProvider);
              }
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }
}
