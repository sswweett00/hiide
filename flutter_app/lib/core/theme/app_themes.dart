import 'package:flutter/material.dart';

class AppThemes {
  static const String fontFamily = 'Inter';
  static const double controlRadius = 8;
  static const double panelRadius = 10;

  static ColorScheme _scheme({required Brightness brightness}) {
    final dark = brightness == Brightness.dark;
    return ColorScheme.fromSeed(
      seedColor: const Color(0xFF7C5CFC),
      brightness: brightness,
      surface: dark ? const Color(0xFF0A0B10) : const Color(0xFFF7F8FC),
      onSurface: dark ? const Color(0xFFE7EAF2) : const Color(0xFF20222A),
      surfaceContainerHighest:
          dark ? const Color(0xFF151721) : const Color(0xFFEEF0F6),
      primary: dark ? const Color(0xFF8B6CFF) : const Color(0xFF6750E9),
      onPrimary: Colors.white,
      secondary: dark ? const Color(0xFF55D6BE) : const Color(0xFF008F7A),
      onSecondary: dark ? const Color(0xFF07110E) : Colors.white,
      tertiary: dark ? const Color(0xFF4DB5FF) : const Color(0xFF087DC1),
      error: dark ? const Color(0xFFFF6B7A) : const Color(0xFFD92D43),
      outline: dark ? const Color(0xFF343847) : const Color(0xFFD5D8E2),
      outlineVariant: dark ? const Color(0xFF242735) : const Color(0xFFE2E5EC),
    );
  }

  static ThemeData get darkTheme => _build(_scheme(brightness: Brightness.dark));

  static ThemeData get lightTheme => _build(_scheme(brightness: Brightness.light));

  static ThemeData _build(ColorScheme colorScheme) {
    final dark = colorScheme.brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: colorScheme.surface,
      splashFactory: NoSplash.splashFactory,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textTheme: Typography.material2021(colorScheme: colorScheme).black.apply(
            bodyColor: colorScheme.onSurface,
            displayColor: colorScheme.onSurface,
          ),
      iconTheme: IconThemeData(
        color: colorScheme.onSurfaceVariant,
        size: 18,
      ),
      textSelectionTheme: TextSelectionThemeData(
        selectionColor: colorScheme.primary.withValues(alpha: 0.30),
        cursorColor: colorScheme.primary,
        selectionHandleColor: colorScheme.primary,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        toolbarHeight: 46,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        color: colorScheme.surfaceContainerHighest,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(panelRadius),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          disabledBackgroundColor: colorScheme.surfaceContainerHighest,
          disabledForegroundColor: colorScheme.onSurfaceVariant,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          minimumSize: const Size(0, 36),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(controlRadius),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colorScheme.onSurface,
          side: BorderSide(color: colorScheme.outline),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          minimumSize: const Size(0, 36),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(controlRadius),
          ),
        ),
      ),
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
          selectedForegroundColor: colorScheme.onSurface,
          selectedBackgroundColor: colorScheme.primary.withValues(alpha: 0.14),
          minimumSize: const Size(34, 34),
          maximumSize: const Size(34, 34),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(7),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF11131B) : const Color(0xFFFFFFFF),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          borderSide: BorderSide(color: colorScheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          borderSide: BorderSide(color: colorScheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.25),
        ),
        hoverColor: colorScheme.primary.withValues(alpha: 0.035),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        showDuration: const Duration(seconds: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF1B1E29) : const Color(0xFF2D3040),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: colorScheme.outline),
          boxShadow: const [
            BoxShadow(
              blurRadius: 18,
              spreadRadius: -4,
              offset: Offset(0, 8),
              color: Color(0x55000000),
            ),
          ],
        ),
        textStyle: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStatePropertyAll(8),
        radius: const Radius.circular(999),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered)
              ? colorScheme.primary.withValues(alpha: 0.62)
              : colorScheme.onSurface.withValues(alpha: 0.20),
        ),
        trackVisibility: const WidgetStatePropertyAll(false),
      ),
      dividerTheme: DividerThemeData(
        color: colorScheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
    );
  }

  static ThemeData get oledBlackTheme {
    final base = darkTheme;
    return base.copyWith(
      scaffoldBackgroundColor: Colors.black,
      colorScheme: base.colorScheme.copyWith(
        surface: Colors.black,
        surfaceContainerHighest: const Color(0xFF0A0A0D),
      ),
    );
  }

  static ThemeData get highContrastTheme {
    final base = darkTheme;
    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: const Color(0xFFA78BFA),
        onPrimary: Colors.black,
        onSurface: Colors.white,
        surface: Colors.black,
        surfaceContainerHighest: const Color(0xFF171717),
        outline: const Color(0xFFDBDDE5),
        outlineVariant: const Color(0xFF6E7280),
      ),
    );
  }
}
