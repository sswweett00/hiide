import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/design_system/tokens.dart';
import '../../shared/widgets/ide_shell.dart';
import '../../shared/widgets/ai_widgets.dart';class OutputScreen extends ConsumerStatefulWidget {
  const OutputScreen({super.key});

  @override
  ConsumerState<OutputScreen> createState() => _OutputScreenState();
}

class _OutputScreenState extends ConsumerState<OutputScreen> {
  String _selectedChannel = 'main';
  final List<Map<String, String>> _logs = [
    {'time': '12:34:56', 'text': 'Building Hiide...', 'type': 'info'},
    {'time': '12:34:56', 'text': 'Succeeded after 2.3s', 'type': 'success'},
    {'time': '12:35:01', 'text': 'Running tests...', 'type': 'info'},
    {'time': '12:35:02', 'text': '142 tests passed', 'type': 'success'},
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return IdeShell(
      showAiSidebar: true,
      child: Container(
        color: cs.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AiPageHeader(
              icon: Icons.output,
              title: 'Output',
              actions: [
                DropdownButton<String>(
                  value: _selectedChannel,
                  items: const [
                    DropdownMenuItem(value: 'main', child: Text('main')),
                    DropdownMenuItem(value: 'task', child: Text('task')),
                    DropdownMenuItem(value: 'build', child: Text('build')),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _selectedChannel = value);
                    }
                  },
                  style: TextStyle(
                      color: cs.onSurface, fontSize: DesignTokens.fontSizeSM),
                ),
                IconButton(
                  icon: Icon(Icons.delete_sweep,
                      size: DesignTokens.iconSM, color: cs.onSurfaceVariant),
                  onPressed: () => setState(() => _logs.clear()),
                  tooltip: 'Clear output',
                ),
              ],
            ),
            Expanded(
              child: Container(
                color: const Color(0xFF0D1117),
                child: ListView(
                  padding: const EdgeInsets.all(DesignTokens.space3),
                  children: _logs.map((log) {
                    final color = log['type'] == 'success'
                        ? const Color(0xFF3FB950)
                        : cs.onSurface;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        '[${log['time']}] ${log['text']}',
                        style: TextStyle(
                            color: color,
                            fontFamily: 'JetBrains Mono',
                            fontSize: DesignTokens.fontSizeSM),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
