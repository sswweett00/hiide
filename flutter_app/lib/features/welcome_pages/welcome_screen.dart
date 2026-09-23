import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/design_system/tokens.dart';
import '../../shared/widgets/ai_widgets.dart';

class WelcomeScreen extends ConsumerWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: AiBackdrop(
        intensity: 0.7,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(DesignTokens.space8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const AiOrb(size: 80, iconSize: 40),
                  const SizedBox(height: DesignTokens.space5),
                  Text(
                    'Welcome to Hiide',
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: DesignTokens.fontSize4XL,
                      fontWeight: DesignTokens.fontWeightSemibold,
                    ),
                  ),
                  const SizedBox(height: DesignTokens.space2),
                  Text(
                    'An agent-native development workspace built around tasks, plans, execution and verification',
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: DesignTokens.fontSizeLG,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: DesignTokens.space8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Expanded(
                        child: _FeatureCard(
                          icon: Icons.forum_outlined,
                          title: 'AI Chat',
                          description:
                              'Ask questions about your codebase and get answers grounded in the files you are working on.',
                        ),
                      ),
                      SizedBox(width: DesignTokens.space3),
                      Expanded(
                        child: _FeatureCard(
                          icon: Icons.psychology_alt_outlined,
                          title: 'Coding Agent',
                          description:
                              'Let the agent read, edit and run commands in your workspace — with Groq under the hood.',
                        ),
                      ),
                      Expanded(
                        child: _FeatureCard(
                          icon: Icons.auto_fix_high,
                          title: 'AI-Native UI',
                          description:
                              'Diff gutters, minimaps, live Groq status and an assistant on every screen.',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: DesignTokens.space8),
                  AiGradientButton(
                    onPressed: () => context.go('/agent'),
                    label: 'Get Started',
                    icon: Icons.bolt,
                    expand: true,
                  ),
                  const SizedBox(height: DesignTokens.space3),
                  TextButton(
                    onPressed: () => context.go('/welcome-settings'),
                    child: const Text('Configure Settings'),
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

class _FeatureCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _FeatureCard({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return AiGlowCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AiOrb(
              icon: icon,
              size: DesignTokens.space9,
              iconSize: DesignTokens.iconLG),
          const SizedBox(height: DesignTokens.space3),
          Text(
            title,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: DesignTokens.fontSizeLG,
              fontWeight: DesignTokens.fontWeightSemibold,
            ),
          ),
          const SizedBox(height: DesignTokens.space1),
          Text(
            description,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: DesignTokens.fontSizeSM,
              height: DesignTokens.lineHeightNormal,
            ),
          ),
        ],
      ),
    );
  }
}
