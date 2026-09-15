import 'package:flutter/material.dart';
import '../../core/design_system/tokens.dart';

class HiideContextMenu extends StatelessWidget {
  final List<ContextMenuItem> items;
  final Offset position;

  const HiideContextMenu(
      {super.key, required this.items, required this.position});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Positioned(
      left: position.dx,
      top: position.dy,
      child: Material(
        color: Colors.transparent,
        child: Container(
          constraints: const BoxConstraints(minWidth: 200),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(DesignTokens.radiusLG),
            border: Border.all(
                color: cs.outlineVariant, width: DesignTokens.borderWidthThin),
            boxShadow: [
              BoxShadow(
                color: cs.shadow.withValues(alpha: 0.2),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: ListView.builder(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              if (item.isDivider) {
                return Divider(height: 1, color: cs.outlineVariant);
              }
              return _ContextMenuItem(item: item);
            },
          ),
        ),
      ),
    );
  }
}

class ContextMenuItem {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool isDivider;
  final bool isDestructive;

  const ContextMenuItem({
    required this.label,
    this.icon,
    this.onTap,
    this.isDivider = false,
    this.isDestructive = false,
  });
}

class _ContextMenuItem extends StatelessWidget {
  final ContextMenuItem item;

  const _ContextMenuItem({required this.item});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (item.isDivider) {
      return Divider(height: 1, color: cs.outlineVariant);
    }

    return InkWell(
      onTap: item.onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: DesignTokens.space4, vertical: DesignTokens.space2),
        child: Row(
          children: [
            if (item.icon != null) ...[
              Icon(item.icon,
                  size: DesignTokens.iconSM,
                  color: item.isDestructive ? cs.error : cs.onSurface),
              const SizedBox(width: DesignTokens.space2),
            ],
            Expanded(
              child: Text(
                item.label,
                style: TextStyle(
                  color: item.isDestructive ? cs.error : cs.onSurface,
                  fontSize: DesignTokens.fontSizeMD,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
