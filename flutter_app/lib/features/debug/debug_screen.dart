import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/design_system/tokens.dart';
import '../../shared/widgets/ide_shell.dart';
import '../../shared/widgets/ai_widgets.dart';

class DebugScreen extends ConsumerStatefulWidget {
  const DebugScreen({super.key});

  @override
  ConsumerState<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends ConsumerState<DebugScreen> {
  bool _isRunning = false;
  String _status = '';

  void _startDebugging(String config) {
    setState(() {
      _isRunning = true;
      _status = 'Starting $config...';
    });
    // Simulate debug session
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _isRunning = false;
          _status = '$config completed.';
        });
      }
    });
  }

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
              icon: Icons.bug_report_outlined,
              title: 'Run and Debug',
              actions: [
                ElevatedButton.icon(
                  onPressed: _isRunning
                      ? null
                      : () => _startDebugging('main'),
                  icon: Icon(
                    _isRunning ? Icons.stop : Icons.play_arrow,
                    size: DesignTokens.iconSM,
                  ),
                  label: Text(_isRunning ? 'Stop' : 'Start Debugging'),
                ),
              ],
            ),
            if (_status.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    horizontal: DesignTokens.space4, vertical: DesignTokens.space2),
                color: cs.surfaceContainerHighest,
                child: Text(_status,
                    style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: DesignTokens.fontSizeSM)),
              ),
            Expanded(
              child: ListView(
                padding:
                    const EdgeInsets.symmetric(horizontal: DesignTokens.space4),
                children: [
                  _DebugConfig(
                      name: 'Launch main.dart', type: 'Dart & Flutter'),
                  _DebugConfig(name: 'Launch test', type: 'Dart Test'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DebugConfig extends StatelessWidget {
  final String name;
  final String type;

  const _DebugConfig({required this.name, required this.type});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return AiGlowCard(
      margin: const EdgeInsets.only(bottom: DesignTokens.space2),
      child: Row(
        children: [
          Icon(Icons.play_arrow, size: DesignTokens.iconMD, color: cs.primary),
          const SizedBox(width: DesignTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: TextStyle(
                        color: cs.onSurface,
                        fontSize: DesignTokens.fontSizeMD)),
                Text(type,
                    style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: DesignTokens.fontSizeSM)),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.play_arrow,
                size: DesignTokens.iconSM, color: cs.primary),
            onPressed: () {
              // Find parent state and start debugging
              final state = context.findAncestorStateOfType<State<DebugScreen>>();
              if (state is _DebugScreenState) {
                state._startDebugging(name);
              }
            },
          ),
        ],
      ),
    );
  }
}
