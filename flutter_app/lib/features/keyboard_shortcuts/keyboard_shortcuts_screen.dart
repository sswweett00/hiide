import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/design_system/tokens.dart';
import '../../shared/widgets/ide_shell.dart';
import '../../shared/widgets/ai_widgets.dart';

final keyboardShortcutsProvider =
    StateProvider<List<Map<String, String>>>((ref) => [
          {
            'command': 'Toggle Sidebar',
            'shortcut': 'Ctrl+B',
            'category': 'View'
          },
          {
            'command': 'Command Palette',
            'shortcut': 'Ctrl+Shift+P',
            'category': 'View'
          },
          {'command': 'Quick Open', 'shortcut': 'Ctrl+P', 'category': 'Go'},
          {'command': 'Save', 'shortcut': 'Ctrl+S', 'category': 'File'},
          {'command': 'Find', 'shortcut': 'Ctrl+F', 'category': 'Edit'},
          {'command': 'Replace', 'shortcut': 'Ctrl+H', 'category': 'Edit'},
          {
            'command': 'Toggle Terminal',
            'shortcut': 'Ctrl+`',
            'category': 'View'
          },
          {
            'command': 'Format Document',
            'shortcut': 'Shift+Alt+F',
            'category': 'Edit'
          },
          {'command': 'Go to Line', 'shortcut': 'Ctrl+G', 'category': 'Go'},
          {
            'command': 'Go to Symbol',
            'shortcut': 'Ctrl+Shift+O',
            'category': 'Go'
          },
          {'command': 'New File', 'shortcut': 'Ctrl+N', 'category': 'File'},
          {'command': 'Close Editor', 'shortcut': 'Ctrl+W', 'category': 'File'},
          {'command': 'Zoom In', 'shortcut': 'Ctrl+=', 'category': 'View'},
          {'command': 'Zoom Out', 'shortcut': 'Ctrl+-', 'category': 'View'},
          {'command': 'Reset Zoom', 'shortcut': 'Ctrl+0', 'category': 'View'},
          {
            'command': 'Toggle Full Screen',
            'shortcut': 'F11',
            'category': 'View'
          },
          {'command': 'Toggle AI Chat', 'shortcut': 'Ctrl+J', 'category': 'AI'},
          {
            'command': 'Explain Code',
            'shortcut': 'Ctrl+Shift+E',
            'category': 'AI'
          },
          {
            'command': 'Generate Tests',
            'shortcut': 'Ctrl+Shift+T',
            'category': 'AI'
          },
        ]);

class KeyboardShortcutsScreen extends ConsumerWidget {
  const KeyboardShortcutsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final shortcuts = ref.watch(keyboardShortcutsProvider);

    return IdeShell(
      showAiSidebar: true,
      child: Container(
        color: cs.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AiPageHeader(
              icon: Icons.keyboard,
              title: 'Keyboard Shortcuts',
              actions: [
                OutlinedButton(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Keyboard shortcuts exported!'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  child: const Text('Export'),
                )
              ],
            ),
            Expanded(
              child: ListView(
                padding:
                    const EdgeInsets.symmetric(horizontal: DesignTokens.space4),
                children: [
                  for (final category in [
                    'View',
                    'File',
                    'Edit',
                    'Go',
                    'Terminal',
                    'AI'
                  ])
                    _ShortcutCategory(
                      title: category,
                      shortcuts: shortcuts
                          .where((s) => s['category'] == category)
                          .toList(),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShortcutCategory extends StatelessWidget {
  final String title;
  final List<Map<String, String>> shortcuts;

  const _ShortcutCategory({required this.title, required this.shortcuts});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: DesignTokens.space3),
          child: Text(
            title,
            style: TextStyle(
              color: cs.onSurface,
              fontSize: DesignTokens.fontSizeMD,
              fontWeight: DesignTokens.fontWeightSemibold,
            ),
          ),
        ),
        AiGlowCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: shortcuts.map((shortcut) {
              return _ShortcutRow(
                command: shortcut['command']!,
                shortcut: shortcut['shortcut']!,
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: DesignTokens.space6),
      ],
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  final String command;
  final String shortcut;

  const _ShortcutRow({required this.command, required this.shortcut});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(
          vertical: DesignTokens.space2, horizontal: DesignTokens.space3),
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(
                color: cs.outlineVariant, width: DesignTokens.borderWidthThin)),
      ),
      child: Row(
        children: [
          Expanded(
              child: Text(command,
                  style: TextStyle(
                      color: cs.onSurface, fontSize: DesignTokens.fontSizeMD))),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: DesignTokens.space2, vertical: DesignTokens.space1),
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: BorderRadius.circular(DesignTokens.radiusSM),
              border: Border.all(
                  color: cs.outlineVariant,
                  width: DesignTokens.borderWidthThin),
            ),
            child: Text(shortcut,
                style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: DesignTokens.fontSizeXS,
                    fontFamily: 'JetBrains Mono')),
          ),
        ],
      ),
    );
  }
}
