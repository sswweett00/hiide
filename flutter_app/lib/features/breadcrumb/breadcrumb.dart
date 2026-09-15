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

    // Find active tab's path
    String? filePath;
    if (activeId != null && tabs.isNotEmpty) {
      final active = tabs.firstWhere(
        (t) => t.id == activeId,
        orElse: () => tabs.first,
      );
      filePath = active.path;
    }

    // Parse path segments
    final segments = <String>[];
    if (filePath != null && filePath.isNotEmpty) {
      // Remove workspace root prefix to get relative path
      final relative = filePath.startsWith(currentWorkspace)
          ? filePath.substring(currentWorkspace.length + 1)
          : filePath;
      segments.addAll(relative.split('/').where((s) => s.isNotEmpty));
    }

    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: DesignTokens.space3),
      color: cs.surface,
      child: Row(
        children: [
          Icon(Icons.folder,
              size: DesignTokens.iconXS, color: cs.onSurfaceVariant),
          const SizedBox(width: DesignTokens.space1),
          if (segments.isEmpty)
            Text(
              currentWorkspace.split('/').last,
              style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: DesignTokens.fontSizeXS),
            )
          else
            ...segments.asMap().entries.map((entry) {
              final i = entry.key;
              final seg = entry.value;
              final isLast = i == segments.length - 1;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.chevron_right,
                      size: DesignTokens.iconXS, color: cs.outline),
                  const SizedBox(width: DesignTokens.space1),
                  Flexible(
                    child: Text(
                      seg,
                      style: TextStyle(
                          color: isLast ? cs.onSurface : cs.onSurfaceVariant,
                          fontSize: DesignTokens.fontSizeXS,
                          fontWeight: isLast
                              ? DesignTokens.fontWeightMedium
                              : FontWeight.normal),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              );
            }),
        ],
      ),
    );
  }
}
