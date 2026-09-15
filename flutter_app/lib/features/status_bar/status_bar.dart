import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/design_system/tokens.dart';
import '../../core/providers/backend_provider.dart';
import '../../features/chat/ai_chat_sidebar.dart';
import '../../shared/models/editor_tab.dart';
import '../../shared/providers/editor_providers.dart';

class StatusBar extends ConsumerWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final cursorLine = ref.watch(cursorLineProvider);
    final cursorColumn = ref.watch(cursorColumnProvider);
    final isThinking = ref.watch(isAiThinkingProvider);

    // Real active-file info: name, language and line/word/char counts.
    final activeId = ref.watch(activeTabIdProvider);
    final tabs = ref.watch(openTabsProvider);
    EditorTab? active;
    if (activeId != null && tabs.isNotEmpty) {
      active =
          tabs.firstWhere((t) => t.id == activeId, orElse: () => tabs.first);
    }
    final content = active?.content ?? '';
    final lineCount = content.isEmpty ? 0 : '\n'.allMatches(content).length + 1;
    final wordCount = content.trim().isEmpty
        ? 0
        : content.trim().split(RegExp(r'\s+')).length;
    final charCount = content.length;
    final language =
        active == null ? '—' : languageForPath(active.path ?? active.title);

    return Container(
      height: 22,
      color: cs.primary,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: DesignTokens.space2),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Hide lower-priority items as the window narrows so the status
            // bar never overflows.
            final w = constraints.maxWidth;
            final showFile = w >= 460;
            final showStats = w >= 640;
            final showLanguage = w >= 700;
            final showAi = w >= 560;

            return Row(
              children: [
                if (showFile)
                  _StatusItem(
                    icon: active?.icon ?? Icons.insert_drive_file_outlined,
                    label: active == null ? '—' : active.title,
                    tooltip: active?.path,
                  ),
                if (showLanguage)
                  _StatusItem(icon: Icons.code, label: language),
                const Spacer(),
                if (showStats)
                  _StatusItem(
                    icon: Icons.notes,
                    label: '$lineCount satır · $wordCount kelime'
                        ' · $charCount karakter',
                  ),
                if (showAi)
                  _AiStatusItem(
                    isThinking: isThinking,
                    engine: _isEngine(ref),
                  ),
                _StatusItem(
                    icon: Icons.rectangle,
                    label: 'Ln $cursorLine, Col $cursorColumn'),
              ],
            );
          },
        ),
      ),
    );
  }

  bool _isEngine(WidgetRef ref) {
    try {
      return ref.read(backendServiceProvider).isConnected;
    } catch (_) {
      return false; // backend not overridden (tests) — treat as local
    }
  }
}

/// Live AI + engine state: reflects the real Groq connectivity probe
/// ([groqConnectionProvider]) rather than assuming the model is reachable,
/// with a dot showing whether the native Zig engine is the active backend.
class _AiStatusItem extends ConsumerWidget {
  final bool isThinking;
  final bool engine;

  const _AiStatusItem({required this.isThinking, required this.engine});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final engineColor = engine ? const Color(0xFF3FB950) : Colors.amber;
    final connection = ref.watch(groqConnectionProvider);

    // While the agent is working the spinner + label take precedence.
    final (label, dotColor) = isThinking
        ? ('AI: Working', cs.primary)
        : switch (connection) {
            AsyncData(:final value) => value.ok
                ? ('AI: Ready', const Color(0xFF3FB950))
                : ('AI: Offline', cs.error),
            AsyncError() => ('AI: Offline', cs.error),
            _ => ('AI: Checking…', Colors.amber),
          };

    final reason = connection.valueOrNull?.message;

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: DesignTokens.space1),
      child: Row(
        children: [
          if (isThinking)
            const SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            )
          else
            Icon(
              Icons.auto_awesome,
              size: DesignTokens.iconXS,
              color: cs.onPrimary,
            ),
          const SizedBox(width: DesignTokens.space1),
          Text(
            label,
            style: TextStyle(
              color: label == 'AI: Offline'
                  ? const Color(0xFFFFD54F)
                  : cs.onPrimary,
              fontSize: DesignTokens.fontSizeXS,
              fontWeight: isThinking || label == 'AI: Offline'
                  ? DesignTokens.fontWeightSemibold
                  : DesignTokens.fontWeightRegular,
            ),
          ),
          const SizedBox(width: DesignTokens.space1),
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: DesignTokens.space1),
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: engineColor,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );

    if (label == 'AI: Offline' && reason != null && reason.isNotEmpty) {
      return Tooltip(message: reason, child: content);
    }
    return content;
  }
}

class _StatusItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? tooltip;

  const _StatusItem({required this.icon, required this.label, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: DesignTokens.space1),
      child: Row(
        children: [
          Icon(icon, size: DesignTokens.iconXS, color: cs.onPrimary),
          const SizedBox(width: DesignTokens.space1),
          Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: cs.onPrimary,
              fontSize: DesignTokens.fontSizeXS,
              fontWeight: DesignTokens.fontWeightRegular,
            ),
          ),
        ],
      ),
    );

    if (tooltip != null && tooltip!.isNotEmpty) {
      return Tooltip(message: tooltip!, child: content);
    }
    return content;
  }
}
