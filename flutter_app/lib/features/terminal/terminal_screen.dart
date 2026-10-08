import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_system/tokens.dart';
import '../../core/backend/terminal_service.dart';
import '../../features/bottom_panels/bottom_panels.dart';
import '../../shared/providers/workspace_providers.dart';
import '../../shared/widgets/ai_widgets.dart';

/// Read-only process output surface. Commands are started by the AI agent
/// through the native tool boundary; users cannot type or execute shell
/// commands from this panel.
class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key});

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  final ScrollController _scrollController = ScrollController();
  late final List<TerminalLine> _lines;
  StreamSubscription<TerminalLine>? _lineSubscription;

  @override
  void initState() {
    super.initState();
    final service = ref.read(terminalServiceProvider);
    _lines = List<TerminalLine>.from(service.outputLog);

    _lineSubscription = service.lineStream.listen((line) {
      if (!mounted) return;
      setState(() {
        if (line.text == '[2J') {
          _lines.clear();
        } else {
          _lines.add(line);
          if (_lines.length > 5000) {
            _lines.removeRange(0, _lines.length - 5000);
          }
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    });
  }

  @override
  void dispose() {
    _lineSubscription?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 80),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Material(
      color: const Color(0xFF0D1117),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: DesignTokens.space4,
              vertical: DesignTokens.space2,
            ),
            decoration: BoxDecoration(
              color: const Color(0xFF161B22),
              border: Border(
                bottom: BorderSide(
                  color: cs.outlineVariant,
                  width: DesignTokens.borderWidthThin,
                ),
              ),
            ),
            child: Row(
              children: [
                const AiOrb(
                  icon: Icons.terminal,
                  size: 20,
                  iconSize: DesignTokens.iconXS,
                  glow: false,
                ),
                const SizedBox(width: DesignTokens.space2),
                const Text(
                  'Agent Output',
                  style: TextStyle(
                    color: Color(0xFFE6EDF3),
                    fontSize: DesignTokens.fontSizeMD,
                    fontWeight: DesignTokens.fontWeightSemibold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(
                    Icons.clear_all_rounded,
                    size: DesignTokens.iconSM,
                    color: Color(0xFF8B949E),
                  ),
                  onPressed: () => setState(() => _lines.clear()),
                  tooltip: 'Clear output',
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  icon: const Icon(
                    Icons.close,
                    size: DesignTokens.iconSM,
                    color: Color(0xFF8B949E),
                  ),
                  onPressed: () => ref
                      .read(selectedBottomPanelProvider.notifier)
                      .state = null,
                  tooltip: 'Close',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(DesignTokens.space3),
              itemCount: _lines.length,
              itemBuilder: (context, index) {
                final line = _lines[index];
                final color = switch (line.type) {
                  TerminalLineType.command => const Color(0xFF79C0FF),
                  TerminalLineType.stderr => const Color(0xFFF85149),
                  TerminalLineType.info => const Color(0xFF3FB950),
                  TerminalLineType.stdout => const Color(0xFFE6EDF3),
                };
                return Padding(
                  padding: const EdgeInsets.only(bottom: 1),
                  child: SelectableText(
                    line.text,
                    style: TextStyle(
                      color: color,
                      fontFamily: 'JetBrains Mono',
                      fontSize: DesignTokens.fontSizeSM,
                      height: 1.4,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
