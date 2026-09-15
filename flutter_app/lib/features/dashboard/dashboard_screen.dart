import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/backend/web_workspace.dart';
import '../../core/design_system/tokens.dart';
import '../../features/bottom_panels/bottom_panels.dart';
import '../../shared/providers/editor_providers.dart';
import '../../shared/widgets/ai_widgets.dart';

// ─── Providers ────────────────────────────────────────────────────────────────

final dashboardStatsProvider =
    FutureProvider<Map<String, dynamic>>((ref) async {
  final root = ref.watch(workspaceRootProvider);
  final openTabs = ref.watch(openTabsProvider);

  final stats = <String, dynamic>{
    'openTabs': openTabs.length,
    'gitBranch': 'main',
    'gitBranches': 0,
    'modifiedFiles': 0,
    'totalFiles': 0,
  };

  if (kIsWeb) {
    // No processes on the web: report the browser-picked folder instead.
    final ws = webWorkspaceStore.workspace;
    stats['totalFiles'] = ws?.files.length ?? 0;
    return stats;
  }

  // Git branch info
  try {
    final branchResult = await Process.run(
        'git', ['rev-parse', '--abbrev-ref', 'HEAD'],
        workingDirectory: root);
    if (branchResult.exitCode == 0) {
      stats['gitBranch'] = branchResult.stdout.toString().trim();
    }

    final allBranchesResult =
        await Process.run('git', ['branch', '--list'], workingDirectory: root);
    if (allBranchesResult.exitCode == 0) {
      final lines = allBranchesResult.stdout
          .toString()
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .length;
      stats['gitBranches'] = lines;
    }

    final statusResult = await Process.run('git', ['status', '--porcelain'],
        workingDirectory: root);
    if (statusResult.exitCode == 0) {
      final changed = statusResult.stdout
          .toString()
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .length;
      stats['modifiedFiles'] = changed;
    }
  } catch (_) {}

  // File count
  try {
    final countResult = await Process.run(
        'find',
        [
          root,
          '-type',
          'f',
          '!',
          '-path',
          '*/.git/*',
          '!',
          '-path',
          '*/.zig-cache/*',
          '!',
          '-path',
          '*/build/*',
          '!',
          '-path',
          '*/.dart_tool/*'
        ],
        workingDirectory: root);
    if (countResult.exitCode == 0) {
      final count = countResult.stdout
          .toString()
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .length;
      stats['totalFiles'] = count;
    }
  } catch (_) {}

  return stats;
});

// ─── Screen ───────────────────────────────────────────────────────────────────

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final statsAsync = ref.watch(dashboardStatsProvider);
    final workspaceRoot = ref.watch(workspaceRootProvider);

    return Container(
      color: cs.surface,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Faint aurora wash behind the dashboard content.
          Positioned.fill(
            child: IgnorePointer(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned(
                    top: -160,
                    right: -120,
                    child: Container(
                      width: 360,
                      height: 360,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color:
                                DesignTokens.aiViolet.withValues(alpha: 0.08),
                            blurRadius: 200,
                            spreadRadius: 60,
                          ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: -180,
                    left: -100,
                    child: Container(
                      width: 320,
                      height: 320,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: DesignTokens.aiCyan.withValues(alpha: 0.07),
                            blurRadius: 180,
                            spreadRadius: 50,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SingleChildScrollView(
            padding: const EdgeInsets.all(DesignTokens.space6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Title ────────────────────────────────────────────────────
                AiPageHeader(
                  icon: Icons.space_dashboard_outlined,
                  title: 'Dashboard',
                  subtitle: workspaceRoot,
                  actions: [
                    IconButton(
                      onPressed: () => ref.invalidate(dashboardStatsProvider),
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Refresh stats',
                    ),
                  ],
                ),
                const SizedBox(height: DesignTokens.space6),

                // ── Stats Cards ───────────────────────────────────────────────────
                statsAsync.when(
                  loading: () => const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                  error: (e, _) =>
                      Text('Error: $e', style: TextStyle(color: cs.error)),
                  data: (stats) => Wrap(
                    spacing: DesignTokens.space4,
                    runSpacing: DesignTokens.space4,
                    children: [
                      _StatCard(
                        title: 'Open Tabs',
                        value: '${stats['openTabs']}',
                        icon: Icons.tab_outlined,
                        color: const Color(0xFF58A6FF),
                        subtitle: 'Active editor tabs',
                      ),
                      _StatCard(
                        title: 'Git Branch',
                        value: '${stats['gitBranch']}',
                        icon: Icons.account_tree_outlined,
                        color: const Color(0xFF3FB950),
                        subtitle: '${stats['gitBranches']} branches total',
                      ),
                      _StatCard(
                        title: 'Changed Files',
                        value: '${stats['modifiedFiles']}',
                        icon: Icons.edit_note_outlined,
                        color: const Color(0xFFD29922),
                        subtitle: 'Uncommitted changes',
                      ),
                      _StatCard(
                        title: 'Total Files',
                        value: '${stats['totalFiles']}',
                        icon: Icons.folder_outlined,
                        color: const Color(0xFFBC8CFF),
                        subtitle: 'In workspace',
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: DesignTokens.space8),

                // ── Quick Actions ─────────────────────────────────────────────────
                const AiSectionHeader(title: 'Quick Actions'),
                const SizedBox(height: DesignTokens.space2),
                Wrap(
                  spacing: DesignTokens.space3,
                  runSpacing: DesignTokens.space3,
                  children: [
                    _ActionButton(
                      label: 'Open File (Ctrl+P)',
                      icon: Icons.search,
                      onTap: () => context.go('/quick-open'),
                    ),
                    _ActionButton(
                      label: 'New Terminal (Ctrl+`)',
                      icon: Icons.terminal,
                      onTap: () {
                        ref.read(selectedBottomPanelProvider.notifier).state =
                            'terminal';
                      },
                    ),
                    _ActionButton(
                      label: 'Git Status',
                      icon: Icons.source,
                      onTap: () => context.go('/source-control'),
                    ),
                    _ActionButton(
                      label: 'View Diff',
                      icon: Icons.difference,
                      onTap: () => context.go('/diff'),
                    ),
                  ],
                ),

                const SizedBox(height: DesignTokens.space8),

                // ── AI Tips ───────────────────────────────────────────────────────
                AiGlowCard(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const AiOrb(
                        icon: Icons.auto_awesome,
                        size: 48,
                        iconSize: 24,
                      ),
                      const SizedBox(width: DesignTokens.space3),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'AI Assistant Tips',
                              style: TextStyle(
                                color: cs.onSurface,
                                fontWeight: FontWeight.bold,
                                fontSize: DesignTokens.fontSizeMD,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Ask the AI sidebar to read files, write code, run commands, and analyze your codebase. '
                              'Try: "Read the main.dart file and explain it" or "Write a test for this function".',
                              style: TextStyle(
                                  color: cs.onSurfaceVariant,
                                  fontSize: DesignTokens.fontSizeMD,
                                  height: 1.5),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Widgets ──────────────────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;
  final String subtitle;

  const _StatCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 200,
      padding: const EdgeInsets.all(DesignTokens.space4),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: 0.16),
            cs.surfaceContainerHighest,
          ],
        ),
        borderRadius: BorderRadius.circular(DesignTokens.radiusLG),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const Spacer(),
            ],
          ),
          const SizedBox(height: DesignTokens.space3),
          Text(
            value,
            style: TextStyle(
              color: cs.onSurface,
              fontSize: 28,
              fontWeight: FontWeight.bold,
              fontFamily: 'JetBrains Mono',
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: TextStyle(
                color: cs.onSurface,
                fontWeight: FontWeight.w600,
                fontSize: DesignTokens.fontSizeMD),
          ),
          Text(
            subtitle,
            style: TextStyle(
                color: cs.onSurfaceVariant, fontSize: DesignTokens.fontSizeSM),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _ActionButton(
      {required this.label, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    );
  }
}
