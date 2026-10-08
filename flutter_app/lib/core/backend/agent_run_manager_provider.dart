import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'agent_run_manager.dart';
import 'agent_task_store.dart';
import 'mcp_manager.dart';
import 'ai_providers/provider_manager.dart';
import 'backend_service.dart';

final agentRunManagerProvider = Provider<AgentRunManager>((ref) {
  final manager = AgentRunManager(
    ai: ref.watch(providerManagerProvider),
    backend: ref.watch(backendServiceProvider),
    taskStore: ref.watch(agentTaskStoreProvider),
    mcpManager: ref.watch(hiideMcpManagerProvider),
    onChanged: () => ref.read(agentTaskVersionProvider.notifier).state++,
  );
  ref.onDispose(() {
    manager.dispose();
  });
  return manager;
});

final hiideMcpManagerProvider = Provider<HiideMcpManager>((ref) {
  final manager = HiideMcpManager();
  ref.onDispose(manager.dispose);
  return manager;
});
