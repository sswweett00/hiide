import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'agent_run_manager.dart';
import 'agent_task_store.dart';
import 'ai_providers/provider_manager.dart';
import 'backend_service.dart';

final agentRunManagerProvider = Provider<AgentRunManager>((ref) {
  final manager = AgentRunManager(
    ai: ref.watch(providerManagerProvider),
    backend: ref.watch(backendServiceProvider),
    taskStore: ref.watch(agentTaskStoreProvider),
    onChanged: () => ref.read(agentTaskVersionProvider.notifier).state++,
  );
  ref.onDispose(() {
    manager.dispose();
  });
  return manager;
});
