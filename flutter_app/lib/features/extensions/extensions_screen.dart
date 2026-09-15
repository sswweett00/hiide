import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/design_system/tokens.dart';
import '../../shared/widgets/ide_shell.dart';
import '../../shared/widgets/ai_widgets.dart';

class ExtensionsScreen extends ConsumerWidget {
  const ExtensionsScreen({super.key});

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
            const AiPageHeader(icon: Icons.extension, title: 'Extensions'),
            Padding(
              padding: const EdgeInsets.fromLTRB(DesignTokens.space4, 0,
                  DesignTokens.space4, DesignTokens.space3),
              child: TextField(
                decoration: InputDecoration(
                  hintText: 'Search extensions...',
                  prefixIcon: Icon(Icons.search, size: DesignTokens.iconSM),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                style: TextStyle(
                    color: cs.onSurface, fontSize: DesignTokens.fontSizeMD),
              ),
            ),
            Expanded(
              child: ListView(
                padding:
                    const EdgeInsets.symmetric(horizontal: DesignTokens.space4),
                children: const [
                  _ExtensionCard(
                      name: 'Flutter',
                      description: 'Flutter development tools',
                      installed: true),
                  _ExtensionCard(
                      name: 'Dart',
                      description: 'Dart language support',
                      installed: true),
                  _ExtensionCard(
                      name: 'GitLens',
                      description: 'Git supercharged',
                      installed: false),
                  _ExtensionCard(
                      name: 'Error Lens',
                      description: 'Inline error diagnostics',
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

class _ExtensionCard extends StatefulWidget {
  final String name;
  final String description;
  final bool installed;

  const _ExtensionCard(
      {required this.name, required this.description, required this.installed});

  @override
  State<_ExtensionCard> createState() => _ExtensionCardState();
}

class _ExtensionCardState extends State<_ExtensionCard> {
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
          Container(
            width: DesignTokens.space8,
            height: DesignTokens.space8,
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(DesignTokens.radiusMD),
            ),
            child: Icon(Icons.extension,
                size: DesignTokens.iconLG, color: cs.primary),
          ),
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
                Text(widget.description,
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
