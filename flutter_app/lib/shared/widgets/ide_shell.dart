import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_system/tokens.dart';
import '../../core/routing/router.dart';
import '../../shared/providers/workspace_providers.dart';
import '../../features/activity_bar/activity_bar.dart';
import '../../features/bottom_panels/bottom_panels.dart';
import '../../features/chat/ai_chat_sidebar.dart';
import '../../features/side_panels/side_panels.dart';
import 'file_tree.dart';

/// Shared non-editing shell for secondary AI-native surfaces.
///
/// Hiide has no human-editable code surface. This shell only exposes the
/// workspace tree, agent/chat surface and supporting runtime tools.
class IdeShell extends ConsumerWidget {
  final Widget child;
  final bool showAiSidebar;

  const IdeShell({
    super.key,
    required this.child,
    this.showAiSidebar = true,
  });

  KeyEventResult _handleKeyEvent(BuildContext context, WidgetRef ref, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final key = event.logicalKey;

    if (ctrl && shift && key == LogicalKeyboardKey.keyP) {
      context.go('/command-palette');
      return KeyEventResult.handled;
    }

    if (ctrl && !shift && key == LogicalKeyboardKey.keyJ) {
      final current = ref.read(selectedBottomPanelProvider);
      ref.read(selectedBottomPanelProvider.notifier).state =
          current == 'ai_chat' ? null : 'ai_chat';
      return KeyEventResult.handled;
    }

    if (ctrl && key == LogicalKeyboardKey.backquote) {
      final current = ref.read(selectedBottomPanelProvider);
      ref.read(selectedBottomPanelProvider.notifier).state =
          current == 'terminal' ? null : 'terminal';
      return KeyEventResult.handled;
    }

    if (ctrl && shift && key == LogicalKeyboardKey.keyG) {
      context.go('/source-control');
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final workspace = ref.watch(workspaceRootProvider);

    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) => _handleKeyEvent(context, ref, event),
      child: Scaffold(
        backgroundColor: cs.surface,
        body: Column(
          children: [
            Container(
              height: 56,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                border: Border(bottom: BorderSide(color: cs.outlineVariant)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.auto_awesome, size: 19),
                  const SizedBox(width: 9),
                  Text(
                    'Hiide AI Workspace',
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      workspace,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: DesignTokens.fontSizeXS,
                        fontFamily: 'JetBrains Mono',
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Workspace',
                    onPressed: () => context.go(RoutePath.workspacePicker.path),
                    icon: const Icon(Icons.folder_open_rounded, size: 18),
                  ),
                  IconButton(
                    tooltip: 'Command Palette',
                    onPressed: () => context.go(RoutePath.commandPalette.path),
                    icon: const Icon(Icons.bolt_rounded, size: 18),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final showExplorer =
                      constraints.maxWidth >= 980 && workspace.isNotEmpty;
                  final showChat =
                      showAiSidebar && constraints.maxWidth >= 900;

                  return Row(
                    children: [
                      if (showExplorer) ...[
                        const ActivityBar(),
                        Container(
                          width: 260,
                          color: cs.surface,
                          child: const Column(
                            children: [
                              _SectionHeader(label: 'Workspace'),
                              Expanded(child: FileTree()),
                            ],
                          ),
                        ),
                        const VerticalDivider(width: 1),
                      ],
                      Expanded(child: child),
                      if (showChat)
                        Container(
                          width: 320,
                          decoration: BoxDecoration(
                            border: Border(
                              left: BorderSide(
                                color: cs.outlineVariant,
                                width: DesignTokens.borderWidthThin,
                              ),
                            ),
                          ),
                          child: const AiChatSidebar(),
                        ),
                    ],
                  );
                },
              ),
            ),
            const SidePanel(),
            const BottomPanel(),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;

  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 32,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
        border: Border(bottom: BorderSide(color: cs.outlineVariant)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: cs.onSurfaceVariant,
          fontSize: DesignTokens.fontSizeXS,
          fontWeight: DesignTokens.fontWeightSemibold,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}
