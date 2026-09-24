import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../shared/models/editor_tab.dart';
import '../../shared/providers/editor_providers.dart';
import '../../shared/widgets/ai_widgets.dart';

// ─── Providers ────────────────────────────────────────────────────────────────

final quickOpenQueryProvider = StateProvider<String>((ref) => '');

final quickOpenIndexProvider = FutureProvider<List<_FileResult>>((ref) async {
  final tree = await ref.watch(fileTreeProvider.future);
  final results = <_FileResult>[];
  _collectFiles(tree, results);
  results.sort((a, b) => a.path.length.compareTo(b.path.length));
  return List.unmodifiable(results);
});

final quickOpenResultsProvider = FutureProvider<List<_FileResult>>((ref) async {
  final query = ref.watch(quickOpenQueryProvider).toLowerCase().trim();
  final index = await ref.watch(quickOpenIndexProvider.future);

  if (query.isEmpty) {
    return index.take(50).toList();
  }

  final ranked = <({double score, _FileResult result})>[];
  for (final result in index) {
    final score = _fuzzyScore(query, result);
    if (score >= 0) {
      ranked.add((score: score, result: result));
    }
  }

  ranked.sort((a, b) {
    final score = b.score.compareTo(a.score);
    if (score != 0) return score;
    return a.result.path.length.compareTo(b.result.path.length);
  });
  return ranked.take(50).map((entry) => entry.result).toList();
});

double _fuzzyScore(String query, _FileResult result) {
  final name = result.name.toLowerCase();
  final path = result.path.toLowerCase();

  if (name == query) return 1000;
  if (name.startsWith(query)) return 800 - name.length / 100;
  if (name.contains(query)) return 600 - name.length / 100;
  if (path.contains(query)) return 400 - path.length / 100;

  var qi = 0;
  var score = 0.0;
  var consecutive = 0;
  for (var i = 0; i < path.length && qi < query.length; i++) {
    if (path.codeUnitAt(i) == query.codeUnitAt(qi)) {
      qi++;
      consecutive++;
      score += 10 + consecutive * 2;
      if (i == 0 || '/_-'.contains(path[i - 1])) score += 20;
    } else {
      consecutive = 0;
    }
  }
  if (qi != query.length) return -1;
  return score - path.length / 100;
}

void _collectFiles(List<dynamic> items, List<_FileResult> results) {
  for (final item in items) {
    if (item.isFile) {
      results
          .add(_FileResult(name: item.name, path: item.path, icon: item.icon));
    } else if (item.children != null) {
      _collectFiles(item.children, results);
    }
  }
}

class _FileResult {
  final String name;
  final String path;
  final dynamic icon;
  const _FileResult(
      {required this.name, required this.path, required this.icon});
}

// ─── Quick Open Overlay ───────────────────────────────────────────────────────

/// Shows as an overlay dialog on top of the IDE shell.
void showQuickOpenOverlay(BuildContext context, WidgetRef ref) {
  showDialog(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    builder: (ctx) => const _QuickOpenDialog(),
  );
}

class _QuickOpenDialog extends ConsumerStatefulWidget {
  const _QuickOpenDialog();

  @override
  ConsumerState<_QuickOpenDialog> createState() => _QuickOpenDialogState();
}

class _QuickOpenDialogState extends ConsumerState<_QuickOpenDialog> {
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _focusNode.requestFocus();
    // Reset query on open
    Future.microtask(() {
      ref.read(quickOpenQueryProvider.notifier).state = '';
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _openFile(List<_FileResult> results, int index) async {
    if (index < 0 || index >= results.length) return;
    final file = results[index];
    Navigator.of(context).pop();

    // Check if already open
    final tabs = ref.read(openTabsProvider);
    final existing = tabs.where((t) => t.path == file.path).firstOrNull;
    if (existing != null) {
      ref.read(activeTabIdProvider.notifier).state = existing.id;
      return;
    }

    // Load and open
    final service = ref.read(workspaceServiceProvider);
    try {
      final content = await service.readFile(file.path);
      final tab = EditorTab(
        id: 'file_${DateTime.now().millisecondsSinceEpoch}',
        title: file.name,
        path: file.path,
        content: content,
        icon: file.icon as IconData?,
      );
      ref.read(openTabsProvider.notifier).state = [...tabs, tab];
      ref.read(activeTabIdProvider.notifier).state = tab.id;
    } catch (e) {
      debugPrint('Quick open error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final resultsAsync = ref.watch(quickOpenResultsProvider);

    // Adapt the dialog insets to the window: on narrow windows the side
    // insets shrink so the footer hint row fits without overflowing.
    final windowWidth = MediaQuery.sizeOf(context).width;
    final horizontalInset = windowWidth < 640 ? 24.0 : 200.0;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.only(
        top: 80,
        left: horizontalInset,
        right: horizontalInset,
      ),
      child: AiGlowCard(
        padding: EdgeInsets.zero,
        wash: false,
        child: Container(
          height: 500,
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 32,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: KeyboardListener(
            focusNode: _focusNode,
            onKeyEvent: (event) {
              if (event is! KeyDownEvent) return;
              resultsAsync.whenData((results) {
                if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                  setState(() => _selectedIndex =
                      (_selectedIndex + 1).clamp(0, results.length - 1));
                } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                  setState(() => _selectedIndex =
                      (_selectedIndex - 1).clamp(0, results.length - 1));
                } else if (event.logicalKey == LogicalKeyboardKey.enter) {
                  _openFile(results, _selectedIndex);
                } else if (event.logicalKey == LogicalKeyboardKey.escape) {
                  Navigator.of(context).pop();
                }
              });
            },
            child: Column(
              children: [
                // Search input
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    border: Border(
                        bottom: BorderSide(color: cs.outlineVariant, width: 1)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.search, color: cs.primary, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _ctrl,
                          autofocus: true,
                          style: TextStyle(color: cs.onSurface, fontSize: 16),
                          decoration: InputDecoration(
                            hintText: 'Go to file... (Ctrl+P)',
                            hintStyle: TextStyle(color: cs.onSurfaceVariant),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                          onChanged: (v) {
                            ref.read(quickOpenQueryProvider.notifier).state = v;
                            setState(() => _selectedIndex = 0);
                          },
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.close,
                            size: 16, color: cs.onSurfaceVariant),
                        onPressed: () => Navigator.of(context).pop(),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ),

                // Results
                Expanded(
                  child: resultsAsync.when(
                    loading: () => const Center(
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    error: (e, _) => Center(
                        child: Text('Error: $e',
                            style: TextStyle(color: cs.error))),
                    data: (results) {
                      if (results.isEmpty) {
                        return AiEmptyState(
                          icon: Icons.search_off,
                          title: 'No files found',
                          subtitle:
                              'Try a different query or open a workspace.',
                        );
                      }
                      return ListView.builder(
                        itemCount: results.length,
                        itemBuilder: (context, index) {
                          final file = results[index];
                          final isSelected = index == _selectedIndex;
                          return Material(
                            color: isSelected
                                ? cs.primary.withValues(alpha: 0.15)
                                : Colors.transparent,
                            child: InkWell(
                              onTap: () => _openFile(results, index),
                              onHover: (h) {
                                if (h) setState(() => _selectedIndex = index);
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 8),
                                child: Row(
                                  children: [
                                    Icon(
                                      file.icon as IconData? ??
                                          Icons.insert_drive_file_outlined,
                                      size: 16,
                                      color: isSelected
                                          ? cs.primary
                                          : cs.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            file.name,
                                            style: TextStyle(
                                              color: cs.onSurface,
                                              fontWeight: isSelected
                                                  ? FontWeight.bold
                                                  : FontWeight.normal,
                                            ),
                                          ),
                                          Text(
                                            file.path,
                                            style: TextStyle(
                                              color: cs.onSurfaceVariant,
                                              fontSize: 11,
                                              fontFamily: 'JetBrains Mono',
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),

                // Footer hint
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    border: Border(
                        top: BorderSide(color: cs.outlineVariant, width: 1)),
                  ),
                  child: Row(
                    children: [
                      _HintKey('↑↓', 'navigate'),
                      const SizedBox(width: 16),
                      _HintKey('Enter', 'open'),
                      const SizedBox(width: 16),
                      _HintKey('Esc', 'close'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HintKey extends StatelessWidget {
  final String hint;
  final String label;
  const _HintKey(this.hint, this.label);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            border: Border.all(color: cs.outlineVariant),
            borderRadius: BorderRadius.circular(4),
            color: cs.surfaceContainerHighest,
          ),
          child: Text(hint,
              style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 11,
                  fontFamily: 'JetBrains Mono')),
        ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11)),
      ],
    );
  }
}

// ─── Quick Open Screen (route fallback) ───────────────────────────────────────

class QuickOpenScreen extends ConsumerWidget {
  const QuickOpenScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // This route just shows the dialog overlay on top of the editor
    WidgetsBinding.instance.addPostFrameCallback((_) {
      showQuickOpenOverlay(context, ref);
    });

    return const SizedBox.shrink();
  }
}
