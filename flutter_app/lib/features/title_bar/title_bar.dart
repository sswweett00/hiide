import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/backend/settings_service.dart';
import '../../core/design_system/tokens.dart';
import '../../shared/models/editor_tab.dart';
import '../../shared/providers/editor_providers.dart';
import '../../features/bottom_panels/bottom_panels.dart';

class TitleBar extends ConsumerWidget {
  const TitleBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      height: 32,
      color: cs.surface,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Below ~560px there isn't room for the menu row, so keep only
          // the app logo, the mode slider and the window controls.
          final showMenus = constraints.maxWidth >= 720;
          final showSecondaryActions = constraints.maxWidth >= 520;
          final showModeSlider = constraints.maxWidth >= 440;

          return Row(
            children: [
              _Logo(),
              if (showMenus) _MenuBar(),
              const Spacer(),
              if (showSecondaryActions) ...[
                const _RecentFilesButton(),
                const SizedBox(width: DesignTokens.space1),
                const _ZenToggle(),
                const SizedBox(width: DesignTokens.space2),
              ],
              if (showModeSlider) const _ModeSlider(),
              if (showModeSlider)
                const SizedBox(width: DesignTokens.space3),
              _WindowControls(),
            ],
          );
        },
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: DesignTokens.space2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.auto_awesome,
            size: DesignTokens.iconSM,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: DesignTokens.space1),
          Text(
            'HIIDE',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontWeight: FontWeight.bold,
              fontSize: DesignTokens.fontSizeSM,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _MenuButton(
          label: 'File',
          items: const [
            _MenuItem(label: 'New File', action: 'new_file', shortcut: 'Ctrl+N'),
            _MenuItem(label: 'Quick Open', action: 'quick_open', shortcut: 'Ctrl+P'),
            _MenuItem(label: '', action: '', isDivider: true),
            _MenuItem(label: 'Save', action: 'save', shortcut: 'Ctrl+S'),
            _MenuItem(label: 'Save As...', action: 'save_as', shortcut: 'Ctrl+Shift+S'),
            _MenuItem(label: '', action: '', isDivider: true),
            _MenuItem(label: 'Open Workspace...', action: 'open_workspace'),
            _MenuItem(label: '', action: '', isDivider: true),
            _MenuItem(label: 'Settings', action: 'settings', shortcut: 'Ctrl+,'),
          ],
        ),
        _MenuButton(
          label: 'Edit',
          items: const [
            _MenuItem(label: 'Undo', action: 'undo', shortcut: 'Ctrl+Z'),
            _MenuItem(label: 'Redo', action: 'redo', shortcut: 'Ctrl+Y'),
            _MenuItem(label: '', action: '', isDivider: true),
            _MenuItem(label: 'Find', action: 'find', shortcut: 'Ctrl+F'),
            _MenuItem(label: 'Replace', action: 'replace', shortcut: 'Ctrl+H'),
            _MenuItem(label: '', action: '', isDivider: true),
            _MenuItem(label: 'Format Document', action: 'format', shortcut: 'Shift+Alt+F'),
          ],
        ),
        _MenuButton(
          label: 'View',
          items: const [
            _MenuItem(label: 'Toggle Sidebar', action: 'toggle_sidebar', shortcut: 'Ctrl+B'),
            _MenuItem(label: 'Toggle Terminal', action: 'toggle_terminal', shortcut: 'Ctrl+`'),
            _MenuItem(label: 'Toggle AI Panel', action: 'toggle_ai', shortcut: 'Ctrl+Shift+A'),
            _MenuItem(label: '', action: '', isDivider: true),
            _MenuItem(label: 'Zen Mode', action: 'zen_mode', shortcut: 'Ctrl+K Z'),
          ],
        ),
        _MenuButton(
          label: 'Go',
          items: const [
            _MenuItem(label: 'Command Palette...', action: 'command_palette', shortcut: 'Ctrl+Shift+P'),
            _MenuItem(label: 'Go to Line...', action: 'goto_line', shortcut: 'Ctrl+G'),
            _MenuItem(label: '', action: '', isDivider: true),
            _MenuItem(label: 'Explorer', action: 'explorer', shortcut: 'Ctrl+Shift+E'),
            _MenuItem(label: 'Search', action: 'search', shortcut: 'Ctrl+Shift+F'),
            _MenuItem(label: 'Source Control', action: 'source_control', shortcut: 'Ctrl+Shift+G'),
            _MenuItem(label: 'Dashboard', action: 'dashboard'),
          ],
        ),
        _MenuButton(
          label: 'Help',
          items: const [
            _MenuItem(label: 'Run Task', action: 'run_task'),
            _MenuItem(label: 'Keyboard Shortcuts', action: 'keyboard_shortcuts'),
            _MenuItem(label: '', action: '', isDivider: true),
            _MenuItem(label: 'About Hiide', action: 'about'),
          ],
        ),
      ],
    );
  }
}

class _MenuItem {
  final String label;
  final String action;
  final String shortcut;
  final bool isDivider;

  const _MenuItem({
    required this.label,
    required this.action,
    this.shortcut = '',
    this.isDivider = false,
  });
}

class _MenuButton extends StatelessWidget {
  final String label;
  final List<_MenuItem> items;

  const _MenuButton({required this.label, required this.items});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return MenuAnchor(
      menuChildren: items.map((item) {
        if (item.isDivider) {
          return const Divider(height: 1);
        }
        return MenuItemButton(
          trailingIcon: item.shortcut.isNotEmpty
              ? Padding(
                  padding: const EdgeInsets.only(left: 24),
                  child: Text(
                    item.shortcut,
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: DesignTokens.fontSizeXS,
                      fontFamily: 'JetBrains Mono',
                    ),
                  ),
                )
              : null,
          onPressed: () => _executeAction(context, item.action),
          child: Text(item.label),
        );
      }).toList(),
      builder: (context, controller, child) {
        return InkWell(
          onTap: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: DesignTokens.space3, vertical: DesignTokens.space1),
            child: Text(
              label,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: DesignTokens.fontSizeSM,
                fontWeight: DesignTokens.fontWeightRegular,
              ),
            ),
          ),
        );
      },
    );
  }

  void _executeAction(BuildContext context, String action) {
    final ref = ProviderScope.containerOf(context);
    switch (action) {
      case 'new_file':
        final openTabs = ref.read(openTabsProvider);
        final newTab = EditorTab(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          title: 'Untitled-${openTabs.length + 1}',
          path: 'Untitled-${openTabs.length + 1}',
          content: '',
          icon: Icons.description_outlined,
        );
        ref.read(openTabsProvider.notifier).state = [...openTabs, newTab];
        ref.read(activeTabIdProvider.notifier).state = newTab.id;
        break;
      case 'quick_open':
        context.go('/quick-open');
        break;
      case 'save':
      case 'save_as':
        final activeId = ref.read(activeTabIdProvider);
        final tabs = ref.read(openTabsProvider);
        final activeTab = tabs.where((t) => t.id == activeId).firstOrNull;
        if (activeTab != null &&
            activeTab.path != null &&
            activeTab.path!.isNotEmpty) {
          ref
              .read(workspaceServiceProvider)
              .writeFile(activeTab.path!, activeTab.content);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                  content: Text('Saved ${activeTab.title}'),
                  duration: const Duration(seconds: 1)),
            );
          }
        }
        break;
      case 'open_workspace':
        context.go('/workspace-picker');
        break;
      case 'settings':
        context.go('/settings');
        break;
      case 'undo':
      case 'redo':
        break;
      case 'find':
        ref.read(findBarOpenProvider.notifier).state = true;
        ref.read(findReplaceModeProvider.notifier).state = false;
        break;
      case 'replace':
        ref.read(findBarOpenProvider.notifier).state = true;
        ref.read(findReplaceModeProvider.notifier).state = true;
        break;
      case 'format':
        final activeId = ref.read(activeTabIdProvider);
        if (activeId != null && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Code formatted'),
                duration: Duration(seconds: 1)),
          );
        }
        break;
      case 'toggle_sidebar':
        ref.read(zenModeProvider.notifier).state = !ref.read(zenModeProvider);
        break;
      case 'toggle_terminal':
        final current = ref.read(selectedBottomPanelProvider);
        ref.read(selectedBottomPanelProvider.notifier).state =
            current == 'terminal' ? null : 'terminal';
        break;
      case 'toggle_ai':
        final current = ref.read(selectedBottomPanelProvider);
        ref.read(selectedBottomPanelProvider.notifier).state =
            current == 'ai_chat' ? null : 'ai_chat';
        break;
      case 'zen_mode':
        ref.read(zenModeProvider.notifier).state = !ref.read(zenModeProvider);
        break;
      case 'command_palette':
        context.go('/command-palette');
        break;
      case 'goto_line':
        context.go('/command-palette');
        break;
      case 'explorer':
        context.go('/explorer');
        break;
      case 'search':
        context.go('/search');
        break;
      case 'source_control':
        context.go('/source-control');
        break;
      case 'dashboard':
        context.go('/dashboard');
        break;
      case 'run_task':
        context.go('/command-palette');
        break;
      case 'keyboard_shortcuts':
        context.go('/keyboard-shortcuts');
        break;
      case 'about':
        showAboutDialog(
          context: context,
          applicationName: 'Hiide AI IDE',
          applicationVersion: '0.1.0',
          applicationLegalese: '© 2026 Hiide IDE Team',
        );
        break;
    }
  }
}

class _WindowControls extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _WindowControl(icon: Icons.minimize, onTap: () {}),
        _WindowControl(icon: Icons.crop_square, onTap: () {}),
        _WindowControl(
          icon: Icons.close,
          onTap: () {},
          isClose: true,
        ),
      ],
    );
  }
}

class _WindowControl extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool isClose;

  const _WindowControl(
      {required this.icon, required this.onTap, this.isClose = false});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          width: 46,
          height: double.infinity,
          color: isClose ? const Color(0xFFF85149) : Colors.transparent,
          child: Icon(
            icon,
            size: DesignTokens.iconSM,
            color: isClose ? Colors.white : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Opens the recent-files popup: the last 10 opened files, most recent
/// first; tapping one reopens it as the active tab.
class _RecentFilesButton extends ConsumerWidget {
  const _RecentFilesButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final recents = ref.watch(recentFilesProvider);

    return _TitleBarIconButton(
      icon: Icons.history,
      tooltip: 'Son Dosyalar',
      onTap: () async {
        if (recents.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Henüz açılmış dosya yok.'),
            duration: Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
            width: 260,
          ));
          return;
        }
        final selected = await showMenu<String>(
          context: context,
          position: RelativeRect.fromLTRB(0, 34, 0, 0),
          items: [
            for (final recent in recents)
              PopupMenuItem<String>(
                value: recent.path,
                child: SizedBox(
                  width: 280,
                  child: Row(
                    children: [
                      Icon(iconForFilePath(recent.path),
                          size: DesignTokens.iconSM,
                          color: cs.onSurfaceVariant),
                      const SizedBox(width: DesignTokens.space2),
                      Expanded(
                        child: Text(
                          recent.title,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: cs.onSurface,
                            fontSize: DesignTokens.fontSizeSM,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
        if (selected != null) {
          await openFileInTabs(ref, selected);
        }
      },
    );
  }
}

/// Toggles zen (focus) mode: hides every chrome panel so only the editor
/// (+ AI chat) remains.
class _ZenToggle extends ConsumerWidget {
  const _ZenToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zen = ref.watch(zenModeProvider);
    return _TitleBarIconButton(
      icon: zen ? Icons.fullscreen_exit : Icons.fullscreen,
      tooltip: zen ? 'Zen modundan çık' : 'Zen modu (odaklanma)',
      onTap: () => ref.read(zenModeProvider.notifier).state = !zen,
      active: zen,
    );
  }
}

class _TitleBarIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;

  const _TitleBarIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: active
                  ? cs.primary.withValues(alpha: DesignTokens.opacitySelected)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(DesignTokens.radiusSM),
            ),
            child: Icon(
              icon,
              size: DesignTokens.iconSM,
              color: active ? cs.primary : cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// Sliding pill switch between the two UI styles: **AI** (native full-screen
/// chat) and **IDE** (classic explorer + editor + terminal layout). The thumb
/// animates to the active side; tapping anywhere flips the mode.
class _ModeSlider extends ConsumerWidget {
  const _ModeSlider();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final mode = ref.watch(uiModeProvider);
    final isAi = mode == UiMode.aiNative;

    return Tooltip(
      message: isAi
          ? 'AI native modu — IDE görünümüne geç'
          : 'IDE modu — yalnızca yapay zeka sohbetine geç',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () async {
            final next = isAi ? UiMode.ide : UiMode.aiNative;
            ref.read(uiModeProvider.notifier).state = next;
            // Persist so the choice survives a restart. A storage failure
            // (tests, web without a channel) must not break the switch —
            // the mode still applies for the session.
            try {
              await settingsService.setUiMode(next);
            } catch (_) {}
          },
          child: Container(
            width: 116,
            height: 24,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(DesignTokens.radiusFull),
              border: Border.all(color: cs.outlineVariant),
            ),
            child: Stack(
              children: [
                // Sliding thumb: gradient pill that glides to the active side.
                AnimatedAlign(
                  duration: DesignTokens.durationNormal,
                  curve: DesignTokens.curveEmphasized,
                  alignment:
                      isAi ? Alignment.centerLeft : Alignment.centerRight,
                  child: Container(
                    width: 55,
                    decoration: BoxDecoration(
                      gradient: DesignTokens.aiGradient,
                      borderRadius:
                          BorderRadius.circular(DesignTokens.radiusFull),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: _ModeLabel(
                        icon: Icons.auto_awesome,
                        label: 'AI',
                        active: isAi,
                        cs: cs,
                      ),
                    ),
                    Expanded(
                      child: _ModeLabel(
                        icon: Icons.code,
                        label: 'IDE',
                        active: !isAi,
                        cs: cs,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final ColorScheme cs;

  const _ModeLabel({
    required this.icon,
    required this.label,
    required this.active,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? Colors.white : cs.onSurfaceVariant;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: DesignTokens.iconXS, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: DesignTokens.fontSizeXS,
            fontWeight: DesignTokens.fontWeightSemibold,
          ),
        ),
      ],
    );
  }
}
