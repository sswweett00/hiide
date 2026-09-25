import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/design_system/tokens.dart';
import '../../shared/providers/editor_providers.dart';

class Breadcrumb extends ConsumerWidget {
  const Breadcrumb({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final activeId = ref.watch(activeTabIdProvider);
    final tabs = ref.watch(openTabsProvider);
    final currentWorkspace = ref.watch(workspaceRootProvider);

    String? filePath;
    String? fileName;
    if (activeId != null && tabs.isNotEmpty) {
      final active = tabs.firstWhere(
        (t) => t.id == activeId,
        orElse: () => tabs.first,
      );
      filePath = active.path;
      fileName = active.title;
    }

    final segments = <String>[];
    if (filePath != null && filePath.isNotEmpty) {
      final normalizedRoot = currentWorkspace.endsWith('/')
          ? currentWorkspace.substring(0, currentWorkspace.length - 1)
          : currentWorkspace;
      final relative = filePath.startsWith('$normalizedRoot/')
          ? filePath.substring(normalizedRoot.length + 1)
          : filePath;
      segments.addAll(relative.split('/').where((s) => s.isNotEmpty));
    }

    final workspaceParts =
        currentWorkspace.split('/').where((s) => s.isNotEmpty).toList();
    final workspaceName = currentWorkspace.isEmpty
        ? 'Workspace'
        : (workspaceParts.isEmpty ? currentWorkspace : workspaceParts.last);

    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: DesignTokens.space3),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: .55)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _CrumbIcon(icon: Icons.folder_open_outlined, color: cs.primary),
                  const SizedBox(width: 6),
                  _CrumbText(workspaceName, emphasized: false),
                  if (segments.isNotEmpty) ...[
                    _Divider(),
                    ...segments.asMap().entries.map((entry) {
                      final isLast = entry.key == segments.length - 1;
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (entry.key > 0) _Divider(),
                          _CrumbText(entry.value, emphasized: isLast),
                        ],
                      );
                    }),
                  ],
                ],
              ),
            ),
          ),
          if (fileName != null && fileName.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: .55),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: DesignTokens.fontSizeXS,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CrumbIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _CrumbIcon({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Icon(icon, size: 14, color: color);
  }
}

class _CrumbText extends StatelessWidget {
  final String text;
  final bool emphasized;
  const _CrumbText(this.text, {required this.emphasized});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: emphasized ? cs.onSurface : cs.onSurfaceVariant,
          fontSize: DesignTokens.fontSizeXS,
          fontWeight: emphasized
              ? DesignTokens.fontWeightMedium
              : DesignTokens.fontWeightRegular,
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Icon(
        Icons.chevron_right,
        size: 13,
        color: Theme.of(context).colorScheme.outline,
      ),
    );
  }
}
