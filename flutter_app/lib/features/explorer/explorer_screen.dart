import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/backend/web_picker.dart';
import '../../shared/models/file_tree_item.dart';
import '../../shared/providers/workspace_providers.dart';
import '../../shared/widgets/ai_widgets.dart';

/// Read-only workspace browser. Files are context targets for the agent; they
/// are never edited, created, renamed or deleted from this surface.
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
    final selectedPath = ref.watch(selectedWorkspacePathProvider);

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
                    'WORKSPACE',
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
          if (selectedPath != null && selectedPath.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              color: cs.primaryContainer.withValues(alpha: 0.18),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome, size: 15, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      selectedPath,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontFamily: 'JetBrains Mono',
                        fontSize: 11,
                      ),
                    ),
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
                        'Bir klasör seçin; agent bu çalışma alanını yönetebilsin.',
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
                      child: Text(
                        'Bu çalışma alanı boş.',
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    ),
                  );
                }
                return ListView(
                  padding: const EdgeInsets.fromLTRB(6, 7, 6, 18),
                  children: tree
                      .map((item) => _FileTreeView(
                            item: item,
                            expandedPaths: expandedPaths,
                          ))
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

  const _FileTreeView({
    required this.item,
    required this.expandedPaths,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isExpanded = expandedPaths.contains(item.path);
    final selected = ref.watch(selectedWorkspacePathProvider) == item.path;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: () {
            if (item.isFile) {
              ref.read(selectedWorkspacePathProvider.notifier).state = item.path;
            } else {
              final next = Set<String>.from(ref.read(expandedPathsProvider));
              if (next.contains(item.path)) {
                next.remove(item.path);
              } else {
                next.add(item.path);
              }
              ref.read(expandedPathsProvider.notifier).state = next;
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
            decoration: BoxDecoration(
              color: selected
                  ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.10)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  child: item.isFile
                      ? null
                      : Icon(
                          isExpanded
                              ? Icons.expand_more_rounded
                              : Icons.chevron_right_rounded,
                          size: 16,
                        ),
                ),
                const SizedBox(width: 4),
                Icon(
                  item.icon,
                  size: 17,
                  color: item.isFile
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: 12.5,
                      fontWeight:
                          item.isFile ? FontWeight.w400 : FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (!item.isFile && isExpanded && item.children.isNotEmpty)
          ...item.children.map(
            (child) => Padding(
              padding: const EdgeInsets.only(left: 12),
              child: _FileTreeView(
                item: child,
                expandedPaths: expandedPaths,
              ),
            ),
          ),
      ],
    );
  }
}
