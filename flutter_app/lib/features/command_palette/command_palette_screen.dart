import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/design_system/tokens.dart';
import '../../shared/providers/editor_providers.dart';
import '../../features/bottom_panels/bottom_panels.dart';
import '../../shared/widgets/ide_shell.dart';
import '../../shared/widgets/ai_widgets.dart';

final commandPaletteQueryProvider = StateProvider<String>((ref) => '');
final commandPaletteFilterProvider = Provider<List<Map<String, String>>>((ref) {
  final query = ref.watch(commandPaletteQueryProvider).toLowerCase();
  final allCommands = [
    {
      'label': 'View: Toggle Terminal',
      'shortcut': 'Ctrl+`',
      'category': 'View'
    },
    {'label': 'View: Toggle Sidebar', 'shortcut': 'Ctrl+B', 'category': 'View'},
    {'label': 'View: Toggle AI Chat', 'shortcut': 'Ctrl+J', 'category': 'View'},
    {
      'label': 'View: Toggle Minimap',
      'shortcut': 'Ctrl+Alt+M',
      'category': 'View'
    },
    {'label': 'File: Save', 'shortcut': 'Ctrl+S', 'category': 'File'},
    {
      'label': 'File: Save As...',
      'shortcut': 'Ctrl+Shift+S',
      'category': 'File'
    },
    {'label': 'File: Close Editor', 'shortcut': 'Ctrl+W', 'category': 'File'},
    {
      'label': 'Edit: Format Document',
      'shortcut': 'Shift+Alt+F',
      'category': 'Edit'
    },
    {'label': 'Edit: Go to Definition', 'shortcut': 'F12', 'category': 'Edit'},
    {'label': 'Edit: Find', 'shortcut': 'Ctrl+F', 'category': 'Edit'},
    {'label': 'Edit: Replace', 'shortcut': 'Ctrl+H', 'category': 'Edit'},
    {'label': 'Go: Go to File', 'shortcut': 'Ctrl+P', 'category': 'Go'},
    {'label': 'Go: Go to Line', 'shortcut': 'Ctrl+G', 'category': 'Go'},
    {'label': 'Go: Go to Symbol', 'shortcut': 'Ctrl+Shift+O', 'category': 'Go'},
    {
      'label': 'Terminal: Run Task',
      'shortcut': 'Ctrl+Shift+B',
      'category': 'Terminal'
    },
    {
      'label': 'Terminal: New Terminal',
      'shortcut': 'Ctrl+Shift+`',
      'category': 'Terminal'
    },
    {'label': 'AI: Explain Code', 'shortcut': 'Ctrl+Shift+E', 'category': 'AI'},
    {
      'label': 'AI: Generate Tests',
      'shortcut': 'Ctrl+Shift+T',
      'category': 'AI'
    },
    {'label': 'AI: Refactor', 'shortcut': 'Ctrl+Shift+R', 'category': 'AI'},
  ];

  if (query.isEmpty) return allCommands;
  return allCommands.where((cmd) {
    final label = cmd['label']!.toLowerCase();
    final category = cmd['category']!.toLowerCase();
    return label.contains(query) || category.contains(query);
  }).toList();
});

class CommandPaletteScreen extends ConsumerWidget {
  const CommandPaletteScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final commands = ref.watch(commandPaletteFilterProvider);

    return IdeShell(
      showAiSidebar: false,
      child: Container(
        color: cs.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AiPageHeader(
                icon: Icons.keyboard_command_key, title: 'Command Palette'),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: DesignTokens.space4),
              child: TextField(
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Type a command...',
                  prefixIcon: Icon(Icons.search,
                      size: DesignTokens.iconMD, color: cs.onSurfaceVariant),
                ),
                onChanged: (value) {
                  ref.read(commandPaletteQueryProvider.notifier).state = value;
                },
              ),
            ),
            const SizedBox(height: DesignTokens.space3),
            Expanded(
              child: ListView.builder(
                padding:
                    const EdgeInsets.symmetric(horizontal: DesignTokens.space4),
                itemCount: commands.length,
                itemBuilder: (context, index) {
                  final cmd = commands[index];
                  return _CommandItem(
                    label: cmd['label']!,
                    shortcut: cmd['shortcut']!,
                    onTap: () {
                      Navigator.of(context).pop();
                      _executeCommand(context, ref, cmd['label']!);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _executeCommand(BuildContext context, WidgetRef ref, String label) {
  switch (label) {
    case 'View: Toggle Terminal':
      final current = ref.read(selectedBottomPanelProvider);
      ref.read(selectedBottomPanelProvider.notifier).state =
          current == 'terminal' ? null : 'terminal';
      break;
    case 'View: Toggle Sidebar':
      ref.read(zenModeProvider.notifier).state = !ref.read(zenModeProvider);
      break;
    case 'View: Toggle AI Chat':
      final current = ref.read(selectedBottomPanelProvider);
      ref.read(selectedBottomPanelProvider.notifier).state =
          current == 'ai_chat' ? null : 'ai_chat';
      break;
    case 'File: Save':
      // Handled by IdeShell
      break;
    case 'Edit: Find':
      ref.read(findBarOpenProvider.notifier).state = true;
      ref.read(findReplaceModeProvider.notifier).state = false;
      break;
    case 'Edit: Replace':
      ref.read(findBarOpenProvider.notifier).state = true;
      ref.read(findReplaceModeProvider.notifier).state = true;
      break;
    case 'Go: Go to File':
      context.go('/quick-open');
      break;
    case 'Go: Go to Line':
      break;
    default:
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Executed: $label'),
            duration: const Duration(seconds: 1)),
      );
  }
}

class _CommandItem extends StatelessWidget {
  final String label;
  final String shortcut;
  final VoidCallback? onTap;

  const _CommandItem({required this.label, required this.shortcut, this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
            vertical: DesignTokens.space2, horizontal: DesignTokens.space3),
        decoration: BoxDecoration(
          border: Border(
              bottom: BorderSide(
                  color: cs.outlineVariant,
                  width: DesignTokens.borderWidthThin)),
        ),
        child: Row(
          children: [
            Expanded(
                child: Text(label,
                    style: TextStyle(
                        color: cs.onSurface,
                        fontSize: DesignTokens.fontSizeMD))),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: DesignTokens.space2,
                  vertical: DesignTokens.space1),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(DesignTokens.radiusSM),
                border: Border.all(color: cs.outlineVariant),
              ),
              child: Text(shortcut,
                  style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: DesignTokens.fontSizeXS)),
            ),
          ],
        ),
      ),
    );
  }
}
