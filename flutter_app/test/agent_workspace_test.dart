import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hiide_flutter/core/backend/agent_mode.dart';
import 'package:hiide_flutter/core/backend/groq_ai_service.dart';
import 'package:hiide_flutter/core/backend/mock_backend_service.dart';
import 'package:hiide_flutter/core/providers/backend_provider.dart';
import 'package:hiide_flutter/core/theme/app_themes.dart';
import 'package:hiide_flutter/features/agent_workspace/agent_workspace_screen.dart';
import 'package:hiide_flutter/shared/providers/editor_providers.dart';

void main() {
  testWidgets('agent workspace is task-first rather than IDE-first', (tester) async {
    final backend = MockBackendService();
    addTearDown(backend.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendServiceProvider.overrideWithValue(backend),
          workspaceRootProvider.overrideWith((ref) => '/tmp/demo'),
          groqAiServiceProvider.overrideWith((ref) async => GroqAiService(apiKey: '')),
          groqConnectionProvider.overrideWith((ref) async => (ok: false, message: 'offline')),
          agentModeProvider.overrideWith((ref) => AgentMode.code),
        ],
        child: MaterialApp(
          theme: AppThemes.darkTheme,
          home: const AgentWorkspaceScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Hiide Agent Workspace'), findsOneWidget);
    expect(find.text('MISSIONS'), findsOneWidget);
    expect(find.text('AGENT CONTEXT'), findsOneWidget);
    expect(find.text('RECENT TASKS'), findsOneWidget);
    expect(find.text('Plan'), findsOneWidget);
    expect(find.text('Code'), findsOneWidget);
    expect(find.text('Yeni görev'), findsOneWidget);
    expect(find.text('Kod yüzeyini aç'), findsOneWidget);
  });
}