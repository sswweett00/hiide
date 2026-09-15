import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The four themes exposed in the settings screen.
enum AppThemePreference {
  dark,
  light,
  oledBlack,
  highContrast,
}

final appThemePreferenceProvider =
    StateProvider<AppThemePreference>((ref) => AppThemePreference.dark);

/// Kept for backwards compatibility; mirrors [appThemePreferenceProvider].
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.dark);
