import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/design_system/tokens.dart';
import '../../shared/providers/editor_providers.dart';

final minimapZoomProvider = StateProvider<double>((ref) => 1.0);

class Minimap extends ConsumerWidget {
  const Minimap({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final lineCount = ref.watch(cursorLineProvider);

    return Container(
      width: DesignTokens.space8,
      height: DesignTokens.space16,
      color: cs.surface,
      child: CustomPaint(
        size: const Size(DesignTokens.space8, DesignTokens.space16),
        painter: _MinimapPainter(
          color: cs.onSurfaceVariant.withValues(alpha: 0.3),
          activeColor: cs.primary.withValues(alpha: 0.5),
          activeLine: lineCount,
        ),
      ),
    );
  }
}

class _MinimapPainter extends CustomPainter {
  final Color color;
  final Color activeColor;
  final int activeLine;

  _MinimapPainter(
      {required this.color,
      required this.activeColor,
      required this.activeLine});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final activePaint = Paint()..color = activeColor;
    final lineCount = 60;
    final lineHeight = size.height / lineCount;

    for (int i = 0; i < lineCount; i++) {
      if (i % 3 == 0) {
        final y = i * lineHeight;
        canvas.drawRect(
          Rect.fromLTWH(0, y, size.width * 0.7, lineHeight * 0.8),
          i == (activeLine - 1) % lineCount ? activePaint : paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MinimapPainter oldDelegate) {
    return oldDelegate.activeLine != activeLine;
  }
}
