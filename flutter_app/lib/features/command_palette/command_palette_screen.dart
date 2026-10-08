
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_system/tokens.dart';
import '../bottom_panels/bottom_panels.dart';
import '../../shared/widgets/ai_widgets.dart';

final commandPaletteQueryProvider = StateProvider<String>((ref) => '');

const _allCommands = <Map<String, String>>[
  {'label': 'Agent: New Task', 'shortcut': '', 'category': 'Agent'},
  {'label': 'View: Toggle Terminal', 'shortcut': 'Ctrl+`', 'category': 'View'},
  {'label': 'View: Toggle AI Chat', 'shortcut': 'Ctrl+J', 'category': 'View'},
  {'label': 'Go: Agent Workspace', 'shortcut': '', 'category': 'Go'},
  {'label': 'Go: Explorer', 'shortcut': 'Ctrl+Shift+E', 'category': 'Go'},
  {'label': 'Go: Search', 'shortcut': 'Ctrl+Shift+F', 'category': 'Go'},
  {'label': 'Go: Source Control', 'shortcut': 'Ctrl+Shift+G', 'category': 'Go'},
  {'label': 'Go: Dashboard', 'shortcut': '', 'category': 'Go'},
  {'label': 'Help: Keyboard Shortcuts', 'shortcut': '', 'category': 'Help'},
  {'label': 'Help: About Hiide', 'shortcut': '', 'category': 'Help'},
];

final commandPaletteFilterProvider = Provider<List<Map<String, String>>>((ref) {
  final query = ref.watch(commandPaletteQueryProvider).trim().toLowerCase();
  if (query.isEmpty) return _allCommands;
  return _allCommands.where((command) {
    final label = command['label']!.toLowerCase();
    final category = command['category']!.toLowerCase();
    return label.contains(query) || category.contains(query);
  }).toList();
});

class CommandPaletteScreen extends ConsumerStatefulWidget {
  const CommandPaletteScreen({super.key});
  @override
  ConsumerState<CommandPaletteScreen> createState() => _CommandPaletteScreenState();
}

class _CommandPaletteScreenState extends ConsumerState<CommandPaletteScreen> {
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    ref.read(commandPaletteQueryProvider.notifier).state = '';
  }

  void _moveSelection(int delta) {
    final commands = ref.read(commandPaletteFilterProvider);
    if (commands.isEmpty) return;
    setState(() {
      _selectedIndex = (_selectedIndex + delta) % commands.length;
      if (_selectedIndex < 0) _selectedIndex = commands.length - 1;
    });
  }

  void _executeSelected() {
    final commands = ref.read(commandPaletteFilterProvider);
    if (commands.isEmpty) return;
    final label = commands[_selectedIndex]['label']!;
    Navigator.of(context).pop();
    _executeCommand(context, ref, label);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final commands = ref.watch(commandPaletteFilterProvider);
    if (_selectedIndex >= commands.length && commands.isNotEmpty) {
      _selectedIndex = commands.length - 1;
    }

    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).maybePop();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          _moveSelection(1);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          _moveSelection(-1);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.enter) {
          _executeSelected();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        color: cs.surface,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const AiPageHeader(icon: Icons.keyboard_command_key, title: 'Command Palette'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: DesignTokens.space4),
              child: TextField(
                autofocus: true,
                onChanged: (value) {
                  ref.read(commandPaletteQueryProvider.notifier).state = value;
                  setState(() => _selectedIndex = 0);
                },
                decoration: InputDecoration(
                  hintText: 'Type a command…',
                  prefixIcon: Icon(Icons.search, size: DesignTokens.iconMD, color: cs.onSurfaceVariant),
                ),
              ),
            ),
            const SizedBox(height: DesignTokens.space3),
            ...commands.map((command) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: DesignTokens.space4),
                  child: _CommandItem(
                    label: command['label']!,
                    shortcut: command['shortcut']!,
                    selected: commands.indexOf(command) == _selectedIndex,
                    onTap: () {
                      Navigator.of(context).pop();
                      _executeCommand(context, ref, command['label']!);
                    },
                  ),
                )),
            const SizedBox(height: DesignTokens.space4),
          ],
        ),
      ),
    );
  }
}

class _CommandItem extends StatelessWidget {
  final String label;
  final String shortcut;
  final bool selected;
  final VoidCallback? onTap;
  const _CommandItem({required this.label, required this.shortcut, required this.selected, this.onTap});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: DesignTokens.space2, horizontal: DesignTokens.space3),
        decoration: BoxDecoration(
          color: selected ? cs.primary.withValues(alpha: 0.10) : Colors.transparent,
          border: Border(bottom: BorderSide(color: cs.outlineVariant, width: DesignTokens.borderWidthThin)),
        ),
        child: Row(
          children: [
            Expanded(child: Text(label, style: TextStyle(color: selected ? cs.primary : cs.onSurface, fontSize: DesignTokens.fontSizeMD))),
            if (shortcut.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: DesignTokens.space2, vertical: DesignTokens.space1),
                decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(DesignTokens.radiusSM), border: Border.all(color: cs.outlineVariant)),
                child: Text(shortcut, style: TextStyle(color: cs.onSurfaceVariant, fontSize: DesignTokens.fontSizeXS)),
              ),
          ],
        ),
      ),
    );
  }
}
