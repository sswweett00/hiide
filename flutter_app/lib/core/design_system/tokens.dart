import 'package:flutter/material.dart';

class DesignTokens {
  // ── AI Native Brand Palette ────────────────────────────────────────────────
  // The signature aurora used for AI surfaces across the IDE: violet → blue →
  // cyan. Every AI element (orbs, glows, gradient buttons, headers, cards)
  // draws from these tokens so the identity stays consistent app-wide.
  static const Color aiViolet = Color(0xFFA78BFA);
  static const Color aiIndigo = Color(0xFF818CF8);
  static const Color aiBlue = Color(0xFF58A6FF);
  static const Color aiCyan = Color(0xFF22D3EE);
  static const Color aiPink = Color(0xFFF472B6);

  /// Soft translucent tint used for AI glows and backdrops.
  static const Color aiGlow = Color(0x3399A3FF);

  /// The app-wide AI gradient (violet → blue → cyan).
  static const LinearGradient aiGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [aiViolet, aiBlue, aiCyan],
  );

  /// Warm accent gradient for “agent” surfaces (violet → pink).
  static const LinearGradient aiAgentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [aiViolet, aiPink],
  );

  /// Shadow used behind AI orbs / gradient buttons to fake a glow.
  static const Color aiGlowShadow = Color(0x55A78BFA);

  // Spacing Scale (4px system)
  static const double space0 = 0;
  static const double space1 = 4;
  static const double space2 = 8;
  static const double space3 = 12;
  static const double space4 = 16;
  static const double space5 = 20;
  static const double space6 = 24;
  static const double space7 = 28;
  static const double space8 = 32;
  static const double space9 = 36;
  static const double space10 = 40;
  static const double space11 = 44;
  static const double space12 = 48;
  static const double space16 = 64;

  // Typography
  static const double fontSizeXS = 11;
  static const double fontSizeSM = 12;
  static const double fontSizeMD = 13;
  static const double fontSizeLG = 14;
  static const double fontSizeXL = 16;
  static const double fontSize2XL = 18;
  static const double fontSize3XL = 20;
  static const double fontSize4XL = 24;

  static const FontWeight fontWeightRegular = FontWeight.w400;
  static const FontWeight fontWeightMedium = FontWeight.w500;
  static const FontWeight fontWeightSemibold = FontWeight.w600;

  static const double lineHeightTight = 1.25;
  static const double lineHeightNormal = 1.5;
  static const double lineHeightRelaxed = 1.75;

  // Radius
  static const double radiusNone = 0;
  static const double radiusSM = 4;
  static const double radiusMD = 6;
  static const double radiusLG = 8;
  static const double radiusXL = 12;
  static const double radius2XL = 16;
  static const double radiusFull = 999;

  // Elevation
  static const double elevation0 = 0;
  static const double elevation1 = 1;
  static const double elevation2 = 2;
  static const double elevation3 = 4;
  static const double elevation4 = 8;
  static const double elevation5 = 12;
  static const double elevation6 = 16;

  // Icon Sizes
  static const double iconXS = 12;
  static const double iconSM = 14;
  static const double iconMD = 16;
  static const double iconLG = 20;
  static const double iconXL = 24;
  static const double icon2XL = 32;

  // Border
  static const double borderWidthThin = 1;
  static const double borderWidthMedium = 2;
  static const double borderWidthThick = 3;

  // Opacity
  static const double opacityDisabled = 0.38;
  static const double opacityHover = 0.08;
  static const double opacityFocus = 0.12;
  static const double opacitySelected = 0.16;

  // Motion
  static const Duration durationFast = Duration(milliseconds: 100);
  static const Duration durationNormal = Duration(milliseconds: 200);
  static const Duration durationSlow = Duration(milliseconds: 300);
  static const Duration durationSlower = Duration(milliseconds: 500);

  static const Curve curveStandard = Curves.ease;
  static const Curve curveEmphasized = Curves.easeInOut;
  static const Curve curveDecelerate = Curves.easeOut;
  static const Curve curveAccelerate = Curves.easeIn;
  static const Curve curveSharp = Curves.easeInOutCubic;

  // Grid
  static const double gridUnit = 4;
  static const int columns = 12;

  // Breakpoints
  static const double breakpointCompact = 600;
  static const double breakpointMedium = 840;
  static const double breakpointExpanded = 1200;
  static const double breakpointLarge = 1600;

  // Z-Index Layers
  static const int zIndexSurface = 1;
  static const int zIndexElevated = 2;
  static const int zIndexOverlay = 3;
  static const int zIndexDialog = 4;
  static const int zIndexSnackbar = 5;
  static const int zIndexTooltip = 6;
  static const int zIndexModal = 10;
}
