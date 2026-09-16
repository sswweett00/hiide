import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/design_system/tokens.dart';
import '../../shared/widgets/ide_shell.dart';
import '../../shared/providers/editor_providers.dart';
import '../../shared/widgets/ai_widgets.dart';

class ExplorerScreen extends ConsumerStatefulWidget {
  const ExplorerScreen({super.key});
  @override
  ConsumerState<ExplorerScreen> createState() => _ExplorerScreenState();
}

class _ExplorerScreenState extends ConsumerState<ExplorerScreen> {
  final Set<String> _expanded = <String>{};
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final tree = ref.watch(fileTreeProvider);
    return tree.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(child: Text('Explorer error: $error')),
      data: (items) => _ExplorerContent(items: items, query: _query, expanded: _expanded),
    );
  }
}

class _ExplorerContent extends StatelessWidget {
  final List<FileTreeItem> items;
  final String query;
  final Set<String> expanded;
  const _ExplorerContent({required this.items, required this.query, required this.expanded});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final filtered = _filter(items, query);
    return ListView.builder(
      itemCount: filtered.length,
      itemBuilder: (context, index) => _ExplorerItem(item: filtered[index]),
    );
  }

  List<FileTreeItem> _filter(List<FileTreeItem> source, String query) {
    if (query.trim().isEmpty) return source;
    final lowered = query.toLowerCase();
    return source.where((item) =>
        item.name.toLowerCase().contains(lowered) ||
        (!item.isFile && _filter(item.children, query).isNotEmpty)).map((item) {
      if (item.isFile) return item;
      return item.copyWith(children: _filter(item.children, query));
    }).toList();
  }
}

class _ExplorerItem extends StatefulWidget {
  final FileTreeItem item;
  const _ExplorerItem({required this.item});
  @override
  State<_ExplorerItem> createState() => _ExplorerItemState();
}

class _ExplorerItemState extends State<_ExplorerItem> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: InkWell(
            onTap: () => widget.item.isFile ? _openFile(context, widget.item) : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Icon(widget.item.isFile ? widget.item.icon : Icons.folder_outlined, size: 16, color: cs.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.item.name,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 12.5,
                        fontWeight: widget.item.isFile ? FontWeight.w400 : FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_hovered) const Icon(Icons.more_horiz, size: 15),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _openFile(BuildContext context, FileTreeItem item) async {
    try {
      await openFileInTabs(ProviderScope.containerOf(context).read, item.path);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Open failed: $error')));
      }
    }
  }
}
