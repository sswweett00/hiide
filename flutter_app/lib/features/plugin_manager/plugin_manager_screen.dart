import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/design_system/tokens.dart';
import '../../shared/widgets/ide_shell.dart';
import '../../shared/widgets/ai_widgets.dart';

class PluginManagerScreen extends ConsumerWidget {
  const PluginManagerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;

    return IdeShell(
      showAiSidebar: true,
      child: Container(
        color: cs.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AiPageHeader(
                icon: Icons.extension_outlined, title: 'Plugin Manager'),
            Expanded(
              child: ListView(
                padding:
                    const EdgeInsets.symmetric(horizontal: DesignTokens.space4),
                children: const [
                  _PluginItem(
                      name: 'Rust Analyzer',
                      version: '1.78.0',
                      installed: true),
                  _PluginItem(
                      name: 'Dart Plugin', version: '3.5.0', installed: true),
                  _PluginItem(
                      name: 'Git Graph', version: '0.6.0', installed: false),
                  _PluginItem(
                      name: 'Markdown Preview',
                      version: '1.2.0',
                      installed: false),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PluginItem extends StatefulWidget {
  final String name;
  final String version;
  final bool installed;

  const _PluginItem(
      {required this.name, required this.version, required this.installed});

  @override
  State<_PluginItem> createState() => _PluginItemState();
}

class _PluginItemState extends State<_PluginItem> {
  late bool _installed;

  @override
  void initState() {
    super.initState();
    _installed = widget.installed;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return AiGlowCard(
      margin: const EdgeInsets.only(bottom: DesignTokens.space2),
      child: Row(
        children: [
          Icon(Icons.extension_outlined,
              size: DesignTokens.iconLG, color: cs.onSurfaceVariant),
          const SizedBox(width: DesignTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.name,
                    style: TextStyle(
                        color: cs.onSurface,
                        fontSize: DesignTokens.fontSizeLG,
                        fontWeight: DesignTokens.fontWeightMedium)),
                Text('Version ${widget.version}',
                    style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: DesignTokens.fontSizeSM)),
              ],
            ),
          ),
          ElevatedButton(
            onPressed: _installed
                ? null
                : () {
                    setState(() => _installed = true);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('${widget.name} installed'),
                      duration: const Duration(seconds: 1),
                    ));
                  },
            style: ElevatedButton.styleFrom(
              backgroundColor: cs.primary,
              foregroundColor: cs.onPrimary,
            ),
            child: Text(_installed ? 'Installed' : 'Install'),
          ),
        ],
      ),
    );
  }
}
