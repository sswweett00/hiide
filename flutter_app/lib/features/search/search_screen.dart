import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/backend/workspace_service.dart';
import '../../core/design_system/tokens.dart';
import '../../core/providers/backend_provider.dart';
import '../../shared/models/editor_tab.dart';
import '../../shared/providers/editor_providers.dart';
import '../../shared/widgets/ai_widgets.dart';

final searchResultsProvider = StateProvider<List<Map<String, dynamic>>>((ref) => []);
final isSearchingProvider = StateProvider<bool>((ref) => false);

const _searchDebounce = Duration(milliseconds: 300);
const _maxResults = 100;
const _maxFiles = 500;

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    final query = _searchController.text.trim();
    final token = ++_generation;
    if (query.isEmpty) {
      ref.read(searchResultsProvider.notifier).state = [];
      ref.read(isSearchingProvider.notifier).state = false;
      return;
    }
    _debounce = Timer(_searchDebounce, () => _performSearch(query, token));
  }

  Future<void> _performSearch(String query, int token) async {
    ref.read(isSearchingProvider.notifier).state = true;
    final workspace = ref.read(workspaceServiceProvider);
    final backend = ref.read(backendServiceProvider);
    final results = <Map<String, dynamic>>[];

    try {
      if (backend.isConnected) {
        final root = ref.read(workspaceRootProvider);
        final hits = await backend.workspaceSearch(root, query, maxResults: _maxResults);
        if (!mounted || token != _generation) return;
        for (final hit in hits.take(_maxResults)) {
          results.add({
            'file': pathBasename(hit.path),
            'path': hit.path,
            'line': hit.line,
            'content': hit.text,
            'icon': _iconForPath(hit.path),
          });
        }
      } else {
        final tree = await workspace.loadTree();
        await _searchInTree(tree, query.toLowerCase(), workspace, results, token);
      }
    } catch (error) {
      debugPrint('Search error: $error');
      if (results.isEmpty && mounted && token == _generation) {
        try {
          final tree = await workspace.loadTree();
          await _searchInTree(tree, query.toLowerCase(), workspace, results, token);
        } catch (fallbackError) {
          debugPrint('Fallback search error: $fallbackError');
        }
      }
    } finally {
      if (mounted && token == _generation) {
        ref.read(searchResultsProvider.notifier).state = results.take(_maxResults).toList();
        ref.read(isSearchingProvider.notifier).state = false;
      }
    }
  }

  IconData _iconForPath(String path) {
    final name = pathBasename(path).toLowerCase();
    if (name.endsWith('.dart')) return Icons.flutter_dash;
    if (name.endsWith('.zig')) return Icons.bolt;
    if (name.endsWith('.rs')) return Icons.settings_applications;
    if (name.endsWith('.yaml') || name.endsWith('.yml') || name.endsWith('.json')) return Icons.settings;
    if (name.endsWith('.md')) return Icons.description;
    if (name.endsWith('.sh') || name.endsWith('.bash')) return Icons.terminal;
    return Icons.insert_drive_file_outlined;
  }

  Future<void> _searchInTree(
    List<dynamic> items,
    String query,
    WorkspaceService workspace,
    List<Map<String, dynamic>> results,
    int token,
  ) async {
    var scannedFiles = 0;

    Future<void> walk(List<dynamic> nodes) async {
      for (final item in nodes) {
        if (!mounted || token != _generation || results.length >= _maxResults || scannedFiles >= _maxFiles) return;
        if (item.isFile) {
          scannedFiles++;
          try {
            final content = await workspace.readFile(item.path);
            final lines = content.split('\n');
            for (var i = 0; i < lines.length && results.length < _maxResults; i++) {
              if (!mounted || token != _generation) return;
              if (lines[i].toLowerCase().contains(query)) {
                results.add({
                  'file': item.name,
                  'path': item.path,
                  'line': i + 1,
                  'content': lines[i].trim(),
                  'icon': item.icon,
                });
              }
            }
          } catch (_) {}
        } else if (item.children.isNotEmpty) {
          await walk(item.children);
        }
      }
    }

    await walk(items);
  }

  Future<void> _openSearchResult(Map<String, dynamic> result) async {
    final path = result['path']?.toString() ?? '';
    if (path.isEmpty) return;
    final workspace = ref.read(workspaceServiceProvider);
    final content = await _safeRead(workspace, path);
    if (content == null) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('File could not be read.')));
      return;
    }

    final tabs = ref.read(openTabsProvider);
    final existing = tabs.indexWhere((tab) => tab.path == path);
    if (existing >= 0) {
      ref.read(activeTabIdProvider.notifier).state = tabs[existing].id;
    } else {
      final tab = EditorTab(
        id: 'search_${DateTime.now().microsecondsSinceEpoch}',
        title: result['file']?.toString() ?? pathBasename(path),
        path: path,
        content: content,
        icon: result['icon'] as IconData? ?? Icons.code,
      );
      ref.read(openTabsProvider.notifier).state = [...tabs, tab];
      ref.read(activeTabIdProvider.notifier).state = tab.id;
      trackRecentFile(ref, tab);
    }
    ref.read(cursorLineProvider.notifier).state = (result['line'] as int? ?? 1).clamp(1, 1000000);
    if (mounted) context.go('/editor');
  }

  Future<String?> _safeRead(WorkspaceService workspace, String path) async {
    try {
      return await workspace.readFile(path);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final results = ref.watch(searchResultsProvider);
    final searching = ref.watch(isSearchingProvider);

    return Container(
      color: cs.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AiPageHeader(icon: Icons.search, title: 'Search Workspace Files'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: DesignTokens.space4),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Type to search across codebase…',
                prefixIcon: Icon(Icons.search, size: DesignTokens.iconMD, color: cs.onSurfaceVariant),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(icon: const Icon(Icons.clear), onPressed: _searchController.clear)
                    : IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _onSearchChanged),
              ),
            ),
          ),
          const SizedBox(height: DesignTokens.space4),
          if (searching) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: DesignTokens.space4, vertical: DesignTokens.space2),
            child: Text('${results.length} results found', style: TextStyle(color: cs.onSurfaceVariant, fontSize: DesignTokens.fontSizeSM)),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: DesignTokens.space4),
              itemCount: results.length,
              itemBuilder: (context, index) {
                final item = results[index];
                return InkWell(
                  onTap: () => _openSearchResult(item),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: DesignTokens.space2),
                    decoration: BoxDecoration(border: Border(bottom: BorderSide(color: cs.outlineVariant, width: DesignTokens.borderWidthThin))),
                    child: Row(
                      children: [
                        Icon(item['icon'] as IconData? ?? Icons.insert_drive_file, size: DesignTokens.iconSM, color: cs.primary),
                        const SizedBox(width: DesignTokens.space2),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${item['file']}:${item['line']}', style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold, fontSize: DesignTokens.fontSizeSM)),
                              Text(item['content']?.toString() ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurface, fontFamily: 'JetBrains Mono', fontSize: DesignTokens.fontSizeSM)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
