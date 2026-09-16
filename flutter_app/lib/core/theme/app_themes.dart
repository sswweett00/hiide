import 'package:flutter/material.dart';
import '../design_system/tokens.dart';

class AppThemes {
  static const String fontFamily = 'Inter';
  static const double controlRadius = DesignTokens.radiusLG;
  static const double panelRadius = DesignTokens.radiusXL;

  static ColorScheme _scheme({required Brightness brightness}) {
    final dark = brightness == Brightness.dark;
    return ColorScheme.fromSeed(
      seedColor: DesignTokens.aiViolet,
      brightness: brightness,
      surface: dark ? const Color(0xFF090A0F) : const Color(0xFFF7F8FC),
      onSurface: dark ? const Color(0xFFE8EAF1) : const Color(0xFF20222A),
      surfaceContainerHighest: dark ? const Color(0xFF151721) : const Color(0xFFEEF0F6),
      surfaceContainerHigh: dark ? const Color(0xFF11131B) : const Color(0xFFF1F3F8),
      surfaceContainer: dark ? const Color(0xFF0E1017) : const Color(0xFFF4F5F9),
      primary: dark ? const Color(0xFF9A82FF) : const Color(0xFF6C55E8),
      onPrimary: Colors.white,
      secondary: dark ? const Color(0xFF55D6BE) : const Color(0xFF008F7A),
      onSecondary: dark ? const Color(0xFF07110E) : Colors.white,
      tertiary: dark ? const Color(0xFF54B7FF) : const Color(0xFF087DC1),
      error: dark ? const Color(0xFFFF7181) : const Color(0xFFD92D43),
      outline: dark ? const Color(0xFF343847) : const Color(0xFFD5D8E2),
      outlineVariant: dark ? const Color(0xFF242735) : const Color(0xFFE2E5EC),
    );
  }

  static ThemeData get darkTheme => _build(_scheme(brightness: Brightness.dark));
  static ThemeData get lightTheme => _build(_scheme(brightness: Brightness.light));

  static ThemeData _build(ColorScheme colorScheme) {
    final dark = colorScheme.brightness == Brightness.dark;
    final pageBackground = dark ? const Color(0xFF090A0F) : const Color(0xFFF7F8FC);
    final fieldBackground = dark ? const Color(0xFF11131B) : Colors.white;

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: pageBackground,
      canvasColor: pageBackground,
      splashFactory: NoSplash.splashFactory,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textTheme: Typography.material2021(colorScheme: colorScheme).black.apply(
            bodyColor: colorScheme.onSurface,
            displayColor: colorScheme.onSurface,
          ),
      iconTheme: IconThemeData(color: colorScheme.onSurfaceVariant, size: DesignTokens.iconLG),
      textSelectionTheme: TextSelectionThemeData(
        selectionColor: colorScheme.primary.withValues(alpha: 0.28),
        cursorColor: colorScheme.primary,
        selectionHandleColor: colorScheme.primary,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: pageBackground,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        toolbarHeight: 46,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: DesignTokens.fontSizeLG,
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        color: colorScheme.surfaceContainerHighest,
        elevation: DesignTokens.elevation1,
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(controlRadius)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colorScheme.onSurface,
          side: BorderSide(color: colorScheme.outline),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          minimumSize: const Size(0, 36),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(controlRadius)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colorScheme.onSurface,
          overlayColor: colorScheme.primary.withValues(alpha: 0.10),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          minimumSize: const Size(0, 32),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(controlRadius)),
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: fieldBackground,
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
        waitDuration: const Duration(milliseconds: 350),
        showDuration: const Duration(seconds: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF1B1E29) : const Color(0xFF2D3040),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: colorScheme.outline),
          boxShadow: const [BoxShadow(blurRadius: 18, spreadRadius: -4, offset: Offset(0, 8), color: Color(0x55000000))],
        ),
        textStyle: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStatePropertyAll(8),
        radius: const Radius.circular(999),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered)
              ? colorScheme.primary.withValues(alpha: 0.64)
              : colorScheme.onSurface.withValues(alpha: 0.20),
        ),
        trackVisibility: const WidgetStatePropertyAll(false),
      ),
      dividerTheme: DividerThemeData(color: colorScheme.outlineVariant, thickness: 1, space: 1),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: dark ? const Color(0xFF1A1D27) : const Color(0xFF252833),
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DesignTokens.radiusLG)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colorScheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: DesignTokens.elevation5,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DesignTokens.radiusXL),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colorScheme.surfaceContainerHigh,
        elevation: DesignTokens.elevation4,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DesignTokens.radiusLG),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
    );
  }

  static ThemeData get oledBlackTheme {
    final base = darkTheme;
    return base.copyWith(
      scaffoldBackgroundColor: Colors.black,
      canvasColor: Colors.black,
      colorScheme: base.colorScheme.copyWith(
        surface: Colors.black,
        surfaceContainer: const Color(0xFF050506),
        surfaceContainerHigh: const Color(0xFF09090C),
        surfaceContainerHighest: const Color(0xFF0B0B0F),
      ),
    );
  }

  static ThemeData get highContrastTheme {
    final base = darkTheme;
    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: const Color(0xFFB69CFF),
        onPrimary: Colors.black,
        onSurface: Colors.white,
        surface: Colors.black,
        surfaceContainer: const Color(0xFF111111),
        surfaceContainerHigh: const Color(0xFF151515),
        surfaceContainerHighest: const Color(0xFF1B1B1B),
        outline: const Color(0xFFE3E5ED),
        outlineVariant: const Color(0xFF777B87),
      ),
    );
  }
}
