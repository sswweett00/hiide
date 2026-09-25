import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/backend/web_picker.dart';
import '../../shared/widgets/ai_widgets.dart';
import '../../shared/models/file_tree_item.dart';
import '../../shared/models/editor_tab.dart';
import '../../shared/providers/editor_providers.dart';

class ExplorerScreen extends ConsumerWidget {
  const ExplorerScreen({super.key});

  Future<void> _browseFolder(BuildContext context, WidgetRef ref) async {
    final ws = await pickWebDirectory();
    if (ws == null || !context.mounted) return;
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
          Container(
            height: 54,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: cs.surface,
              border: Border(bottom: BorderSide(color: cs.outlineVariant)),
            ),
            child: Row(
              children: [
                Icon(Icons.folder_outlined, size: 17, color: cs.primary),
                const SizedBox(width: 9),
                const Expanded(
                  child: Text(
                    'EXPLORER',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh Workspace',
                  icon: const Icon(Icons.refresh_rounded, size: 17),
                  onPressed: () => ref.invalidate(fileTreeProvider),
                ),
                IconButton(
                  tooltip: 'Collapse All',
                  icon: const Icon(Icons.unfold_less_rounded, size: 18),
                  onPressed: () =>
                      ref.read(expandedPathsProvider.notifier).state = <String>{},
                ),
              ],
            ),
          ),
          Expanded(
            child: treeAsync.when(
              data: (tree) {
                if (tree.isEmpty &&
                    kIsWeb &&
                    webWorkspaceStore.workspace == null) {
                  return AiEmptyState(
                    icon: Icons.folder_open,
                    title: 'Henüz çalışma alanı seçilmedi',
                    subtitle:
                        'Tarayıcıda bir klasör seçin; dosyaları IDE\'de açalım.',
                    action: AiGradientButton(
                      onPressed: () => _browseFolder(context, ref),
                      label: 'Klasör Seç',
                      icon: Icons.folder_open,
                    ),
                  );
                }
                if (tree.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.folder_off_outlined,
                              size: 30, color: cs.onSurfaceVariant),
                          const SizedBox(height: 10),
                          Text('Bu çalışma alanı boş.',
                              style: TextStyle(color: cs.onSurfaceVariant)),
                        ],
                      ),
                    ),
                  );
                }
                return ListView(
                  padding: const EdgeInsets.fromLTRB(6, 7, 6, 18),
                  children: tree
                      .map((item) => _FileTreeView(
                          item: item, expandedPaths: expandedPaths))
                      .toList(),
                );
              },
              loading: () => Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: cs.primary,
                  ),
                ),
              ),
              error: (err, stack) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Dosyalar yüklenemedi: $err',
                    style: TextStyle(color: cs.error, fontSize: 12),
                  ),
                ),
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
              _toggleExpand(ref, item);
            }
          },
        ),
        if (!item.isFile && isExpanded && item.children.isNotEmpty)
          ...item.children.map((child) => Padding(
                padding: const EdgeInsets.only(left: 12),
                child: _FileTreeView(item: child, expandedPaths: expandedPaths),
              )),
      ],
    );
  }

  void _toggleExpand(WidgetRef ref, FileTreeItem item) {
    final expanded = ref.read(expandedPathsProvider);
    final next = Set<String>.from(expanded);
    if (next.contains(item.path)) {
      next.remove(item.path);
    } else {
      next.add(item.path);
    }
    ref.read(expandedPathsProvider.notifier).state = next;
  }

  Future<void> _openFile(
      BuildContext context, WidgetRef ref, FileTreeItem item) async {
    final existingTabs = ref.read(openTabsProvider);
    final existingIndex = existingTabs.indexWhere((t) => t.path == item.path);
    if (existingIndex >= 0) {
      ref.read(activeTabIdProvider.notifier).state =
          existingTabs[existingIndex].id;
      return;
    }

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

class _FileTreeItemTile extends StatefulWidget {
  final FileTreeItem item;
  final bool isExpanded;
  final VoidCallback onTap;

  const _FileTreeItemTile({
    required this.item,
    required this.isExpanded,
    required this.onTap,
  });

  @override
  State<_FileTreeItemTile> createState() => _FileTreeItemTileState();
}

class _FileTreeItemTileState extends State<_FileTreeItemTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onSecondaryTapUp: (details) =>
            _showContextMenu(context, details),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: _hovered
                ? cs.onSurface.withValues(alpha: 0.055)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                child: !widget.item.isFile
                    ? Icon(
                        widget.isExpanded
                            ? Icons.expand_more_rounded
                            : Icons.chevron_right_rounded,
                        size: 16,
                        color: cs.onSurfaceVariant,
                      )
                    : null,
              ),
              const SizedBox(width: 4),
              Icon(
                widget.item.icon,
                size: 17,
                color: widget.item.isFile
                    ? cs.onSurfaceVariant.withValues(alpha: 0.9)
                    : cs.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.item.name,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 12.5,
                    fontWeight:
                        widget.item.isFile ? FontWeight.w400 : FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_hovered)
                Icon(Icons.more_horiz_rounded,
                    size: 16, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  void _showContextMenu(BuildContext context, TapUpDetails details) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        details.globalPosition.dx,
        details.globalPosition.dy,
        details.globalPosition.dx + 1,
        details.globalPosition.dy + 1,
      ),
      items: [
        if (widget.item.isFile) ...[
          const PopupMenuItem(value: 'open', child: Text('Open')),
          const PopupMenuItem(value: 'rename', child: Text('Rename')),
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ] else ...[
          const PopupMenuItem(value: 'new_file', child: Text('New File')),
          const PopupMenuItem(value: 'new_folder', child: Text('New Folder')),
          const PopupMenuItem(value: 'rename', child: Text('Rename')),
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ],
    ).then((value) {
      if (value == null || !context.mounted) return;
      switch (value) {
        case 'open':
          widget.onTap();
          break;
        case 'rename':
          _showRenameDialog(context);
          break;
        case 'delete':
          _showDeleteConfirmation(context);
          break;
        case 'new_file':
          _showNewFileDialog(context);
          break;
        case 'new_folder':
          _showNewFolderDialog(context);
          break;
      }
    });
  }

  void _showRenameDialog(BuildContext context) {
    final controller = TextEditingController(text: widget.item.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'New name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final newName = controller.text.trim();
              if (newName.isNotEmpty && newName != widget.item.name) {
                final parentPath = widget.item.path
                    .substring(0, widget.item.path.length - widget.item.name.length);
                final service = ProviderScope.containerOf(context, listen: false)
                    .read(workspaceServiceProvider);
                await service.renameEntity(widget.item.path, '$parentPath$newName');
                if (context.mounted) {
                  ProviderScope.containerOf(context, listen: false)
                      .invalidate(fileTreeProvider);
                }
              }
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
  }

  void _showDeleteConfirmation(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete'),
        content: Text('Are you sure you want to delete "${widget.item.name}"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final container = ProviderScope.containerOf(context, listen: false);
              await container.read(workspaceServiceProvider).deleteEntity(widget.item.path);
              container.invalidate(fileTreeProvider);
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _showNewFileDialog(BuildContext context) {
    _showNameDialog(context, 'New File', 'File name', (name, service, container) async {
      final parentPath = widget.item.isFile
          ? widget.item.path.substring(0, widget.item.path.length - widget.item.name.length)
          : '${widget.item.path}/';
      await service.createFile('$parentPath$name');
      container.invalidate(fileTreeProvider);
    });
  }

  void _showNewFolderDialog(BuildContext context) {
    _showNameDialog(context, 'New Folder', 'Folder name', (name, service, container) async {
      final parentPath = widget.item.isFile
          ? widget.item.path.substring(0, widget.item.path.length - widget.item.name.length)
          : '${widget.item.path}/';
      await service.createDirectory('$parentPath$name');
      container.invalidate(fileTreeProvider);
    });
  }

  void _showNameDialog(
    BuildContext context,
    String title,
    String hint,
    Future<void> Function(String, dynamic, ProviderContainer) onCreate,
  ) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                final container = ProviderScope.containerOf(context, listen: false);
                await onCreate(name, container.read(workspaceServiceProvider), container);
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
