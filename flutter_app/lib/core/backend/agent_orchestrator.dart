import 'agent_controller.dart';
import 'agent_profile.dart';
import 'ai_chat_client.dart';
import 'backend_service.dart';
import 'skill_registry.dart';

class AgentSpecialistResult {
  const AgentSpecialistResult({
    required this.profile,
    required this.output,
    required this.success,
  });

  final AgentProfile profile;
  final String output;
  final bool success;
}

class AgentOrchestrator {
  AgentOrchestrator({
    required this.ai,
    required this.backend,
    required this.workspaceRoot,
    required this.model,
    this.skillRegistry = const HiideSkillRegistry(),
  });

  final AiChatClient ai;
  final BackendService backend;
  final String workspaceRoot;
  final String model;
  final HiideSkillRegistry skillRegistry;

  /// Runs independent read-only specialists concurrently.
  ///
  /// Mutating agents are intentionally excluded from this phase. Parallel
  /// execution therefore cannot create write/write races in the shared
  /// workspace. This mirrors multi-agent products that fan out exploration
  /// and review work while keeping mutations under a controlled agent.
  Future<List<AgentSpecialistResult>> runParallelReadOnlyReview({
    required String objective,
    List<String> changedFiles = const [],
    bool includeExplorer = true,
    bool includeReviewer = true,
    bool includeSecurity = true,
  }) async {
    final profiles = <AgentProfile>[
      if (includeExplorer) AgentProfile.explore,
      if (includeReviewer) AgentProfile.reviewer,
      if (includeSecurity) AgentProfile.security,
    ];

    if (profiles.isEmpty) return const [];

    final skills = await skillRegistry.contextFor(
      workspaceRoot,
      objective,
      maxSkills: 2,
      maxChars: 6000,
    );

    return Future.wait(
      profiles.map(
        (profile) => _runSpecialist(
          profile,
          objective: objective,
          changedFiles: changedFiles,
          skillContext: skills,
        ),
      ),
    );
  }

  Future<AgentSpecialistResult> _runSpecialist(
    AgentProfile profile, {
    required String objective,
    required List<String> changedFiles,
    required String skillContext,
  }) async {
    final controller = AgentController(
      ai: ai,
      backend: backend,
      workspaceRoot: workspaceRoot,
      model: model,
      systemPrompt: profile.systemPrompt,
      allowedTools: profile.allowedTools,
      maxIterations: profile.maxIterations,
    );

    final files = changedFiles.isEmpty
        ? 'No changed-file list was provided; inspect the workspace.'
        : changedFiles.join(', ');

    final prompt = '''
Task objective:
$objective

Known changed files:
$files

Inspect the real workspace yourself. Do not assume that the parent agent is
correct. You are a read-only specialist; never edit, delete, create or mutate
files.

$skillContext

Return a concise evidence-backed report. Include PASS/FAIL or FINDINGS at the
top, followed by concrete file paths and the highest-value observations.
''';

    final output = StringBuffer();
    var success = true;

    try {
      await for (final event in controller.run([
        {'role': 'user', 'content': prompt},
      ])) {
        switch (event) {
          case AgentTextTokenEvent(:final token):
            output.write(token);
          case AgentDoneEvent(:final text):
            if (text.trim().isNotEmpty) output
              ..write(output.isEmpty ? '' : '\n')
              ..write(text);
          case AgentErrorEvent(:final message):
            success = false;
            output
              ..write(output.isEmpty ? '' : '\n')
              ..write(message);
          case AgentStoppedEvent():
            success = false;
          case AgentIterationLimitEvent(:final reason):
            success = false;
            output
              ..write(output.isEmpty ? '' : '\n')
              ..write(reason);
          case AgentToolStartedEvent():
          case AgentToolFinishedEvent():
        }
      }
    } catch (error) {
      success = false;
      output
        ..write(output.isEmpty ? '' : '\n')
        ..write(error.toString());
    }

    final text = output.toString().trim();
    return AgentSpecialistResult(
      profile: profile,
      output: text.isEmpty ? 'Specialist produced no report.' : text,
      success: success,
    );
  }
}
