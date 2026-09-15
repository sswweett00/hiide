import 'package:flutter/material.dart';

class AppThemes {
  static const String fontFamily = 'Inter';

  static ThemeData get darkTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF58A6FF),
      brightness: Brightness.dark,
      surface: const Color(0xFF0D1117), // GitHub Dark High Density
      onSurface: const Color(0xFFE6EDF3),
      surfaceContainerHighest: const Color(0xFF161B22),
      primary: const Color(0xFF58A6FF),
      onPrimary: const Color(0xFF0D1117),
      secondary: const Color(0xFFBC8CFF),
      onSecondary: const Color(0xFF0D1117),
      error: const Color(0xFFF85149),
      outline: const Color(0xFF30363D),
      outlineVariant: const Color(0xFF21262D),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: colorScheme.surface,
      textSelectionTheme: TextSelectionThemeData(
        selectionColor: const Color(0xFF58A6FF).withValues(alpha: 0.35),
        cursorColor: const Color(0xFF58A6FF),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
        surfaceTintColor: colorScheme.surface,
      ),
      cardTheme: CardThemeData(
        color: colorScheme.surfaceContainerHighest,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: colorScheme.outlineVariant, width: 1),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colorScheme.onSurface,
          side: BorderSide(color: colorScheme.outline),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colorScheme.primary,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: colorScheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: colorScheme.primary, width: 2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      dividerTheme: DividerThemeData(
        color: colorScheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      dividerColor: colorScheme.outlineVariant,
    );
  }

  static ThemeData get lightTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0969DA),
      brightness: Brightness.light,
      surface: const Color(0xFFF6F8FA),
      onSurface: const Color(0xFF1F2328),
      surfaceContainerHighest: const Color(0xFFEFF1F3),
      primary: const Color(0xFF0969DA),
      onPrimary: Colors.white,
      secondary: const Color(0xFF8250DF),
      onSecondary: Colors.white,
      error: const Color(0xFFCF222E),
      outline: const Color(0xFFD0D7DE),
      outlineVariant: const Color(0xFFD8DEE4),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: colorScheme.surface,
      dividerTheme: DividerThemeData(
          color: colorScheme.outlineVariant, thickness: 1, space: 1),
    );
  }

  static ThemeData get oledBlackTheme {
    final base = darkTheme;
    return base.copyWith(
      scaffoldBackgroundColor: const Color(0xFF000000),
      colorScheme: base.colorScheme.copyWith(
        surface: const Color(0xFF000000),
        surfaceContainerHighest: const Color(0xFF0D0D0D),
      ),
    );
  }

  static ThemeData get highContrastTheme {
    final base = darkTheme;
    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: const Color(0xFF58A6FF),
        onPrimary: Colors.black,
        onSurface: Colors.white,
        surface: Colors.black,
        surfaceContainerHighest: const Color(0xFF161616),
        outline: Colors.white,
      ),
    );
  }
}
