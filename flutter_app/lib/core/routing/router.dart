import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../backend/web_picker.dart';
import '../backend/workspace_service.dart';
import '../design_system/tokens.dart';
import '../../shared/providers/editor_providers.dart';
import '../../shared/widgets/ai_widgets.dart';
import '../../shared/widgets/folder_browser_dialog.dart';
import '../../features/editor/editor_screen.dart';
import '../../features/explorer/explorer_screen.dart';
import '../../features/search/search_screen.dart';
import '../../features/source_control/source_control_screen.dart';
import '../../features/debug/debug_screen.dart';
import '../../features/extensions/extensions_screen.dart';
import '../../features/problems/problems_screen.dart';
import '../../features/output/output_screen.dart';
import '../../features/terminal/terminal_screen.dart';
import '../../features/dashboard/dashboard_screen.dart';
import '../../features/agent_workspace/agent_workspace_screen.dart';
import '../../features/welcome_pages/welcome_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/plugin_manager/plugin_manager_screen.dart';
import '../../features/keyboard_shortcuts/keyboard_shortcuts_screen.dart';
import '../../features/command_palette/command_palette_screen.dart';
import '../../features/notification_center/notification_center_screen.dart';
import '../../features/quick_open/quick_open_screen.dart';
import '../../features/diff_viewer/diff_viewer_screen.dart';
import '../../features/merge_view/merge_view_screen.dart';

enum RoutePath {
  splash('/'),
  welcome('/welcome'),
  workspacePicker('/workspace-picker'),
  dashboard('/dashboard'),
  agent('/agent'),
  editor('/editor'),
  explorer('/explorer'),
  search('/search'),
  sourceControl('/source-control'),
  debug('/debug'),
  extensions('/extensions'),
  problems('/problems'),
  output('/output'),
  terminal('/terminal'),
  settings('/settings'),
  pluginManager('/plugin-manager'),
  keyboardShortcuts('/keyboard-shortcuts'),
  commandPalette('/command-palette'),
  notificationCenter('/notifications'),
  quickOpen('/quick-open'),
  diffViewer('/diff'),
  mergeView('/merge');

  final String path;
  const RoutePath(this.path);
}

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    debugLogDiagnostics: false,
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => SplashScreen(),
      ),
      GoRoute(
        path: '/welcome',
        builder: (context, state) => WelcomeScreen(),
      ),
      GoRoute(
        path: '/workspace-picker',
        builder: (context, state) => WorkspacePickerScreen(),
      ),
      GoRoute(
        path: '/dashboard',
        builder: (context, state) => DashboardScreen(),
      ),
      GoRoute(
        path: '/agent',
        builder: (context, state) => const AgentWorkspaceScreen(),
      ),
      GoRoute(
        path: '/editor',
        builder: (context, state) => const EditorScreen(),
      ),
      GoRoute(
        path: '/explorer',
        builder: (context, state) => const ExplorerScreen(),
      ),
      GoRoute(
        path: '/search',
        builder: (context, state) => const SearchScreen(),
      ),
      GoRoute(
        path: '/source-control',
        builder: (context, state) => const SourceControlScreen(),
      ),
      GoRoute(
        path: '/debug',
        builder: (context, state) => const DebugScreen(),
      ),
      GoRoute(
        path: '/extensions',
        builder: (context, state) => const ExtensionsScreen(),
      ),
      GoRoute(
        path: '/problems',
        builder: (context, state) => const ProblemsScreen(),
      ),
      GoRoute(
        path: '/output',
        builder: (context, state) => const OutputScreen(),
      ),
      GoRoute(
        path: '/terminal',
        builder: (context, state) => const TerminalScreen(),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/welcome-settings',
        builder: (context, state) => const SettingsScreen(standalone: true),
      ),
      GoRoute(
        path: '/plugin-manager',
        builder: (context, state) => const PluginManagerScreen(),
      ),
      GoRoute(
        path: '/keyboard-shortcuts',
        builder: (context, state) => const KeyboardShortcutsScreen(),
      ),
      GoRoute(
        path: '/command-palette',
        builder: (context, state) => const CommandPaletteScreen(),
      ),
      GoRoute(
        path: '/notifications',
        builder: (context, state) => const NotificationCenterScreen(),
      ),
      GoRoute(
        path: '/quick-open',
        builder: (context, state) => const QuickOpenScreen(),
      ),
      GoRoute(
        path: '/diff',
        builder: (context, state) => const DiffViewerScreen(),
      ),
      GoRoute(
        path: '/merge',
        builder: (context, state) => const MergeViewScreen(),
      ),
    ],
  );
});

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: AiBackdrop(
        intensity: 0.8,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const AiOrb(size: 88, iconSize: 44),
              const SizedBox(height: DesignTokens.space6),
              Text(
                'Hiide',
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: DesignTokens.space2),
              Text(
                'The AI-native IDE for modern development',
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: DesignTokens.fontSizeLG,
                ),
              ),
              const SizedBox(height: DesignTokens.space8),
              AiGradientButton(
                onPressed: () => context.go('/welcome'),
                label: 'Get Started',
                icon: Icons.bolt,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The start screen's folder picker: shows the current workspace, quick-opens
/// recently used folders, and opens the real folder browser (or the native OS
/// picker) to choose a new one. Selecting a folder activates it app-wide and
/// moves to the dashboard.
class WorkspacePickerScreen extends ConsumerWidget {
  const WorkspacePickerScreen({super.key});

  Future<void> _pickFolder(BuildContext context, WidgetRef ref) async {
    if (kIsWeb) {
      // Browsers cannot enumerate the disk; the native directory picker
      // hands us a real (in-memory) folder to open instead. Land straight in
      // the editor so the picked folder's tree is visible immediately.
      final ws = await pickWebDirectory();
      if (!context.mounted || ws == null) return;
      await activateWorkspace(ref, ws.rootPath);
      if (context.mounted) context.go('/agent');
      return;
    }
    final current = ref.read(workspaceRootProvider);
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => FolderBrowserDialog(initialPath: current),
    );
    if (selected == null || selected.isEmpty) return;
    await activateWorkspace(ref, selected);
    if (context.mounted) context.go('/agent');
  }

  Future<void> _openNativePicker(BuildContext context, WidgetRef ref) async {
    final result = await WorkspaceService.pickDirectoryWithNativeDialog();
    if (!context.mounted) return;
    final path = result.path;
    if (path != null) {
      await activateWorkspace(ref, path);
      if (context.mounted) context.go('/agent');
      return;
    }
    // A plain cancel has no message; anything else is surfaced explicitly.
    if (result.message.isNotEmpty) {
      _warn(context, result.message);
    }
  }

  void _warn(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 4),
    ));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final current = ref.watch(workspaceRootProvider);
    final recents = ref.watch(recentWorkspacesProvider);

    return Scaffold(
      backgroundColor: cs.surface,
      body: AiBackdrop(
        intensity: 0.65,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(DesignTokens.space5),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(
                    child: AiOrb(
                      icon: Icons.folder_special,
                      size: 64,
                      iconSize: 32,
                    ),
                  ),
                  const SizedBox(height: DesignTokens.space4),
                  Text(
                    'Select Workspace',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: DesignTokens.space1),
                  Text(
                    'Choose where to work — recent folders below, or browse your disk.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: DesignTokens.fontSizeMD,
                    ),
                  ),
                  const SizedBox(height: DesignTokens.space4),
                  AiGlowCard(
                    padding: const EdgeInsets.symmetric(
                        horizontal: DesignTokens.space3,
                        vertical: DesignTokens.space2),
                    wash: false,
                    child: Row(
                      children: [
                        Icon(Icons.folder_outlined,
                            size: DesignTokens.iconSM,
                            color: DesignTokens.aiViolet),
                        const SizedBox(width: DesignTokens.space2),
                        Expanded(
                          child: Text(
                            current,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: cs.onSurface,
                              fontFamily: 'JetBrains Mono',
                              fontSize: DesignTokens.fontSizeSM,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: DesignTokens.space4),
                  if (recents.isNotEmpty) ...[
                    Text(
                      'SON KLASÖRLER',
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: DesignTokens.fontSizeXS,
                        fontWeight: DesignTokens.fontWeightSemibold,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: DesignTokens.space2),
                    ...recents.map((path) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.history,
                              size: DesignTokens.iconSM,
                              color: cs.onSurfaceVariant),
                          title: Text(
                            path,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: cs.onSurface,
                                fontFamily: 'JetBrains Mono',
                                fontSize: DesignTokens.fontSizeSM),
                          ),
                          onTap: () async {
                            await activateWorkspace(ref, path);
                            if (context.mounted) {
                              context.go('/editor');
                            }
                          },
                        )),
                    const SizedBox(height: DesignTokens.space2),
                  ],
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 430;
                      final browse = AiGradientButton(
                        onPressed: () => _pickFolder(context, ref),
                        label: kIsWeb ? 'Browse Folder' : 'Open Workspace',
                        icon: Icons.folder_open,
                        expand: true,
                      );
                      if (kIsWeb) return browse;
                      final native = OutlinedButton.icon(
                        onPressed: () => _openNativePicker(context, ref),
                        icon: const Icon(Icons.laptop, size: DesignTokens.iconSM),
                        label: const Text('Sistem seçici'),
                      );
                      return compact
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                native,
                                const SizedBox(height: DesignTokens.space2),
                                browse,
                              ],
                            )
                          : Row(
                              children: [
                                Expanded(child: native),
                                const SizedBox(width: DesignTokens.space2),
                                Expanded(child: browse),
                              ],
                            );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
