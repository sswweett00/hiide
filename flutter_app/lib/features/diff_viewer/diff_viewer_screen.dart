import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/design_system/tokens.dart';
import '../../shared/widgets/ai_widgets.dart';
import '../../shared/widgets/ide_shell.dart';
import '../../shared/providers/editor_providers.dart';

// ─── Diff Data Models ─────────────────────────────────────────────────────────

enum DiffLineType { unchanged, added, removed, header, hunk }

class DiffLine {
  final DiffLineType type;
  final String content;
  final int? oldLineNumber;
  final int? newLineNumber;

  const DiffLine({
    required this.type,
    required this.content,
    this.oldLineNumber,
    this.newLineNumber,
  });
}

class DiffFile {
  final String path;
  final List<DiffLine> lines;
  const DiffFile({required this.path, required this.lines});
}

// ─── Providers ────────────────────────────────────────────────────────────────

final diffFilesProvider = FutureProvider<List<DiffFile>>((ref) async {
  final root = ref.watch(workspaceRootProvider);
  return _fetchGitDiff(root);
});

final selectedDiffFileProvider = StateProvider<String?>((ref) => null);

Future<List<DiffFile>> _fetchGitDiff(String workingDir) async {
  try {
    final result = await Process.run(
      'git',
      ['diff', 'HEAD'],
      workingDirectory: workingDir,
    );
    final raw = result.stdout.toString();
    if (raw.trim().isEmpty) {
      // Try staged diff
      final stagedResult = await Process.run(
        'git',
        ['diff', '--cached'],
        workingDirectory: workingDir,
      );
      return _parseDiff(stagedResult.stdout.toString());
    }
    return _parseDiff(raw);
  } catch (e) {
    debugPrint('git diff error: $e');
    return [];
  }
}

List<DiffFile> _parseDiff(String raw) {
  final files = <DiffFile>[];
  if (raw.trim().isEmpty) return files;

  final chunks = raw.split(RegExp(r'(?=diff --git )'));
  for (final chunk in chunks) {
    if (chunk.trim().isEmpty) continue;
    final lines = chunk.split('\n');

    String filePath = '';
    // Extract file path from "diff --git a/... b/..."
    for (final line in lines) {
      if (line.startsWith('diff --git ')) {
        final match = RegExp(r'b/(.+)$').firstMatch(line);
        if (match != null) filePath = match.group(1) ?? '';
        break;
      }
    }
    if (filePath.isEmpty) continue;

    final diffLines = <DiffLine>[];
    int oldLine = 0;
    int newLine = 0;
    bool inHeader = true;

    for (final line in lines) {
      if (line.startsWith('diff --git ') ||
          line.startsWith('index ') ||
          line.startsWith('--- ') ||
          line.startsWith('+++ ')) {
        diffLines.add(DiffLine(type: DiffLineType.header, content: line));
        inHeader = true;
        continue;
      }

      if (line.startsWith('@@')) {
        inHeader = false;
        // Parse hunk header: @@ -a,b +c,d @@
        final match = RegExp(r'@@ -(\d+)(?:,\d+)? \+(\d+)').firstMatch(line);
        if (match != null) {
          oldLine = int.parse(match.group(1)!);
          newLine = int.parse(match.group(2)!);
        }
        diffLines.add(DiffLine(type: DiffLineType.hunk, content: line));
        continue;
      }

      if (inHeader) continue;

      if (line.startsWith('+')) {
        diffLines.add(DiffLine(
            type: DiffLineType.added,
            content: line.substring(1),
            newLineNumber: newLine++));
      } else if (line.startsWith('-')) {
        diffLines.add(DiffLine(
            type: DiffLineType.removed,
            content: line.substring(1),
            oldLineNumber: oldLine++));
      } else if (line.startsWith(' ')) {
        diffLines.add(DiffLine(
            type: DiffLineType.unchanged,
            content: line.substring(1),
            oldLineNumber: oldLine++,
            newLineNumber: newLine++));
      } else if (line.isEmpty) {
        diffLines.add(DiffLine(
            type: DiffLineType.unchanged,
            content: '',
            oldLineNumber: oldLine++,
            newLineNumber: newLine++));
      }
    }

    if (diffLines.isNotEmpty) {
      files.add(DiffFile(path: filePath, lines: diffLines));
    }
  }
  return files;
}

// ─── Screen ───────────────────────────────────────────────────────────────────

class DiffViewerScreen extends ConsumerWidget {
  const DiffViewerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final diffAsync = ref.watch(diffFilesProvider);
    final selectedPath = ref.watch(selectedDiffFileProvider);

    return IdeShell(
      showAiSidebar: true,
      child: Container(
        color: cs.surface,
        child: diffAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline, size: 48, color: cs.error),
                const SizedBox(height: 16),
                Text('Git diff error: $e', style: TextStyle(color: cs.error)),
              ],
            ),
          ),
          data: (files) {
            if (files.isEmpty) {
              return AiEmptyState(
                icon: Icons.check_circle_outline,
                title: 'No Changes',
                subtitle: 'Working tree is clean — no uncommitted changes.',
                action: OutlinedButton.icon(
                  onPressed: () => ref.invalidate(diffFilesProvider),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
              );
            }

            // Select first file if none selected
            final activeFile = files.firstWhere(
              (f) => f.path == selectedPath,
              orElse: () => files.first,
            );

            return Row(
              children: [
                // ── File list sidebar ──────────────────────────────────────
                Container(
                  width: 220,
                  decoration: BoxDecoration(
                    border: Border(
                        right: BorderSide(color: cs.outlineVariant, width: 1)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(DesignTokens.space3),
                        child: Row(
                          children: [
                            Text('Changed Files',
                                style: TextStyle(
                                    color: cs.onSurface,
                                    fontWeight: FontWeight.bold)),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFFD29922)
                                    .withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '${files.length}',
                                style: const TextStyle(
                                    color: Color(0xFFD29922),
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: files.length,
                          itemBuilder: (context, index) {
                            final f = files[index];
                            final isActive = f.path == activeFile.path;
                            final addedCount = f.lines
                                .where((l) => l.type == DiffLineType.added)
                                .length;
                            final removedCount = f.lines
                                .where((l) => l.type == DiffLineType.removed)
                                .length;

                            return Material(
                              color: isActive
                                  ? cs.primaryContainer.withValues(alpha: 0.3)
                                  : Colors.transparent,
                              child: InkWell(
                                onTap: () => ref
                                    .read(selectedDiffFileProvider.notifier)
                                    .state = f.path,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: DesignTokens.space3,
                                      vertical: DesignTokens.space2),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        f.path.split('/').last,
                                        style: TextStyle(
                                          color: cs.onSurface,
                                          fontWeight: isActive
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                          fontSize: DesignTokens.fontSizeMD,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Row(
                                        children: [
                                          Text('+$addedCount',
                                              style: const TextStyle(
                                                  color: Color(0xFF3FB950),
                                                  fontSize: 11)),
                                          const SizedBox(width: 4),
                                          Text('-$removedCount',
                                              style: const TextStyle(
                                                  color: Color(0xFFF85149),
                                                  fontSize: 11)),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),

                // ── Diff content ───────────────────────────────────────────
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header with file path + refresh
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: DesignTokens.space4,
                            vertical: DesignTokens.space2),
                        decoration: BoxDecoration(
                          color:
                              cs.surfaceContainerHighest.withValues(alpha: 0.3),
                          border: Border(
                              bottom: BorderSide(
                                  color: cs.outlineVariant, width: 1)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.difference_outlined,
                                size: 16, color: Color(0xFF58A6FF)),
                            const SizedBox(width: 8),
                            Text(
                              activeFile.path,
                              style: TextStyle(
                                color: cs.onSurface,
                                fontFamily: 'JetBrains Mono',
                                fontSize: DesignTokens.fontSizeSM,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            OutlinedButton.icon(
                              onPressed: () =>
                                  ref.invalidate(diffFilesProvider),
                              icon: const Icon(Icons.refresh, size: 14),
                              label: const Text('Refresh'),
                              style: OutlinedButton.styleFrom(
                                  visualDensity: VisualDensity.compact),
                            ),
                          ],
                        ),
                      ),
                      // Diff lines
                      Expanded(
                        child: _DiffContent(file: activeFile),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ─── Diff Content Widget ──────────────────────────────────────────────────────

class _DiffContent extends StatelessWidget {
  final DiffFile file;
  const _DiffContent({required this.file});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0D1117),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: DesignTokens.space2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children:
              file.lines.map((line) => _DiffLineWidget(line: line)).toList(),
        ),
      ),
    );
  }
}

class _DiffLineWidget extends StatelessWidget {
  final DiffLine line;
  const _DiffLineWidget({required this.line});

  @override
  Widget build(BuildContext context) {
    final (bg, fg, prefix) = switch (line.type) {
      DiffLineType.added => (
          const Color(0xFF1A4731),
          const Color(0xFF3FB950),
          '+'
        ),
      DiffLineType.removed => (
          const Color(0xFF4A1620),
          const Color(0xFFF85149),
          '-'
        ),
      DiffLineType.hunk => (
          const Color(0xFF1C2D3E),
          const Color(0xFF58A6FF),
          ' '
        ),
      DiffLineType.header => (
          const Color(0xFF1C2030),
          const Color(0xFF8B949E),
          ' '
        ),
      DiffLineType.unchanged => (
          Colors.transparent,
          const Color(0xFFE6EDF3),
          ' '
        ),
    };

    final lineNumStr = line.type == DiffLineType.added
        ? '     ${line.newLineNumber ?? ''}'
        : line.type == DiffLineType.removed
            ? '${line.oldLineNumber ?? ''}     '
            : line.type == DiffLineType.unchanged
                ? '${line.oldLineNumber ?? ''}  ${line.newLineNumber ?? ''}'
                : '';

    return Container(
      color: bg,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Line numbers gutter
          Container(
            width: 80,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            color: const Color(0xFF161B22),
            child: Text(
              lineNumStr,
              style: const TextStyle(
                color: Color(0xFF6E7681),
                fontFamily: 'JetBrains Mono',
                fontSize: 11,
              ),
            ),
          ),
          // Prefix (+/-/ )
          Container(
            width: 20,
            padding: const EdgeInsets.symmetric(vertical: 1),
            color: bg.withValues(alpha: 0.6),
            child: Text(
              prefix,
              style: TextStyle(
                color: fg,
                fontFamily: 'JetBrains Mono',
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          // Line content
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
              child: SelectableText(
                line.content,
                style: TextStyle(
                  color: fg,
                  fontFamily: 'JetBrains Mono',
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
