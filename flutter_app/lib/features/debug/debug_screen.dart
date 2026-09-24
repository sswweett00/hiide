import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/backend/terminal_service.dart';
import '../../core/backend/workspace_service.dart';
import '../../core/design_system/tokens.dart';
import '../../core/providers/backend_provider.dart';
import '../../shared/models/editor_tab.dart';
import '../../shared/providers/editor_providers.dart';
import '../../shared/widgets/ai_widgets.dart';
import '../../shared/widgets/ide_shell.dart';

class _DebugConfigData {
  const _DebugConfigData({
    required this.name,
    required this.type,
    required this.command,
    required this.timeout,
    this.longRunning = false,
  });

  final String name;
  final String type;
  final String command;
  final Duration timeout;
  final bool longRunning;
}

class DebugScreen extends ConsumerStatefulWidget {
  const DebugScreen({super.key});

  @override
  ConsumerState<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends ConsumerState<DebugScreen> {
  bool _isRunning = false;
  bool _loadingConfig = true;
  String _status = '';
  String? _workspaceKind;
  String? _workspaceRoot;
  List<_DebugConfigData> _configs = const [];
  Future<String>? _runningTask;

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadConfigurations);
  }

  Future<void> _loadConfigurations() async {
    if (kIsWeb) {
      if (!mounted) return;
      setState(() {
        _loadingConfig = false;
        _configs = const [];
        _status = 'Debug execution is unavailable in the web build.';
      });
      return;
    }

    try {
      final workspace = ref.read(workspaceServiceProvider);
      final backend = ref.read(backendServiceProvider);
      final tree = await workspace.loadTree(engine: backend);

      final files = <String>{};
      void collect(List<FileTreeItem> items) {
        for (final item in items) {
          if (item.isFile) files.add(item.name.toLowerCase());
          if (item.children.isNotEmpty) collect(item.children);
        }
      }
      collect(tree);

      final root = workspace.rootPath;
      final quotedRoot = _shellQuote(root);
      final configs = <_DebugConfigData>[];

      if (files.contains('pubspec.yaml')) {
        _workspaceKind = 'Flutter / Dart';
        configs.addAll([
          _DebugConfigData(
            name: 'Run Flutter app',
            type: 'Flutter / Debug',
            command: 'cd $quotedRoot && flutter run -d linux --debug',
            timeout: const Duration(days: 1),
            longRunning: true,
          ),
          _DebugConfigData(
            name: 'Run Flutter tests',
            type: 'Dart / Test',
            command: 'cd $quotedRoot && flutter test',
            timeout: const Duration(minutes: 15),
          ),
          _DebugConfigData(
            name: 'Analyze Flutter project',
            type: 'Dart / Analyze',
            command: 'cd $quotedRoot && flutter analyze',
            timeout: const Duration(minutes: 15),
          ),
          _DebugConfigData(
            name: 'Build Flutter debug',
            type: 'Flutter / Build',
            command: 'cd $quotedRoot && flutter build linux --debug',
            timeout: const Duration(minutes: 20),
          ),
        ]);
      } else if (files.contains('build.zig')) {
        _workspaceKind = 'Zig';
        configs.addAll([
          _DebugConfigData(
            name: 'Build Zig project',
            type: 'Zig / Build',
            command: 'cd $quotedRoot && zig build',
            timeout: const Duration(minutes: 15),
          ),
          _DebugConfigData(
            name: 'Run Zig tests',
            type: 'Zig / Test',
            command: 'cd $quotedRoot && zig build test',
            timeout: const Duration(minutes: 15),
          ),
        ]);
      } else if (files.contains('package.json')) {
        _workspaceKind = 'Node.js';
        configs.addAll([
          _DebugConfigData(
            name: 'Run Node development task',
            type: 'Node / Dev',
            command: 'cd $quotedRoot && npm run dev',
            timeout: const Duration(days: 1),
            longRunning: true,
          ),
          _DebugConfigData(
            name: 'Run Node tests',
            type: 'Node / Test',
            command: 'cd $quotedRoot && npm test',
            timeout: const Duration(minutes: 15),
          ),
          _DebugConfigData(
            name: 'Build Node project',
            type: 'Node / Build',
            command: 'cd $quotedRoot && npm run build',
            timeout: const Duration(minutes: 20),
          ),
        ]);
      } else {
        _workspaceKind = 'Generic workspace';
        configs.add(
          _DebugConfigData(
            name: 'Check workspace',
            type: 'Shell',
            command:
                'cd $quotedRoot && printf "Workspace ready: %s\n" "$PWD"',
            timeout: const Duration(minutes: 1),
          ),
        );
      }

      if (!mounted) return;
      setState(() {
        _workspaceRoot = root;
        _configs = List.unmodifiable(configs);
        _loadingConfig = false;
        _status = _configs.isEmpty
            ? 'No runnable configuration detected.'
            : 'Detected ${_configs.length} runnable configurations.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingConfig = false;
        _status = 'Could not detect debug configurations: $error';
      });
    }
  }

  Future<void> _startDebugging(_DebugConfigData config) async {
    if (_isRunning) {
      final canceled = ref.read(terminalServiceProvider).cancelLatestProcess();
      if (mounted) {
        setState(() {
          _isRunning = false;
          _status = canceled
              ? 'Stopped: ${config.name}'
              : 'No active process was available to stop.';
        });
      }
      return;
    }

    final terminal = ref.read(terminalServiceProvider);
    if (_workspaceRoot != null) {
      terminal.setWorkingDirectory(_workspaceRoot!);
    }

    setState(() {
      _isRunning = true;
      _status = 'Running: ${config.name}';
    });

    final command = config.command.replaceAll('$', r'$');
    final future = terminal.executeCapture(
      command,
      timeout: config.timeout,
    );
    _runningTask = future;

    try {
      final output = await future;
      if (!mounted) return;
      final failed = output.startsWith('(error)');
      setState(() {
        _isRunning = false;
        _status = failed
            ? '${config.name} failed. See Terminal for details.'
            : '${config.name} completed successfully.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isRunning = false;
        _status = '${config.name} failed: ${error}';
      });
    } finally {
      if (identical(_runningTask, future)) _runningTask = null;
    }
  }

  String _shellQuote(String value) {
    return "'" + value.replaceAll("'", "'\"'\"'") + "'";
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return IdeShell(
      showAiSidebar: true,
      child: Container(
        color: cs.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AiPageHeader(
              icon: Icons.bug_report_outlined,
              title: 'Run and Debug',
              actions: [
                IconButton(
                  onPressed: _loadingConfig ? null : _loadConfigurations,
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Detect configurations again',
                ),
                if (_isRunning)
                  ElevatedButton.icon(
                    onPressed: () {
                      final canceled = ref
                          .read(terminalServiceProvider)
                          .cancelLatestProcess();
                      setState(() {
                        _isRunning = false;
                        _status = canceled
                            ? 'Debug process stopped.'
                            : 'No active process was available to stop.';
                      });
                    },
                    icon: const Icon(Icons.stop, size: DesignTokens.iconSM),
                    label: const Text('Stop'),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                DesignTokens.space4,
                DesignTokens.space1,
                DesignTokens.space4,
                DesignTokens.space2,
              ),
              child: Row(
                children: [
                  Icon(Icons.folder_open,
                      size: DesignTokens.iconXS,
                      color: cs.primary),
                  const SizedBox(width: DesignTokens.space2),
                  Expanded(
                    child: Text(
                      _workspaceRoot ?? 'Detecting workspace…',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: DesignTokens.fontSizeXS,
                        fontFamily: 'JetBrains Mono',
                      ),
                    ),
                  ),
                  if (_workspaceKind != null)
                    Chip(
                      label: Text(
                        _workspaceKind!,
                        style: TextStyle(
                          fontSize: DesignTokens.fontSizeXS,
                          color: cs.onSurface,
                        ),
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
            if (_status.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: DesignTokens.space4,
                  vertical: DesignTokens.space2,
                ),
                color: cs.surfaceContainerHighest,
                child: Text(
                  _status,
                  style: TextStyle(
                    color: _status.contains('failed') ||
                            _status.contains('unavailable')
                        ? cs.error
                        : cs.onSurfaceVariant,
                    fontSize: DesignTokens.fontSizeSM,
                  ),
                ),
              ),
            if (_loadingConfig) const LinearProgressIndicator(),
            Expanded(
              child: _configs.isEmpty && !_loadingConfig
                  ? const AiEmptyState(
                      icon: Icons.play_disabled_outlined,
                      title: 'No runnable configuration detected',
                      subtitle:
                          'Open a Flutter, Zig, Node.js or compatible workspace, then refresh.',
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(DesignTokens.space4),
                      itemCount: _configs.length,
                      itemBuilder: (context, index) {
                        final config = _configs[index];
                        return _DebugConfig(
                          config: config,
                          running: _isRunning,
                          onRun: () => _startDebugging(config),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DebugConfig extends StatelessWidget {
  const _DebugConfig({
    required this.config,
    required this.running,
    required this.onRun,
  });

  final _DebugConfigData config;
  final bool running;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return AiGlowCard(
      margin: const EdgeInsets.only(bottom: DesignTokens.space2),
      child: Row(
        children: [
          Icon(
            config.longRunning
                ? Icons.directions_run_rounded
                : Icons.play_arrow_rounded,
            size: DesignTokens.iconMD,
            color: cs.primary,
          ),
          const SizedBox(width: DesignTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  config.name,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: DesignTokens.fontSizeMD,
                  ),
                ),
                Text(
                  config.type,
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: DesignTokens.fontSizeSM,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  config.command,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: DesignTokens.fontSizeXS,
                    fontFamily: 'JetBrains Mono',
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(
              running ? Icons.stop : Icons.play_arrow,
              size: DesignTokens.iconSM,
              color: running ? cs.error : cs.primary,
            ),
            tooltip: running ? 'Stop process' : 'Run configuration',
            onPressed: onRun,
          ),
        ],
      ),
    );
  }
}
