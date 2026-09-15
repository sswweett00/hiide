// Verifies every screen builds without thrown exceptions (e.g. missing
// Material ancestors) and without RenderFlex overflow errors, at both
// desktop and narrow window sizes.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hiide_flutter/core/theme/app_themes.dart';
import 'package:hiide_flutter/features/command_palette/command_palette_screen.dart';
import 'package:hiide_flutter/features/dashboard/dashboard_screen.dart';
import 'package:hiide_flutter/features/debug/debug_screen.dart';
import 'package:hiide_flutter/features/diff_viewer/diff_viewer_screen.dart';
import 'package:hiide_flutter/features/editor/editor_screen.dart';
import 'package:hiide_flutter/features/explorer/explorer_screen.dart';
import 'package:hiide_flutter/features/extensions/extensions_screen.dart';
import 'package:hiide_flutter/features/keyboard_shortcuts/keyboard_shortcuts_screen.dart';
import 'package:hiide_flutter/features/merge_view/merge_view_screen.dart';
import 'package:hiide_flutter/features/notification_center/notification_center_screen.dart';
import 'package:hiide_flutter/features/output/output_screen.dart';
import 'package:hiide_flutter/features/plugin_manager/plugin_manager_screen.dart';
import 'package:hiide_flutter/features/problems/problems_screen.dart';
import 'package:hiide_flutter/features/quick_open/quick_open_screen.dart';
import 'package:hiide_flutter/features/search/search_screen.dart';
import 'package:hiide_flutter/features/settings/settings_screen.dart';
import 'package:hiide_flutter/features/source_control/source_control_screen.dart';
import 'package:hiide_flutter/features/terminal/terminal_screen.dart';

Future<void> _loadAppFonts() async {
  // Load the bundled fonts so text layout matches production metrics instead
  // of the test-only Ahem placeholder font.
  const families = {
    'Inter': ['400', '500', '600', '700'],
    'JetBrains Mono': ['400', '500', '700'],
  };
  for (final entry in families.entries) {
    final loader = FontLoader(entry.key);
    for (final weight in entry.value) {
      final bytes =
          File('assets/fonts/${entry.key.replaceAll(' ', '')}-$weight.ttf')
              .readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }
}

void main() {
  setUpAll(_loadAppFonts);

  // Screens are pumped WITHOUT a Scaffold: MaterialApp alone does not provide
  // a Material ancestor, so a screen that fails to supply its own Material
  // (e.g. via IdeShell) throws "No Material widget found".
  final screens = <String, WidgetBuilder>{
    'DashboardScreen': (_) => const DashboardScreen(),
    'EditorScreen': (_) => const EditorScreen(),
    'ExplorerScreen': (_) => const ExplorerScreen(),
    'SearchScreen': (_) => const SearchScreen(),
    'SourceControlScreen': (_) => const SourceControlScreen(),
    'DebugScreen': (_) => const DebugScreen(),
    'ExtensionsScreen': (_) => const ExtensionsScreen(),
    'ProblemsScreen': (_) => const ProblemsScreen(),
    'OutputScreen': (_) => const OutputScreen(),
    'TerminalScreen': (_) => const TerminalScreen(),
    'SettingsScreen': (_) => const SettingsScreen(),
    'SettingsScreen (standalone)': (_) =>
        const SettingsScreen(standalone: true),
    'PluginManagerScreen': (_) => const PluginManagerScreen(),
    'KeyboardShortcutsScreen': (_) => const KeyboardShortcutsScreen(),
    'CommandPaletteScreen': (_) => const CommandPaletteScreen(),
    'NotificationCenterScreen': (_) => const NotificationCenterScreen(),
    'QuickOpenScreen': (_) => const QuickOpenScreen(),
    'DiffViewerScreen': (_) => const DiffViewerScreen(),
    'MergeViewScreen': (_) => const MergeViewScreen(),
  };

  for (final entry in screens.entries) {
    for (final size in const [
      Size(1280, 720), // desktop
      Size(500, 800), // narrow window
    ]) {
      testWidgets(
          '${entry.key} renders at ${size.width.toInt()}x${size.height.toInt()}',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final errors = <FlutterErrorDetails>[];
        final oldHandler = FlutterError.onError;
        FlutterError.onError = (details) => errors.add(details);

        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: AppThemes.darkTheme,
              home: Builder(builder: entry.value),
            ),
          ),
        );
        // Let async initializers (tabs, AI suggestions) settle.
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(seconds: 2));

        FlutterError.onError = oldHandler;

        // No exception thrown while building/laying out.
        expect(tester.takeException(), isNull,
            reason: '${entry.key} threw an exception');

        // No layout overflow errors reported.
        final overflows =
            errors.where((e) => e.toString().contains('overflowed')).toList();
        expect(overflows, isEmpty,
            reason: '${entry.key} overflowed: $overflows');
      });
    }
  }
}
