import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/design_system/tokens.dart';
import '../../core/backend/terminal_service.dart';
import '../../shared/providers/editor_providers.dart';
import '../../shared/widgets/ide_shell.dart';
import '../../shared/widgets/ai_widgets.dart';

final gitStatusProvider = StateProvider<List<Map<String, String>>>((ref) => []);
final isGitLoadingProvider = StateProvider<bool>((ref) => false);

class SourceControlScreen extends ConsumerStatefulWidget {
  const SourceControlScreen({super.key});

  @override
  ConsumerState<SourceControlScreen> createState() =>
      _SourceControlScreenState();
}

class _SourceControlScreenState extends ConsumerState<SourceControlScreen> {
  final TextEditingController _commitController = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() => _fetchGitStatus());
  }

  @override
  void dispose() {
    _commitController.dispose();
    super.dispose();
  }

  Future<void> _fetchGitStatus() async {
    ref.read(isGitLoadingProvider.notifier).state = true;
    final terminalService = TerminalService();
    final root = ref.read(workspaceRootProvider);
    if (kIsWeb || root.isEmpty) {
      ref.read(isGitLoadingProvider.notifier).state = false;
      return;
    }
    try {
      final result = await Process.run('git', ['status', '--porcelain'],
          workingDirectory: root);
      final lines = result.stdout
          .toString()
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();

      final List<Map<String, String>> items = [];
      for (final line in lines) {
        if (line.length >= 3) {
          final status = line.substring(0, 2).trim();
          final file = line.substring(3).trim();
          items.add({'status': status.isEmpty ? 'M' : status, 'file': file});
        }
      }
      ref.read(gitStatusProvider.notifier).state = items;
    } catch (e) {
      debugPrint('Git status error: $e');
    } finally {
      ref.read(isGitLoadingProvider.notifier).state = false;
      terminalService.dispose();
    }
  }

  Future<void> _commit() async {
    final msg = _commitController.text.trim();
    if (msg.isEmpty) return;
    ref.read(isGitLoadingProvider.notifier).state = true;
    try {
      final root = ref.read(workspaceRootProvider);
      await Process.run('git', ['add', '.'],
          workingDirectory: root);
      await Process.run('git', ['commit', '-m', msg],
          workingDirectory: root);
      _commitController.clear();
      await _fetchGitStatus();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Changes committed successfully')));
      }
    } catch (e) {
      debugPrint('Commit failed: $e');
    } finally {
      ref.read(isGitLoadingProvider.notifier).state = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final gitItems = ref.watch(gitStatusProvider);
    final isLoading = ref.watch(isGitLoadingProvider);

    return Container(
      color: cs.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AiPageHeader(
            icon: Icons.source,
            title: 'Source Control (Git)',
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh, size: DesignTokens.iconSM),
                onPressed: () => _fetchGitStatus(),
                tooltip: 'Refresh Git status',
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(DesignTokens.space4),
            child: TextField(
              controller: _commitController,
              decoration: const InputDecoration(
                hintText: 'Message (Ctrl+Enter to commit on "main")',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: DesignTokens.space4),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: isLoading ? null : () => _commit(_commitController.text),
                    icon: const Icon(Icons.check, size: DesignTokens.iconSM),
                    label: const Text('Commit'),
                  ),
                ),
                const SizedBox(width: DesignTokens.space2),
                OutlinedButton.icon(
                  onPressed: _fetchGitStatus,
                  icon: const Icon(Icons.refresh, size: DesignTokens.iconSM),
                  label: const Text('Refresh'),
                ),
              ],
            ),
          ),
          const SizedBox(height: DesignTokens.space4),
          if (isLoading)
            const LinearProgressIndicator()
          else
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: DesignTokens.space4,
                  vertical: DesignTokens.space2),
              child: Text(
                '${gitItems.length} Changed Files',
                style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: DesignTokens.fontSizeSM),
              ),
            ),
          Expanded(
            child: ListView.builder(
              padding:
                  const EdgeInsets.symmetric(horizontal: DesignTokens.space4),
              itemCount: gitItems.length,
              itemBuilder: (context, index) {
                final item = gitItems[index];
                return _SCMItem(
                    label: item['status'] ?? 'M', file: item['file'] ?? '');
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SCMItem extends StatelessWidget {
  final String label;
  final String file;

  const _SCMItem({required this.label, required this.file});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = label.contains('M')
        ? const Color(0xFFD29922)
        : (label.contains('A') || label.contains('?'))
            ? const Color(0xFF3FB950)
            : cs.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: DesignTokens.space2),
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(
                color: cs.outlineVariant, width: DesignTokens.borderWidthThin)),
      ),
      child: Row(
        children: [
          Container(
            width: DesignTokens.space6,
            height: DesignTokens.space6,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(DesignTokens.radiusSM),
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                    color: color,
                    fontSize: DesignTokens.fontSizeXS,
                    fontWeight: DesignTokens.fontWeightSemibold),
              ),
            ),
          ),
          const SizedBox(width: DesignTokens.space3),
          Expanded(
            child: Text(
              file,
              style: TextStyle(
                  color: cs.onSurface,
                  fontSize: DesignTokens.fontSizeMD,
                  fontFamily: 'JetBrains Mono'),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
