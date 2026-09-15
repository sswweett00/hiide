import 'package:flutter/material.dart';
import '../../core/design_system/tokens.dart';

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final String? actionLabel;
  final VoidCallback? onAction;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(DesignTokens.space8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: DesignTokens.space10,
                color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
            const SizedBox(height: DesignTokens.space4),
            Text(
              title,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: DesignTokens.fontSizeXL,
                fontWeight: DesignTokens.fontWeightMedium,
              ),
            ),
            const SizedBox(height: DesignTokens.space2),
            Text(
              description,
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: DesignTokens.fontSizeMD,
              ),
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: DesignTokens.space4),
              ElevatedButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
