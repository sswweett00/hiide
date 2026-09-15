import 'package:flutter/material.dart';
import '../../core/design_system/tokens.dart';

class HiideButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final VoidCallback? onLongPressed;
  final Widget child;
  final bool isPrimary;
  final bool isOutlined;
  final bool isTonal;
  final bool isIcon;
  final bool isLoading;
  final bool isDisabled;
  final Size? size;

  const HiideButton({
    super.key,
    this.onPressed,
    this.onLongPressed,
    required this.child,
    this.isPrimary = false,
    this.isOutlined = false,
    this.isTonal = false,
    this.isIcon = false,
    this.isLoading = false,
    this.isDisabled = false,
    this.size,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final effectiveDisabled = isDisabled || onPressed == null;

    Widget button;
    if (isIcon) {
      button = IconButton(
        onPressed: effectiveDisabled ? null : onPressed,
        icon: isLoading
            ? SizedBox(
                width: DesignTokens.iconSM,
                height: DesignTokens.iconSM,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: cs.onSurfaceVariant,
                ),
              )
            : child,
        iconSize: DesignTokens.iconMD,
        padding: const EdgeInsets.all(DesignTokens.space1),
        constraints: BoxConstraints(
          minWidth: size?.width ?? DesignTokens.space8,
          minHeight: size?.height ?? DesignTokens.space8,
        ),
      );
    } else {
      button = ElevatedButton(
        onPressed: effectiveDisabled ? null : onPressed,
        onLongPress: onLongPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: _backgroundColor(cs),
          foregroundColor: _foregroundColor(cs),
          disabledBackgroundColor: cs.surfaceContainerHighest
              .withValues(alpha: DesignTokens.opacityDisabled),
          disabledForegroundColor:
              cs.onSurface.withValues(alpha: DesignTokens.opacityDisabled),
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DesignTokens.radiusMD),
            side: isOutlined
                ? BorderSide(
                    color: cs.outline, width: DesignTokens.borderWidthMedium)
                : BorderSide.none,
          ),
        ),
        child: isLoading
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: _foregroundColor(cs),
                ),
              )
            : child,
      );
    }

    if (effectiveDisabled) {
      return Opacity(opacity: DesignTokens.opacityDisabled, child: button);
    }
    return button;
  }

  Color _backgroundColor(ColorScheme cs) {
    if (isOutlined) return cs.surface;
    if (isPrimary) return cs.primary;
    if (isTonal) return cs.secondaryContainer;
    return cs.surfaceContainerHighest;
  }

  Color _foregroundColor(ColorScheme cs) {
    if (isOutlined) return cs.onSurface;
    if (isPrimary) return cs.onPrimary;
    if (isTonal) return cs.onSecondaryContainer;
    return cs.onSurface;
  }
}

class HiideTextField extends StatelessWidget {
  final TextEditingController? controller;
  final String? hintText;
  final String? labelText;
  final bool isPassword;
  final bool isReadOnly;
  final bool isEnabled;
  final TextInputType? keyboardType;
  final int? maxLines;
  final int? minLines;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onEditingComplete;

  const HiideTextField({
    super.key,
    this.controller,
    this.hintText,
    this.labelText,
    this.isPassword = false,
    this.isReadOnly = false,
    this.isEnabled = true,
    this.keyboardType,
    this.maxLines = 1,
    this.minLines,
    this.prefixIcon,
    this.suffixIcon,
    this.onChanged,
    this.onEditingComplete,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Material(
      child: TextField(
        controller: controller,
        readOnly: isReadOnly,
        enabled: isEnabled,
        obscureText: isPassword,
        keyboardType: keyboardType,
        maxLines: maxLines,
        minLines: minLines,
        onChanged: onChanged,
        onEditingComplete: onEditingComplete,
        style: TextStyle(color: cs.onSurface),
        decoration: InputDecoration(
          hintText: hintText,
          labelText: labelText,
          prefixIcon: prefixIcon,
          suffixIcon: suffixIcon,
          filled: true,
          fillColor: cs.surfaceContainerHighest,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(DesignTokens.radiusMD),
            borderSide: BorderSide(color: cs.outlineVariant),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(DesignTokens.radiusMD),
            borderSide: BorderSide(
                color: cs.primary, width: DesignTokens.borderWidthMedium),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(DesignTokens.radiusMD),
            borderSide: BorderSide(color: cs.outlineVariant),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ),
    );
  }
}

class HiideCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final bool isSelected;

  const HiideCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding,
    this.margin,
    this.isSelected = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: DesignTokens.durationFast,
        margin: margin ?? EdgeInsets.zero,
        padding: padding ?? const EdgeInsets.all(DesignTokens.space4),
        decoration: BoxDecoration(
          color: isSelected ? cs.primaryContainer : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(DesignTokens.radiusLG),
          border: Border.all(
            color: isSelected ? cs.primary : cs.outlineVariant,
            width: isSelected
                ? DesignTokens.borderWidthMedium
                : DesignTokens.borderWidthThin,
          ),
        ),
        child: child,
      ),
    );
  }
}

class HiideBadge extends StatelessWidget {
  final String label;
  final Color? color;
  final bool isDot;

  const HiideBadge({
    super.key,
    required this.label,
    this.color,
    this.isDot = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = color ?? cs.primary;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isDot ? DesignTokens.space1 : DesignTokens.space2,
        vertical: DesignTokens.space1,
      ),
      decoration: BoxDecoration(
        color: bg.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(DesignTokens.radiusFull),
        border: Border.all(color: bg.withValues(alpha: 0.3)),
      ),
      child: isDot
          ? Icon(Icons.circle, size: DesignTokens.iconXS, color: bg)
          : Text(
              label,
              style: TextStyle(
                color: bg,
                fontSize: DesignTokens.fontSizeXS,
                fontWeight: DesignTokens.fontWeightMedium,
              ),
            ),
    );
  }
}

class HiideAvatar extends StatelessWidget {
  final String? imageUrl;
  final String? initials;
  final double size;

  const HiideAvatar({
    super.key,
    this.imageUrl,
    this.initials,
    this.size = DesignTokens.iconXL,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(size / 2),
        border: Border.all(
            color: cs.outlineVariant, width: DesignTokens.borderWidthThin),
      ),
      child: imageUrl != null
          ? ClipOval(child: Image.network(imageUrl!, fit: BoxFit.cover))
          : Center(
              child: Text(
                initials ?? '?',
                style: TextStyle(
                  color: cs.onPrimaryContainer,
                  fontSize: size * 0.4,
                  fontWeight: DesignTokens.fontWeightSemibold,
                ),
              ),
            ),
    );
  }
}
