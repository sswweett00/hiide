import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_system/tokens.dart';
import '../../shared/models/editor_tab.dart';
import '../../shared/providers/editor_providers.dart';
import '../bottom_panels/bottom_panels.dart';
import '../../shared/widgets/ai_widgets.dart';
import '../../shared/widgets/ide_shell.dart';

final commandPaletteQueryProvider = StateProvider<String>((ref) => '');

const _allCommands = <Map<String, String>>[
  {'label': 'View: Toggle Terminal', 'shortcut': 'Ctrl+`', 'category': 'View'},
  {'label': 'View: Toggle AI Chat', 'shortcut': 'Ctrl+J', 'category': 'View'},
  {'label': 'View: Toggle Zen Mode', 'shortcut': 'Ctrl+K Z', 'category': 'View'},
  {'label': 'View: Toggle Minimap', 'shortcut': 'Ctrl+Alt+M', 'category': 'View'},
  {'label': 'File: Save', 'shortcut': 'Ctrl+S', 'category': 'File'},
  {'label': 'File: Close Editor', 'shortcut': 'Ctrl+W', 'category': 'File'},
  {'label': 'Edit: Find', 'shortcut': 'Ctrl+F', 'category': 'Edit'},
  {'label': 'Edit: Replace', 'shortcut': 'Ctrl+H', 'category': 'Edit'},
  {'label': 'Go: Go to File', 'shortcut': 'Ctrl+P', 'category': 'Go'},
  {'label': 'Go: Go to Line', 'shortcut': 'Ctrl+G', 'category': 'Go'},
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
    Navigator.of(context).pop();
    _executeCommand(context, ref, commands[_selectedIndex]['label']!);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final commands = ref.watch(commandPaletteFilterProvider);
    if (_selectedIndex >= commands.length && commands.isNotEmpty) _selectedIndex = commands.length - 1;

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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
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
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: DesignTokens.space4),
                itemCount: commands.length,
                itemBuilder: (context, index) {
                  final command = commands[index];
                  return _CommandItem(
                    label: command['label']!,
                    shortcut: command['shortcut']!,
                    selected: index == _selectedIndex,
                    onTap: () {
                      Navigator.of(context).pop();
                      _executeCommand(context, ref, command['label']!);
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

Future<void> _saveActiveTab(WidgetRef ref, BuildContext context) async {
  final id = ref.read(activeTabIdProvider);
  final tabs = ref.read(openTabsProvider);
  if (id == null) return;
  final index = tabs.indexWhere((tab) => tab.id == id);
  if (index < 0) return;
  final tab = tabs[index];
  if (tab.path == null || tab.path!.isEmpty || tab.title.startsWith('Untitled')) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This tab has no file path yet.')));
    return;
  }
  try {
    await ref.read(workspaceServiceProvider).writeFile(tab.path!, tab.content);
    final updated = tab.copyWith(isModified: false);
    ref.read(openTabsProvider.notifier).state = List<EditorTab>.from(tabs)..[index] = updated;
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved ${tab.title}')));
  } catch (error) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $error')));
  }
}

Future<void> _showGoToLine(BuildContext context, WidgetRef ref) async {
  final controller = TextEditingController(text: '${ref.read(cursorLineProvider)}');
  try {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Go to Line'),
        content: TextField(controller: controller, autofocus: true, keyboardType: TextInputType.number),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final line = int.tryParse(controller.text.trim());
              if (line != null && line > 0) ref.read(cursorLineProvider.notifier).state = line;
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Go'),
          ),
        ],
      ),
    );
  } finally {
    controller.dispose();
  }
}

void _executeCommand(BuildContext context, WidgetRef ref, String label) {
  switch (label) {
    case 'View: Toggle Terminal':
      final current = ref.read(selectedBottomPanelProvider);
      ref.read(selectedBottomPanelProvider.notifier).state = current == 'terminal' ? null : 'terminal';
      break;
    case 'View: Toggle AI Chat':
      final current = ref.read(selectedBottomPanelProvider);
      ref.read(selectedBottomPanelProvider.notifier).state = current == 'ai_chat' ? null : 'ai_chat';
      break;
    case 'View: Toggle Zen Mode':
      ref.read(zenModeProvider.notifier).state = !ref.read(zenModeProvider);
      break;
    case 'View: Toggle Minimap':
      final settings = Map<String, dynamic>.from(ref.read(settingsProvider));
      settings['minimap'] = !(settings['minimap'] == true);
      ref.read(settingsProvider.notifier).state = settings;
      break;
    case 'File: Save':
      _saveActiveTab(ref, context);
      break;
    case 'File: Close Editor':
      final id = ref.read(activeTabIdProvider);
      final tabs = ref.read(openTabsProvider);
      if (id != null) {
        final updated = tabs.where((tab) => tab.id != id).toList();
        ref.read(openTabsProvider.notifier).state = updated;
        ref.read(activeTabIdProvider.notifier).state = updated.isEmpty ? null : updated.last.id;
      }
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
      _showGoToLine(context, ref);
      break;
    case 'Go: Explorer':
      context.go('/explorer');
      break;
    case 'Go: Search':
      context.go('/search');
      break;
    case 'Go: Source Control':
      context.go('/source-control');
      break;
    case 'Go: Dashboard':
      context.go('/dashboard');
      break;
    case 'Help: Keyboard Shortcuts':
      context.go('/keyboard-shortcuts');
      break;
    case 'Help: About Hiide':
      showAboutDialog(context: context, applicationName: 'Hiide AI IDE', applicationVersion: '0.1.0');
      break;
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
