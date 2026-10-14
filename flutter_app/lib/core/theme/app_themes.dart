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
      surface: dark ? const Color(0xFF141720) : const Color(0xFFF5F6F8),
      onSurface: dark ? const Color(0xFFE4E7EE) : const Color(0xFF242833),
      surfaceContainerHighest: dark ? const Color(0xFF202430) : const Color(0xFFFFFFFF),
      surfaceContainerHigh: dark ? const Color(0xFF1B1F2A) : const Color(0xFFFAFAFC),
      surfaceContainer: dark ? const Color(0xFF181B24) : const Color(0xFFF0F2F5),
      primary: dark ? const Color(0xFFB0A2FF) : const Color(0xFF6554C0),
      onPrimary: Colors.white,
      secondary: dark ? const Color(0xFF79CDBB) : const Color(0xFF167C6D),
      onSecondary: dark ? const Color(0xFF07110E) : Colors.white,
      tertiary: dark ? const Color(0xFF83BDF0) : const Color(0xFF286DAD),
      error: dark ? const Color(0xFFFF7181) : const Color(0xFFD92D43),
      outline: dark ? const Color(0xFF414654) : const Color(0xFFD7DAE2),
      outlineVariant: dark ? const Color(0xFF303541) : const Color(0xFFE6E8ED),
    );
  }

  static ThemeData get darkTheme => _build(_scheme(brightness: Brightness.dark));
  static ThemeData get lightTheme => _build(_scheme(brightness: Brightness.light));

  static ThemeData _build(ColorScheme colorScheme) {
    final dark = colorScheme.brightness == Brightness.dark;
    final pageBackground = dark ? const Color(0xFF141720) : const Color(0xFFF5F6F8);
    final fieldBackground = dark ? const Color(0xFF1B1F2A) : const Color(0xFFFFFFFF);

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: pageBackground,
      canvasColor: pageBackground,
      splashFactory: NoSplash.splashFactory,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
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
        toolbarHeight: 52,
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
          minimumSize: const Size(0, 40),
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
          minimumSize: const Size(0, 36),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(controlRadius)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: colorScheme.onSurfaceVariant,
          hoverColor: colorScheme.primary.withValues(alpha: dark ? 0.14 : 0.08),
          focusColor: colorScheme.primary.withValues(alpha: 0.14),
          minimumSize: const Size(40, 40),
          maximumSize: const Size(40, 40),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: fieldBackground,
        isDense: false,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
          color: dark ? const Color(0xFF292E3A) : const Color(0xFF343947),
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
