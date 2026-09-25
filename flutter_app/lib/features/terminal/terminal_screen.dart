import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/design_system/tokens.dart';
import '../../core/backend/terminal_service.dart';
import '../../features/bottom_panels/bottom_panels.dart';
import '../../shared/providers/editor_providers.dart';
import '../../shared/widgets/ai_widgets.dart';

class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key});

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  late final List<TerminalLine> _lines;
  StreamSubscription<TerminalLine>? _lineSubscription;

  @override
  void initState() {
    super.initState();
    final service = ref.read(terminalServiceProvider);
    // Start with the existing log so history is not lost on tab switches
    _lines = List<TerminalLine>.from(service.outputLog);

    // Listen for new lines
    _lineSubscription = service.lineStream.listen((line) {
      if (!mounted) return;
      if (line.text == '\x1B[2J') {
        setState(() => _lines.clear());
      } else {
        setState(() {
          _lines.add(line);
          // Keep the in-memory terminal bounded; the service owns the full
          // persistent-ish command log used when reopening the panel.
          if (_lines.length > 5000) {
            _lines.removeRange(0, _lines.length - 5000);
          }
        });
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    });

    // Print a welcome banner if empty
    if (_lines.isEmpty) {
      Future.microtask(() => service.execute('echo "Hiide Terminal — ready"'));
    }
  }

  @override
  void dispose() {
    _lineSubscription?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
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

  void _submit(String cmd) {
    if (cmd.trim().isEmpty) return;
    final service = ref.read(terminalServiceProvider);
    service.execute(cmd.trim());
    _controller.clear();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final service = ref.read(terminalServiceProvider);

    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final prev = service.navigateHistory(true);
      if (prev != null) {
        _controller.text = prev;
        _controller.selection = TextSelection.collapsed(offset: prev.length);
      }
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      final next = service.navigateHistory(false);
      _controller.text = next ?? '';
      _controller.selection =
          TextSelection.collapsed(offset: _controller.text.length);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // Terminal is a leaf panel (no Scaffold/IdeShell ancestor), so it must
    // provide its own Material for the TextField to work.
    return Material(
      color: const Color(0xFF0D1117),
      child: Column(
        children: [
          // Terminal header
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: DesignTokens.space4, vertical: DesignTokens.space2),
            decoration: BoxDecoration(
              color: const Color(0xFF161B22),
              border: Border(
                  bottom: BorderSide(
                      color: cs.outlineVariant,
                      width: DesignTokens.borderWidthThin)),
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
                  'Terminal',
                  style: TextStyle(
                    color: Color(0xFFE6EDF3),
                    fontSize: DesignTokens.fontSizeMD,
                    fontWeight: DesignTokens.fontWeightSemibold,
                  ),
                ),
                const Spacer(),
                // Clear button
                IconButton(
                  icon: const Icon(Icons.delete_sweep_outlined,
                      size: DesignTokens.iconSM, color: Color(0xFF8B949E)),
                  onPressed: () {
                    ref.read(terminalServiceProvider).execute('clear');
                  },
                  tooltip: 'Clear terminal',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                      minWidth: DesignTokens.space8,
                      minHeight: DesignTokens.space8),
                ),
                IconButton(
                  icon: const Icon(Icons.close,
                      size: DesignTokens.iconSM, color: Color(0xFF8B949E)),
                  onPressed: () => ref
                      .read(selectedBottomPanelProvider.notifier)
                      .state = null,
                  tooltip: 'Close',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                      minWidth: DesignTokens.space8,
                      minHeight: DesignTokens.space8),
                ),
              ],
            ),
          ),

          // Output log
          Expanded(
            child: GestureDetector(
              onTap: () => _focusNode.requestFocus(),
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
          ),

          // Input row
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: DesignTokens.space3, vertical: DesignTokens.space2),
            decoration: const BoxDecoration(
              border:
                  Border(top: BorderSide(color: Color(0xFF30363D), width: 1)),
            ),
            child: Focus(
              focusNode: _focusNode,
              onKeyEvent: _handleKey,
              child: Row(
                children: [
                  const Text(
                    r'$ ',
                    style: TextStyle(
                      color: Color(0xFF3FB950),
                      fontFamily: 'JetBrains Mono',
                      fontSize: DesignTokens.fontSizeMD,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: FocusNode(),
                      style: const TextStyle(
                        color: Color(0xFFE6EDF3),
                        fontFamily: 'JetBrains Mono',
                        fontSize: DesignTokens.fontSizeMD,
                      ),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onSubmitted: _submit,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
