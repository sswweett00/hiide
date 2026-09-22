import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_system/tokens.dart';
import '../../shared/providers/editor_providers.dart';
import '../../shared/widgets/ai_widgets.dart';

final gitStatusProvider = StateProvider<List<Map<String, String>>>((ref) => []);
final isGitLoadingProvider = StateProvider<bool>((ref) => false);
final gitErrorProvider = StateProvider<String?>((ref) => null);

class SourceControlScreen extends ConsumerStatefulWidget {
  const SourceControlScreen({super.key});

  @override
  ConsumerState<SourceControlScreen> createState() =>
      _SourceControlScreenState();
}

class _SourceControlScreenState extends ConsumerState<SourceControlScreen> {
  final TextEditingController _commitController = TextEditingController();
  int _operation = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(_fetchGitStatus);
  }

  @override
  void dispose() {
    _commitController.dispose();
    super.dispose();
  }

  Future<ProcessResult> _runGit(List<String> args, String root) {
    return Process.run('git', args, workingDirectory: root);
  }

  Future<void> _fetchGitStatus() async {
    final token = ++_operation;
    final root = ref.read(workspaceRootProvider).trim();
    if (kIsWeb || root.isEmpty) {
      ref.read(gitStatusProvider.notifier).state = [];
      ref.read(gitErrorProvider.notifier).state =
          kIsWeb ? 'Git is unavailable in the web build.' : 'No workspace is open.';
      return;
    }

    ref.read(isGitLoadingProvider.notifier).state = true;
    ref.read(gitErrorProvider.notifier).state = null;
    try {
      final result = await _runGit(['status', '--porcelain=v1'], root);
      if (!mounted || token != _operation) return;
      if (result.exitCode != 0) {
        throw StateError(result.stderr.toString().trim().isEmpty
            ? 'git status failed with exit code ${result.exitCode}'
            : result.stderr.toString().trim());
      }

      final items = <Map<String, String>>[];
      for (final raw in result.stdout.toString().split('\n')) {
        if (raw.isEmpty || raw.length < 3) continue;
        final status = raw.substring(0, 2).trim();
        final path = raw.substring(3).trim();
        if (path.isEmpty) continue;
        items.add({
          'status': status.isEmpty ? '??' : status,
          'file': path,
        });
      }
      ref.read(gitStatusProvider.notifier).state = items;
    } catch (error) {
      if (!mounted || token != _operation) return;
      ref.read(gitStatusProvider.notifier).state = [];
      ref.read(gitErrorProvider.notifier).state = error.toString();
    } finally {
      if (mounted && token == _operation) {
        ref.read(isGitLoadingProvider.notifier).state = false;
      }
    }
  }

  Future<void> _commit() async {
    final message = _commitController.text.trim();
    if (message.isEmpty) {
      _showMessage('Commit message is required.');
      return;
    }

    final root = ref.read(workspaceRootProvider).trim();
    if (kIsWeb || root.isEmpty) {
      _showMessage(kIsWeb ? 'Git is unavailable in the web build.' : 'No workspace is open.');
      return;
    }

    final token = ++_operation;
    ref.read(isGitLoadingProvider.notifier).state = true;
    ref.read(gitErrorProvider.notifier).state = null;

    try {
      final add = await _runGit(['add', '--all'], root);
      if (add.exitCode != 0) {
        throw StateError(add.stderr.toString().trim().isEmpty
            ? 'git add failed with exit code ${add.exitCode}'
            : add.stderr.toString().trim());
      }

      final commit = await _runGit(['commit', '-m', message], root);
      final stdout = commit.stdout.toString().trim();
      final stderr = commit.stderr.toString().trim();
      if (commit.exitCode != 0) {
        final details = stderr.isNotEmpty ? stderr : stdout;
        throw StateError(details.isEmpty
            ? 'git commit failed with exit code ${commit.exitCode}'
            : details);
      }

      _commitController.clear();
      if (mounted && token == _operation) {
        _showMessage(stdout.isEmpty ? 'Changes committed.' : stdout);
      }
    } catch (error) {
      if (!mounted || token != _operation) return;
      ref.read(gitErrorProvider.notifier).state = error.toString();
      _showMessage('Commit failed: $error', error: true);
    } finally {
      if (mounted && token == _operation) {
        ref.read(isGitLoadingProvider.notifier).state = false;
      }
      if (mounted && token == _operation) {
        await _fetchGitStatus();
      }
    }
  }

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final items = ref.watch(gitStatusProvider);
    final loading = ref.watch(isGitLoadingProvider);
    final error = ref.watch(gitErrorProvider);

    return Container(
      color: cs.surface,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          AiPageHeader(
            icon: Icons.source,
            title: 'Source Control (Git)',
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh, size: DesignTokens.iconSM),
                onPressed: loading ? null : _fetchGitStatus,
                tooltip: 'Refresh Git status',
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(DesignTokens.space4),
            child: TextField(
              controller: _commitController,
              enabled: !loading,
              onSubmitted: (_) => _commit(),
              decoration: const InputDecoration(
                hintText: 'Commit message',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: DesignTokens.space4),
            child: Wrap(
              spacing: DesignTokens.space2,
              runSpacing: DesignTokens.space2,
              children: [
                FilledButton.icon(
                  onPressed: loading ? null : _commit,
                  icon: const Icon(Icons.check, size: DesignTokens.iconSM),
                  label: const Text('Commit'),
                ),
                OutlinedButton.icon(
                  onPressed: loading ? null : _fetchGitStatus,
                  icon: const Icon(Icons.refresh, size: DesignTokens.iconSM),
                  label: const Text('Refresh'),
                ),
              ],
            ),
          ),
          if (loading) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(DesignTokens.space4),
              child: Text(error, style: TextStyle(color: cs.error, fontSize: DesignTokens.fontSizeSM)),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(DesignTokens.space4, DesignTokens.space3, DesignTokens.space4, DesignTokens.space2),
            child: Text('${items.length} changed files', style: TextStyle(color: cs.onSurfaceVariant, fontSize: DesignTokens.fontSizeSM)),
          ),
          ...items.map((item) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: DesignTokens.space4),
                child: _SCMItem(label: item['status'] ?? '??', file: item['file'] ?? ''),
              )),
          const SizedBox(height: DesignTokens.space4),
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
    final color = label.contains('D')
        ? DesignTokens.deleted
        : label.contains('?') || label.contains('A')
            ? DesignTokens.added
            : label.contains('M') || label.contains('R')
                ? DesignTokens.modified
                : cs.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: DesignTokens.space2),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: cs.outlineVariant, width: DesignTokens.borderWidthThin)),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 24,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(DesignTokens.radiusSM),
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(color: color, fontSize: DesignTokens.fontSizeXS, fontWeight: DesignTokens.fontWeightSemibold),
              ),
            ),
          ),
          const SizedBox(width: DesignTokens.space3),
          Expanded(
            child: Text(
              file,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.onSurface, fontSize: DesignTokens.fontSizeMD, fontFamily: 'JetBrains Mono'),
            ),
          ),
        ],
      ),
    );
  }
}
