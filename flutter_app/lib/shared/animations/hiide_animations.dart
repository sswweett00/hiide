import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

class HiideAnimations {
  static Widget fadeIn(Widget child) {
    return child.animate().fadeIn(duration: const Duration(milliseconds: 200));
  }

  static Widget scaleIn(Widget child) {
    return child.animate().scale(
        duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
  }

  static Widget slideIn(Widget child,
      {AxisDirection direction = AxisDirection.down}) {
    return child.animate().slide(
          begin: switch (direction) {
            AxisDirection.up => const Offset(0, -0.1),
            AxisDirection.down => const Offset(0, 0.1),
            AxisDirection.left => const Offset(-0.1, 0),
            AxisDirection.right => const Offset(0.1, 0),
          },
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
  }

  static Widget shimmer(Widget child) {
    return child.animate(onPlay: (controller) => controller.repeat()).shimmer(
          duration: const Duration(milliseconds: 1500),
        );
  }

  static Widget pulse(Widget child) {
    return child.animate(onPlay: (controller) => controller.repeat()).scale(
          begin: const Offset(1, 1),
          end: const Offset(1.05, 1.05),
          duration: const Duration(milliseconds: 800),
          curve: Curves.easeInOut,
        );
  }
}
