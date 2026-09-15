import 'package:flutter/material.dart';
import '../../core/design_system/tokens.dart';

class HiideDialog extends StatelessWidget {
  final String title;
  final Widget content;
  final List<Widget>? actions;
  final bool showCloseButton;

  const HiideDialog({
    super.key,
    required this.title,
    required this.content,
    this.actions,
    this.showCloseButton = true,
  });

  static Future<T?> show<T>(BuildContext context,
      {required String title, required Widget content, List<Widget>? actions}) {
    return showDialog<T>(
      context: context,
      builder: (context) =>
          HiideDialog(title: title, content: content, actions: actions),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Dialog(
      backgroundColor: cs.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DesignTokens.radiusLG)),
      child: Padding(
        padding: const EdgeInsets.all(DesignTokens.space6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: DesignTokens.fontSizeXL,
                      fontWeight: DesignTokens.fontWeightSemibold,
                    ),
                  ),
                ),
                if (showCloseButton)
                  IconButton(
                    icon: Icon(Icons.close,
                        size: DesignTokens.iconMD, color: cs.onSurfaceVariant),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
              ],
            ),
            const SizedBox(height: DesignTokens.space4),
            content,
            if (actions != null) ...[
              const SizedBox(height: DesignTokens.space6),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: actions!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
