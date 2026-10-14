import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiide_flutter/core/theme/app_themes.dart';

void main() {
  group('AppThemes', () {
    test('light and dark themes use readable foreground/background pairs', () {
      for (final theme in [AppThemes.lightTheme, AppThemes.darkTheme]) {
        final scheme = theme.colorScheme;
        expect(
          ThemeData.estimateBrightnessForColor(scheme.surface),
          theme.brightness,
        );
        expect(scheme.onSurface, isNot(scheme.surface));
        expect(scheme.onSurfaceVariant, isNot(scheme.surface));
        expect(theme.scaffoldBackgroundColor, isNot(Colors.transparent));
      }
    });

    test('interactive controls retain comfortable target sizes', () {
      final theme = AppThemes.darkTheme;
      expect(theme.materialTapTargetSize, MaterialTapTargetSize.padded);
      expect(theme.visualDensity, VisualDensity.standard);
      expect(theme.iconButtonTheme.style?.minimumSize?.resolve({}),
          const Size(40, 40));
    });

    test('light theme uses a soft neutral canvas rather than pure white', () {
      expect(AppThemes.lightTheme.scaffoldBackgroundColor, isNot(Colors.white));
      expect(AppThemes.lightTheme.scaffoldBackgroundColor, isNot(Colors.black));
    });
  });
}
