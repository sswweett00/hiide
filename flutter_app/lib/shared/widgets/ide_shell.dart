import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/design_system/tokens.dart';
import '../../shared/models/editor_tab.dart';
import '../../shared/providers/editor_providers.dart';
import '../../features/activity_bar/activity_bar.dart';
import '../../features/tab_bar/tab_bar.dart' as hiide_tab_bar;
import '../../features/title_bar/title_bar.dart';
import '../../features/status_bar/status_bar.dart';
import '../../features/side_panels/side_panels.dart';
import '../../features/bottom_panels/bottom_panels.dart';
import '../../features/breadcrumb/breadcrumb.dart';
import '../../features/chat/ai_chat_sidebar.dart';
import '../../features/quick_open/quick_open_screen.dart';
import 'file_tree.dart';

class IdeShell extends ConsumerStatefulWidget {
  final Widget child;
  final bool showAiSidebar;

  const IdeShell({super.key, required this.child, this.showAiSidebar = true});

  @override
  ConsumerState<IdeShell> createState() => _IdeShellState();
}

class _IdeShellState extends ConsumerState<IdeShell> {
  @override
  void initState() {
    super.initState();
    // Record files the user opens (via the tree, quick open, recents, …) so
    // the title bar's history popup stays current.
    ref.listenManual<String?>(activeTabIdProvider, (prev, next) {
      if (next == null || next == prev) return;
      final tabs = ref.read(openTabsProvider);
      for (final tab in tabs) {
        if (tab.id == next) {
          trackRecentFile(ref, tab);
          break;
        }
      }
    });
  }

  // ─── Global keyboard shortcuts ──────────────────────────────────────────────

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final key = event.logicalKey;

    // Ctrl+S — Save active tab
    if (ctrl && !shift && key == LogicalKeyboardKey.keyS) {
      _saveActiveTab();
      return KeyEventResult.handled;
    }

    // Ctrl+P — Quick Open
    if (ctrl && !shift && key == LogicalKeyboardKey.keyP) {
      showQuickOpenOverlay(context, ref);
      return KeyEventResult.handled;
    }

    // Ctrl+Shift+P — Command Palette
    if (ctrl && shift && key == LogicalKeyboardKey.keyP) {
      context.go('/command-palette');
      return KeyEventResult.handled;
    }

    // Ctrl+N — New untitled file
    if (ctrl && !shift && key == LogicalKeyboardKey.keyN) {
      _createNewFile();
      return KeyEventResult.handled;
    }

    // Ctrl+B — Toggle sidebar explorer visibility
    if (ctrl && !shift && key == LogicalKeyboardKey.keyB) {
      final zen = ref.read(zenModeProvider);
      ref.read(zenModeProvider.notifier).state = !zen;
      return KeyEventResult.handled;
    }

    // Ctrl+J — Toggle AI chat sidebar
    if (ctrl && !shift && key == LogicalKeyboardKey.keyJ) {
      final current = ref.read(selectedBottomPanelProvider);
      ref.read(selectedBottomPanelProvider.notifier).state =
          current == 'ai_chat' ? null : 'ai_chat';
      return KeyEventResult.handled;
    }

    // Ctrl+G — Go to line (opens a simple dialog)
    if (ctrl && !shift && key == LogicalKeyboardKey.keyG) {
      _showGoToLineDialog();
      return KeyEventResult.handled;
    }

    // Ctrl+` — Toggle Terminal
    if (ctrl && key == LogicalKeyboardKey.backquote) {
      final current = ref.read(selectedBottomPanelProvider);
      ref.read(selectedBottomPanelProvider.notifier).state =
          current == 'terminal' ? null : 'terminal';
      return KeyEventResult.handled;
    }

    // Ctrl+Shift+G — Source Control / Git
    if (ctrl && shift && key == LogicalKeyboardKey.keyG) {
      context.go('/source-control');
      return KeyEventResult.handled;
    }

    // Ctrl+W — Close active tab
    if (ctrl && !shift && key == LogicalKeyboardKey.keyW) {
      _closeActiveTab();
      return KeyEventResult.handled;
    }

    // Ctrl+F — Find in file; Ctrl+H — Find & replace.
    if (ctrl && !shift && key == LogicalKeyboardKey.keyF) {
      ref.read(findBarOpenProvider.notifier).state = true;
      ref.read(findReplaceModeProvider.notifier).state = false;
      return KeyEventResult.handled;
    }
    if (ctrl && !shift && key == LogicalKeyboardKey.keyH) {
      ref.read(findBarOpenProvider.notifier).state = true;
      ref.read(findReplaceModeProvider.notifier).state = true;
      return KeyEventResult.handled;
    }

    // Escape — close the find bar when it is open.
    if (key == LogicalKeyboardKey.escape && ref.read(findBarOpenProvider)) {
      ref.read(findBarOpenProvider.notifier).state = false;
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _saveActiveTab() {
    final activeId = ref.read(activeTabIdProvider);
    final tabs = ref.read(openTabsProvider);
    if (activeId == null) return;
    final tab = tabs.firstWhere((t) => t.id == activeId,
        orElse: () => const EditorTab(id: '', title: ''));
    if (tab.path == null || tab.path!.isEmpty) return;

    final workspaceService = ref.read(workspaceServiceProvider);
    workspaceService.writeFile(tab.path!, tab.content).then((_) {
      // Mark as saved
      final idx = tabs.indexWhere((t) => t.id == activeId);
      if (idx >= 0) {
        final updated = tabs[idx].copyWith(isModified: false);
        ref.read(openTabsProvider.notifier).state = List<EditorTab>.from(tabs)
          ..[idx] = updated;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Saved ${tab.title}'),
          duration: const Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
          width: 200,
        ));
      }
    }).catchError((e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Save failed: $e'),
          backgroundColor: Colors.red,
        ));
      }
    });
  }

  void _closeActiveTab() {
    final activeId = ref.read(activeTabIdProvider);
    final tabs = ref.read(openTabsProvider);
    if (activeId == null) return;
    final newTabs = tabs.where((t) => t.id != activeId).toList();
    ref.read(openTabsProvider.notifier).state = newTabs;
    if (newTabs.isNotEmpty) {
      ref.read(activeTabIdProvider.notifier).state = newTabs.last.id;
    } else {
      ref.read(activeTabIdProvider.notifier).state = null;
    }
  }

  /// Creates a new untitled file tab and focuses it.
  void _createNewFile() {
    final tabs = ref.read(openTabsProvider);
    final untitledCount =
        tabs.where((t) => t.title.startsWith('Untitled')).length;
    final name = untitledCount == 0 ? 'Untitled' : 'Untitled ${untitledCount + 1}';
    final newTab = EditorTab(
      id: 'untitled_${DateTime.now().millisecondsSinceEpoch}',
      title: name,
      content: '',
      icon: Icons.insert_drive_file_outlined,
    );
    ref.read(openTabsProvider.notifier).state = [...tabs, newTab];
    ref.read(activeTabIdProvider.notifier).state = newTab.id;
  }

  /// Shows a Go To Line dialog that jumps the editor to the entered line.
  void _showGoToLineDialog() {
    final activeId = ref.read(activeTabIdProvider);
    if (activeId == null) return;
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Go to Line'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            hintText: 'Line number',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) {
            final line = int.tryParse(controller.text);
            if (line != null && line > 0) {
              // The editor's _scrollToLine is not directly accessible here,
              // so we use the cursor line provider to signal the jump.
              ref.read(cursorLineProvider.notifier).state = line;
            }
            Navigator.of(ctx).pop();
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final line = int.tryParse(controller.text);
              if (line != null && line > 0) {
                ref.read(cursorLineProvider.notifier).state = line;
              }
              Navigator.of(ctx).pop();
            },
            child: const Text('Go'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final uiMode = ref.watch(uiModeProvider);
    final zen = ref.watch(zenModeProvider);

    // ─── AI-native mode: the whole screen is the AI chat ───────────────────
    // No explorer, tabs, editor, terminal or status bar — just the chat,
    // with the title bar (and its mode slider) still on top.
    if (uiMode == UiMode.aiNative) {
      return Focus(
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: Scaffold(
          backgroundColor: cs.surface,
          body: Column(
            children: const [
              TitleBar(),
              Expanded(child: AiChatSidebar()),
            ],
          ),
        ),
      );
    }

    return Focus(
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: cs.surface,
        body: Container(
          color: cs.surface,
          child: Column(
            children: [
              const TitleBar(),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Zen mode strips every chrome panel — only the editor
                    // (and chat) remain.
                    final showExplorer = !zen && constraints.maxWidth >= 1100;
                    final showAiSidebar =
                        widget.showAiSidebar && constraints.maxWidth >= 1000;

                    return Row(
                      children: [
                        if (!zen) const ActivityBar(),
                        if (showExplorer) ...[
                          Container(
                            width: 260,
                            color: cs.surface,
                            child: const Column(
                              children: [
                                _GroupHeader(label: 'Explorer'),
                                Expanded(child: FileTree()),
                              ],
                            ),
                          ),
                          const VerticalDivider(width: 1),
                        ],
                        Expanded(
                          child: Column(
                            children: [
                              hiide_tab_bar.TabBar(),
                              const Breadcrumb(),
                              Expanded(
                                child: Row(
                                  children: [
                                    Expanded(child: widget.child),
                                    if (showAiSidebar)
                                      Container(
                                        width: 300,
                                        decoration: BoxDecoration(
                                          border: Border(
                                            left: BorderSide(
                                              color: cs.outlineVariant,
                                              width:
                                                  DesignTokens.borderWidthThin,
                                            ),
                                          ),
                                        ),
                                        child: const AiChatSidebar(),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              if (!zen) const SidePanel(),
              if (!zen) const BottomPanel(),
              if (!zen) const StatusBar(),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  final String label;
  const _GroupHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: DesignTokens.space3, vertical: DesignTokens.space2),
      width: double.infinity,
      height: 32,
      color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: DesignTokens.fontSizeSM,
              fontWeight: DesignTokens.fontWeightSemibold,
            ),
          ),
          const Spacer(),
          Icon(Icons.more_vert,
              size: DesignTokens.iconSM, color: cs.onSurfaceVariant),
        ],
      ),
    );
  }
}
