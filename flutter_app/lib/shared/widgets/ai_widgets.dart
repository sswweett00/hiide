import 'package:flutter/material.dart';
import '../../core/design_system/tokens.dart';

/// Soft aurora backdrop used behind brand pages (splash, welcome, workspace
/// picker, dashboard). Non-interactive; safe inside any layout. The blobs are
/// plain glow shadows so the widget stays cheap and test-friendly.
class AiBackdrop extends StatelessWidget {
  const AiBackdrop({super.key, this.child, this.intensity = 0.5});

  final Widget? child;
  final double intensity;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: Stack(
            fit: StackFit.expand,
            children: [
              _blob(DesignTokens.aiViolet, 260, top: -140, left: -120),
              _blob(DesignTokens.aiBlue, 300, top: -90, right: -120),
              _blob(DesignTokens.aiCyan, 280, bottom: -140, left: 80),
            ],
          ),
        ),
        if (child != null) child!,
      ],
    );
  }

  Widget _blob(
    Color color,
    double size, {
    double? top,
    double? left,
    double? right,
    double? bottom,
  }) {
    return Positioned(
      top: top,
      left: left,
      right: right,
      bottom: bottom,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.16 * intensity),
              blurRadius: size * 0.9,
              spreadRadius: size * 0.35,
            ),
          ],
        ),
      ),
    );
  }
}

/// Rounded square with the AI gradient, optional icon and a soft glow. The
/// signature “AI element” used in headers, cards and empty states.
class AiOrb extends StatelessWidget {
  const AiOrb({
    super.key,
    this.icon = Icons.auto_awesome,
    this.size = DesignTokens.space8,
    this.iconSize,
    this.glow = true,
  });

  final IconData icon;
  final double size;
  final double? iconSize;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: DesignTokens.aiGradient,
        borderRadius: BorderRadius.circular(size * 0.32),
        boxShadow: glow
            ? [
                BoxShadow(
                  color: DesignTokens.aiGlowShadow,
                  blurRadius: size * 0.7,
                  offset: Offset(0, size * 0.12),
                ),
              ]
            : null,
      ),
      child: Icon(
        icon,
        size: iconSize ?? size * 0.55,
        color: cs.onPrimary,
      ),
    );
  }
}

/// Card framed by the AI gradient (a 1px gradient ring around the surface
/// background), with the option to tint the fill with a faint aurora wash.
class AiGlowCard extends StatelessWidget {
  const AiGlowCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(DesignTokens.space4),
    this.radius = DesignTokens.radiusXL,
    this.wash = true,
    this.margin,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final bool wash;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: margin,
      padding: const EdgeInsets.all(1), // gradient ring
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            DesignTokens.aiViolet.withValues(alpha: 0.55),
            DesignTokens.aiBlue.withValues(alpha: 0.35),
            DesignTokens.aiCyan.withValues(alpha: 0.45),
          ],
        ),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: wash
              ? Color.lerp(
                  cs.surfaceContainerHighest, DesignTokens.aiViolet, 0.06)
              : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(radius - 1),
        ),
        child: child,
      ),
    );
  }
}

/// Primary CTA with the AI gradient and a soft glow — the standard “AI action”
/// button across brand pages.
class AiGradientButton extends StatelessWidget {
  const AiGradientButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
    this.expand = false,
  });

  final VoidCallback? onPressed;
  final String label;
  final IconData? icon;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final button = ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.transparent,
        foregroundColor: cs.onPrimary,
        elevation: 0,
        disabledBackgroundColor: cs.surfaceContainerHighest,
        disabledForegroundColor: cs.onSurfaceVariant,
        shadowColor: DesignTokens.aiGlowShadow,
        padding: const EdgeInsets.symmetric(
            horizontal: DesignTokens.space6, vertical: DesignTokens.space3),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DesignTokens.radiusLG)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: DesignTokens.iconMD),
            const SizedBox(width: DesignTokens.space2),
          ],
          Text(
            label,
            style: TextStyle(
                fontSize: DesignTokens.fontSizeLG,
                fontWeight: DesignTokens.fontWeightSemibold),
          ),
        ],
      ),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: DesignTokens.aiGradient,
        borderRadius: BorderRadius.circular(DesignTokens.radiusLG),
        boxShadow: onPressed == null
            ? null
            : [
                BoxShadow(
                  color: DesignTokens.aiGlowShadow.withValues(alpha: 0.6),
                  blurRadius: 18,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: expand ? SizedBox(width: double.infinity, child: button) : button,
    );
  }
}

/// Standard page header across IDE screens: AI orb + title (+ optional
/// subtitle) on the left, optional actions on the right. Wrap-safe on narrow
/// windows — the title column absorbs the extra space.
class AiPageHeader extends StatelessWidget {
  const AiPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon = Icons.auto_awesome,
    this.actions = const [],
    this.padding = const EdgeInsets.all(DesignTokens.space4),
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final List<Widget> actions;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),
      child: Row(
        children: [
          AiOrb(
            icon: icon,
            size: DesignTokens.space7,
            iconSize: DesignTokens.iconMD,
          ),
          const SizedBox(width: DesignTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: DesignTokens.fontSizeLG,
                    fontWeight: DesignTokens.fontWeightSemibold,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: DesignTokens.fontSizeXS,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(width: DesignTokens.space3),
            Wrap(
              spacing: DesignTokens.space1,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: actions,
            ),
          ],
        ],
      ),
    );
  }
}

/// Section label with a small gradient accent bar — used to group settings,
/// dashboard sections and other content blocks.
class AiSectionHeader extends StatelessWidget {
  const AiSectionHeader({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: DesignTokens.space1, vertical: DesignTokens.space3),
      child: Row(
        children: [
          Container(
            width: 3,
            height: DesignTokens.space4,
            decoration: BoxDecoration(
              gradient: DesignTokens.aiGradient,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: DesignTokens.space2),
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: DesignTokens.fontSizeXS,
                fontWeight: DesignTokens.fontWeightSemibold,
                letterSpacing: 0.8,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Centered empty state: AI orb, title, subtitle and an optional action —
/// the consistent “nothing here yet / let the AI help” pattern.
class AiEmptyState extends StatelessWidget {
  const AiEmptyState({
    super.key,
    required this.title,
    required this.subtitle,
    this.icon = Icons.auto_awesome,
    this.action,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(DesignTokens.space8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AiOrb(
              icon: icon,
              size: DesignTokens.space16,
              iconSize: DesignTokens.icon2XL,
            ),
            const SizedBox(height: DesignTokens.space4),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: DesignTokens.fontSizeXL,
                fontWeight: DesignTokens.fontWeightSemibold,
              ),
            ),
            const SizedBox(height: DesignTokens.space2),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: DesignTokens.fontSizeMD,
                  height: DesignTokens.lineHeightNormal),
            ),
            if (action != null) ...[
              const SizedBox(height: DesignTokens.space5),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
