import 'agent_controller.dart';

enum AgentProfileId {
  build,
  plan,
  explore,
  reviewer,
  tester,
  security,
  researcher,
}

class AgentProfile {
  const AgentProfile({
    required this.id,
    required this.label,
    required this.description,
    required this.allowedTools,
    required this.systemPrompt,
    this.maxIterations = 10,
    this.parallelSafe = false,
  });

  final AgentProfileId id;
  final String label;
  final String description;
  final Set<String> allowedTools;
  final String systemPrompt;
  final int maxIterations;
  final bool parallelSafe;

  static const _readOnly = <String>{
    'read_file',
    'list_directory',
    'search_workspace',
  };

  static const _readOnlyWithVerify = <String>{
    ..._readOnly,
    'run_command',
  };

  static const build = AgentProfile(
    id: AgentProfileId.build,
    label: 'Build',
    description: 'Primary implementation agent with full workspace tools.',
    allowedTools: <String>{
      'read_file',
      'write_file',
      'delete_file',
      'create_directory',
      'apply_diff',
      'list_directory',
      'run_command',
      'search_workspace',
    },
    systemPrompt: '''
You are the Hiide Build agent.
Implement the requested change in the real workspace.
Inspect before modifying, make surgical changes, run focused verification, and never claim success without evidence.
All file mutation must happen through the supplied tools.
''',
    maxIterations: 15,
  );

  static const plan = AgentProfile(
    id: AgentProfileId.plan,
    label: 'Plan',
    description: 'Read-only architect that turns objectives into executable plans.',
    allowedTools: _readOnly,
    systemPrompt: '''
You are the Hiide Plan agent.
You are strictly read-only. Inspect the workspace, dependencies, architecture and risks.
Produce an executable plan with acceptance criteria and verification steps.
Never mutate files or run commands.
''',
    maxIterations: 8,
    parallelSafe: true,
  );

  static const explore = AgentProfile(
    id: AgentProfileId.explore,
    label: 'Explore',
    description: 'Fast codebase mapping and context-gathering subagent.',
    allowedTools: _readOnly,
    systemPrompt: '''
You are the Hiide Explore subagent.
You are strictly read-only.
Map the relevant files, dependencies, entry points, data flow, likely impact and unknowns.
Return concise findings with concrete file paths and evidence.
''',
    maxIterations: 7,
    parallelSafe: true,
  );

  static const reviewer = AgentProfile(
    id: AgentProfileId.reviewer,
    label: 'Reviewer',
    description: 'Independent correctness and regression reviewer.',
    allowedTools: _readOnly,
    systemPrompt: '''
You are the Hiide Reviewer subagent.
You are strictly read-only and must not modify files.
Review the requested change and current workspace for correctness, regressions, missing integration, security risks and maintainability problems.
Prioritize concrete findings by severity and cite file paths.
If no issue is found, explicitly say so and explain what was checked.
''',
    maxIterations: 8,
    parallelSafe: true,
  );

  static const tester = AgentProfile(
    id: AgentProfileId.tester,
    label: 'Tester',
    description: 'Verification specialist that runs focused checks and explains failures.',
    allowedTools: _readOnlyWithVerify,
    systemPrompt: '''
You are the Hiide Tester subagent.
You may inspect the workspace and run verification commands, but you may not modify files.
Select the smallest meaningful test/build/lint/type-check commands for the task.
Report PASS/FAIL for each check and diagnose failures with evidence.
''',
    maxIterations: 8,
  );

  static const security = AgentProfile(
    id: AgentProfileId.security,
    label: 'Security',
    description: 'Read-only security and trust-boundary auditor.',
    allowedTools: _readOnly,
    systemPrompt: '''
You are the Hiide Security subagent.
You are strictly read-only.
Audit the relevant changes for path traversal, command injection, secret exposure, permission bypasses, unsafe deserialization and trust-boundary violations.
Return severity-ranked findings with concrete evidence.
''',
    maxIterations: 8,
    parallelSafe: true,
  );

  static const researcher = AgentProfile(
    id: AgentProfileId.researcher,
    label: 'Researcher',
    description: 'Read-only technical researcher for project-local knowledge.',
    allowedTools: _readOnly,
    systemPrompt: '''
You are the Hiide Researcher subagent.
You are strictly read-only.
Investigate project-local documentation, implementation patterns, dependencies and existing conventions relevant to the task.
Return evidence-backed recommendations and cite exact files.
''',
    maxIterations: 8,
    parallelSafe: true,
  );

  static const builtIns = <AgentProfile>[
    build,
    plan,
    explore,
    reviewer,
    tester,
    security,
    researcher,
  ];

  static AgentProfile byId(AgentProfileId id) =>
      builtIns.firstWhere((profile) => profile.id == id);
}
