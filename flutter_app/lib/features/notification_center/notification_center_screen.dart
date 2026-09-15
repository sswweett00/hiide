import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/design_system/tokens.dart';
import '../../shared/widgets/ide_shell.dart';
import '../../shared/widgets/ai_widgets.dart';

class NotificationCenterScreen extends StatefulWidget {
  const NotificationCenterScreen({super.key});

  @override
  State<NotificationCenterScreen> createState() => _NotificationCenterScreenState();
}

class _NotificationCenterScreenState extends State<NotificationCenterScreen> {
  final List<Map<String, String>> _notifications = [
    {'title': 'Build Succeeded', 'message': 'Your project built successfully', 'type': 'success'},
    {'title': 'Update Available', 'message': 'Hiide 1.1.0 is available', 'type': 'info'},
    {'title': 'Git Conflict', 'message': 'Merge conflict in main.dart', 'type': 'warning'},
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return IdeShell(
      showAiSidebar: true,
      child: Container(
        color: cs.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AiPageHeader(
              icon: Icons.notifications_outlined,
              title: 'Notifications',
              actions: [
                if (_notifications.isNotEmpty)
                  TextButton(
                    onPressed: () {
                      setState(() => _notifications.clear());
                    },
                    child: const Text('Clear All'),
                  ),
              ],
            ),
            Expanded(
              child: _notifications.isEmpty
                  ? const Center(
                      child: Text('No notifications',
                          style: TextStyle(color: Color(0xFF8B949E))),
                    )
                  : ListView(
                      padding: const EdgeInsets.symmetric(
                          horizontal: DesignTokens.space4),
                      children: _notifications.map((n) {
                        return _NotificationItem(
                          title: n['title']!,
                          message: n['message']!,
                          type: n['type']!,
                          onDismiss: () {
                            setState(() => _notifications.remove(n));
                          },
                        );
                      }).toList(),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotificationItem extends StatelessWidget {
  final String title;
  final String message;
  final String type;
  final VoidCallback? onDismiss;

  const _NotificationItem(
      {required this.title, required this.message, required this.type, this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = type == 'success'
        ? const Color(0xFF3FB950)
        : type == 'warning'
            ? const Color(0xFFD29922)
            : const Color(0xFF58A6FF);

    return AiGlowCard(
      margin: const EdgeInsets.only(bottom: DesignTokens.space2),
      child: Row(
        children: [
          Icon(
            type == 'success'
                ? Icons.check_circle
                : type == 'warning'
                    ? Icons.warning_amber
                    : Icons.info,
            size: DesignTokens.iconMD,
            color: color,
          ),
          const SizedBox(width: DesignTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: cs.onSurface,
                        fontSize: DesignTokens.fontSizeMD,
                        fontWeight: DesignTokens.fontWeightMedium)),
                Text(message,
                    style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: DesignTokens.fontSizeSM)),
              ],
            ),
          ),
          if (onDismiss != null)
            IconButton(
              icon: Icon(Icons.close, size: DesignTokens.iconSM, color: cs.onSurfaceVariant),
              onPressed: onDismiss,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }
}
