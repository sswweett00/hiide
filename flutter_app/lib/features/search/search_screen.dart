import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/backend/workspace_service.dart';
import '../../core/design_system/tokens.dart';
import '../../core/providers/backend_provider.dart';
import '../../shared/widgets/ide_shell.dart';
import '../../shared/widgets/ai_widgets.dart';
import '../../shared/providers/editor_providers.dart';
import '../../shared/models/editor_tab.dart';

final searchResultsProvider =
    StateProvider<List<Map<String, dynamic>>>((ref) => []);
final isSearchingProvider = StateProvider<bool>((ref) => false);

/// Debounce delay for incremental search.
const _searchDebounce = Duration(milliseconds: 350);

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  /// Fires on every keystroke; debounces the actual search.
  void _onSearchChanged() {
    _debounce?.cancel();
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      ref.read(searchResultsProvider.notifier).state = [];
      return;
    }
    _debounce = Timer(_searchDebounce, () => _performSearch(query));
  }

  Future<void> _performSearch([String? queryParam]) async {
    final query = queryParam ?? _searchController.text;
    if (query.trim().isEmpty) {
      ref.read(searchResultsProvider.notifier).state = [];
      return;
    }

    ref.read(isSearchingProvider.notifier).state = true;
    final workspaceService = ref.read(workspaceServiceProvider);
    final backend = ref.read(backendServiceProvider);

    final List<Map<String, dynamic>> results = [];
    try {
      // Fast path: the Zig engine greps the whole workspace natively.
      if (backend.isConnected) {
        final root = ref.read(workspaceRootProvider);
        final hits =
            await backend.workspaceSearch(root, query.trim(), maxResults: 100);
        for (final hit in hits) {
          results.add({
            'file': pathBasename(hit.path),
            'path': hit.path,
            'line': hit.line,
            'content': hit.text,
            'icon': _iconForPath(hit.path),
          });
        }
      } else {
        // Offline fallback: in-memory Dart scan.
        final tree = await workspaceService.loadTree();
        await _searchInTree(
            tree, query.toLowerCase(), workspaceService, results);
      }
    } catch (e) {
      debugPrint('Search error: $e');
      // Last resort: Dart scan if the engine call failed.
      if (results.isEmpty) {
        try {
          final tree = await workspaceService.loadTree();
          await _searchInTree(
              tree, query.toLowerCase(), workspaceService, results);
        } catch (e2) {
          debugPrint('Fallback search error: $e2');
        }
      }
    } finally {
      ref.read(searchResultsProvider.notifier).state = results;
      ref.read(isSearchingProvider.notifier).state = false;
    }
  }

  IconData _iconForPath(String path) {
    final name = pathBasename(path);
    if (name.endsWith('.dart')) return Icons.flutter_dash;
    if (name.endsWith('.zig')) return Icons.bolt;
    if (name.endsWith('.rs')) return Icons.settings_applications;
    if (name.endsWith('.yaml') ||
        name.endsWith('.yml') ||
        name.endsWith('.json')) {
      return Icons.settings;
    }
    if (name.endsWith('.md')) return Icons.description;
    if (name.endsWith('.sh') || name.endsWith('.bash')) return Icons.terminal;
    return Icons.insert_drive_file_outlined;
  }

  Future<void> _searchInTree(
    List dynamicItems,
    String query,
    dynamic workspaceService,
    List<Map<String, dynamic>> results,
  ) async {
    for (final item in dynamicItems) {
      if (item.isFile) {
        try {
          final content = await workspaceService.readFile(item.path);
          final lines = content.split('\n');
          for (int i = 0; i < lines.length; i++) {
            if (lines[i].toLowerCase().contains(query)) {
              results.add({
                'file': item.name,
                'path': item.path,
                'line': i + 1,
                'content': lines[i].trim(),
                'icon': item.icon,
              });
              if (results.length >= 100) return;
            }
          }
        } catch (_) {}
      } else if (item.children.isNotEmpty) {
        await _searchInTree(item.children, query, workspaceService, results);
      }
    }
  }

  void _openSearchResult(Map<String, dynamic> result) async {
    final workspaceService = ref.read(workspaceServiceProvider);
    String content = '';
    try {
      content = await workspaceService.readFile(result['path']);
    } catch (e) {
      content = '// Error reading file';
    }

    final tabs = ref.read(openTabsProvider);
    final existingIndex = tabs.indexWhere((t) => t.path == result['path']);

    if (existingIndex >= 0) {
      ref.read(activeTabIdProvider.notifier).state = tabs[existingIndex].id;
    } else {
      final newTab = EditorTab(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: result['file'],
        path: result['path'],
        content: content,
        icon: result['icon'] ?? Icons.code,
      );
      ref.read(openTabsProvider.notifier).state = [...tabs, newTab];
      ref.read(activeTabIdProvider.notifier).state = newTab.id;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final results = ref.watch(searchResultsProvider);
    final isSearching = ref.watch(isSearchingProvider);

    return Container(
      color: cs.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AiPageHeader(
              icon: Icons.search, title: 'Search Workspace Files'),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: DesignTokens.space4),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Type to search across codebase…',
                prefixIcon: Icon(Icons.search,
                    size: DesignTokens.iconMD, color: cs.onSurfaceVariant),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          ref.read(searchResultsProvider.notifier).state = [];
                        },
                      )
                    : IconButton(
                        icon: const Icon(Icons.arrow_forward),
                        onPressed: () =>
                            _performSearch(_searchController.text),
                      ),
              ),
            ),
          ),
          const SizedBox(height: DesignTokens.space4),
          if (isSearching)
            const LinearProgressIndicator()
          else
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: DesignTokens.space4,
                  vertical: DesignTokens.space2),
              child: Text(
                '${results.length} results found',
                style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: DesignTokens.fontSizeSM),
              ),
            ),
          Expanded(
            child: ListView.builder(
              padding:
                  const EdgeInsets.symmetric(horizontal: DesignTokens.space4),
              itemCount: results.length,
              itemBuilder: (context, index) {
                final item = results[index];
                return GestureDetector(
                  onTap: () => _openSearchResult(item),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        vertical: DesignTokens.space2),
                    decoration: BoxDecoration(
                      border: Border(
                          bottom: BorderSide(
                              color: cs.outlineVariant,
                              width: DesignTokens.borderWidthThin)),
                    ),
                    child: Row(
                      children: [
                        Icon(item['icon'] ?? Icons.insert_drive_file,
                            size: DesignTokens.iconSM, color: cs.primary),
                        const SizedBox(width: DesignTokens.space2),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${item['file']}:${item['line']}',
                                style: TextStyle(
                                  color: cs.primary,
                                  fontWeight: FontWeight.bold,
                                  fontSize: DesignTokens.fontSizeSM,
                                ),
                              ),
                              Text(
                                item['content'],
                                style: TextStyle(
                                  color: cs.onSurface,
                                  fontFamily: 'JetBrains Mono',
                                  fontSize: DesignTokens.fontSizeSM,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
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
