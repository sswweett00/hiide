import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/backend_provider.dart';
import '../../shared/models/editor_tab.dart';
import '../../shared/providers/editor_providers.dart';

final statusAiThinkingProvider = StateProvider<bool>((ref) => false);

class StatusBar extends ConsumerWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final cursorLine = ref.watch(cursorLineProvider);
    final cursorColumn = ref.watch(cursorColumnProvider);
    final isThinking = ref.watch(statusAiThinkingProvider);
    final activeId = ref.watch(activeTabIdProvider);
    final tabs = ref.watch(openTabsProvider);
    EditorTab? active;
    if (activeId != null && tabs.isNotEmpty) {
      active = tabs.firstWhere((t) => t.id == activeId, orElse: () => tabs.first);
    }

    final content = active?.content ?? '';
    final lineCount = content.isEmpty ? 0 : '\n'.allMatches(content).length + 1;
    final wordCount = content.trim().isEmpty ? 0 : content.trim().split(RegExp(r'\s+')).length;
    final charCount = content.length;
    final language = active == null ? 'Plain Text' : languageForPath(active.path ?? active.title);
    final connected = _isEngine(ref);

    return Container(
      height: 24,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.72),
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final showFile = w >= 480;
            final showStats = w >= 650;
            final showAi = w >= 760;
            return Row(
              children: [
                _StatusItem(icon: connected ? Icons.cloud_done_outlined : Icons.cloud_off_outlined, label: connected ? 'Engine' : 'Fallback', tone: connected ? const Color(0xFF3FB950) : Colors.amber),
                const SizedBox(width: 4),
                if (showFile && active != null) ...[
                  _StatusItem(icon: Icons.description_outlined, label: active.title),
                  const SizedBox(width: 4),
                ],
                const Spacer(),
                if (showStats)
                  _StatusItem(icon: Icons.data_object, label: '$lineCount lines · $wordCount words · $charCount chars'),
                if (showStats) const SizedBox(width: 6),
                _StatusItem(icon: Icons.code, label: language),
                const SizedBox(width: 6),
                if (showAi) ...[
                  _AiStatusItem(isThinking: isThinking),
                  const SizedBox(width: 6),
                ],
                _StatusItem(icon: Icons.my_location_outlined, label: 'Ln $cursorLine, Col $cursorColumn'),
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
      return false;
    }
  }
}

class _AiStatusItem extends ConsumerWidget {
  final bool isThinking;
  const _AiStatusItem({required this.isThinking});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final connection = ref.watch(groqConnectionProvider);
    final (label, tone) = isThinking
        ? ('AI Working', cs.primary)
        : switch (connection) {
            AsyncData(:final value) => value.ok ? ('AI Ready', const Color(0xFF3FB950)) : ('AI Offline', cs.error),
            AsyncError() => ('AI Offline', cs.error),
            _ => ('AI Checking', Colors.amber),
          };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isThinking)
          SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: tone))
        else
          Icon(Icons.auto_awesome, size: 12, color: tone),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: tone, fontSize: 10, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _StatusItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? tone;
  const _StatusItem({required this.icon, required this.label, this.tone});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: tone ?? cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: tone ?? cs.onSurfaceVariant, fontSize: 10, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
