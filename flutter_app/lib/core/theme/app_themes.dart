import 'package:flutter/material.dart';
import '../design_system/tokens.dart';

class AppThemes {
  static ThemeData _theme({required bool dark}) {
    final colorScheme = dark
        ? const ColorScheme.dark(
            primary: DesignTokens.aiViolet,
            secondary: DesignTokens.aiBlue,
            surface: Color(0xFF0D1117),
            surfaceContainerHighest: Color(0xFF21262D),
          )
        : const ColorScheme.light(
            primary: Color(0xFF6D28D9),
            secondary: Color(0xFF2563EB),
            surface: Color(0xFFF8FAFC),
            surfaceContainerHighest: Color(0xFFE2E8F0),
          );
    const controlRadius = 7.0;
    return ThemeData(
      useMaterial3: true,
      brightness: dark ? Brightness.dark : Brightness.light,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      fontFamily: 'Inter',
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colorScheme.onSurface,
          overlayColor: colorScheme.primary.withValues(alpha: 0.10),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          minimumSize: const Size(0, 32),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(controlRadius),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: colorScheme.onSurfaceVariant,
          hoverColor: colorScheme.primary.withValues(alpha: dark ? 0.14 : 0.08),
          focusColor: colorScheme.primary.withValues(alpha: 0.14),
          minimumSize: const Size(34, 34),
          maximumSize: const Size(34, 34),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(controlRadius),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          borderSide: BorderSide(color: colorScheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
        ),
      ),
    );
  }

  static ThemeData get darkTheme => _theme(dark: true);
  static ThemeData get lightTheme => _theme(dark: false);
}
