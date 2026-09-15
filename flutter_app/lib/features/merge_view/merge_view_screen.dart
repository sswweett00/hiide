import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/design_system/tokens.dart';
import '../../shared/widgets/ide_shell.dart';
import '../../shared/widgets/ai_widgets.dart';

class MergeViewScreen extends StatefulWidget {
  const MergeViewScreen({super.key});

  @override
  State<MergeViewScreen> createState() => _MergeViewScreenState();
}

class _MergeViewScreenState extends State<MergeViewScreen> {
  bool _accepted = false;

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
              icon: Icons.merge_type,
              title: 'Merge View',
              actions: [
                if (_accepted)
                  const Chip(
                    avatar: Icon(Icons.check_circle, size: 16, color: Color(0xFF3FB950)),
                    label: Text('Merged'),
                  )
                else
                  ElevatedButton.icon(
                    onPressed: () {
                      setState(() => _accepted = true);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Merge accepted')),
                      );
                    },
                    icon: Icon(Icons.check, size: DesignTokens.iconSM),
                    label: const Text('Accept Merge'),
                  ),
              ],
            ),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      color: const Color(0xFF0D1117),
                      padding: const EdgeInsets.all(DesignTokens.space4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Incoming',
                              style: TextStyle(
                                  color: cs.onSurfaceVariant,
                                  fontSize: DesignTokens.fontSizeSM)),
                          const SizedBox(height: DesignTokens.space2),
                          Text('+ static ThemeData get lightTheme {',
                              style: TextStyle(
                                  color: const Color(0xFF3FB950),
                                  fontFamily: 'JetBrains Mono',
                                  fontSize: DesignTokens.fontSizeMD)),
                        ],
                      ),
                    ),
                  ),
                  VerticalDivider(color: cs.outlineVariant, width: 1),
                  Expanded(
                    child: Container(
                      color: const Color(0xFF0D1117),
                      padding: const EdgeInsets.all(DesignTokens.space4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Current',
                              style: TextStyle(
                                  color: cs.onSurfaceVariant,
                                  fontSize: DesignTokens.fontSizeSM)),
                          const SizedBox(height: DesignTokens.space2),
                          Text('- static ThemeData get darkTheme {',
                              style: TextStyle(
                                  color: const Color(0xFFF85149),
                                  fontFamily: 'JetBrains Mono',
                                  fontSize: DesignTokens.fontSizeMD)),
                        ],
                      ),
                    ),
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
