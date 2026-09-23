import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/backend/agent_controller.dart';
import '../../core/design_system/tokens.dart';
import '../../core/providers/backend_provider.dart';
import '../../features/terminal/terminal_screen.dart';
import '../../shared/models/chat_message.dart';
import '../../shared/models/editor_tab.dart';
import '../../shared/providers/editor_providers.dart';
import '../../shared/widgets/ai_widgets.dart';

final chatMessagesProvider = StateProvider<List<ChatMessage>>((ref) => []);
final chatInputProvider = StateProvider<String>((ref) => '');
final streamingMessageProvider = StateProvider<String>((ref) => '');

/// Canonical conversation history in OpenAI chat format. Persisted across
/// turns so the agent loop can continue a multi-step task.
final agentMessagesProvider =
    StateProvider<List<Map<String, dynamic>>>((ref) => []);

/// One-shot prompt injected by the editor ("Ask AI" actions). The chat
/// sidebar watches this and sends it automatically.
final aiPromptProvider = StateProvider<String?>((ref) => null);

/// Max characters of the active file injected as context per turn.
const _activeFileContextChars = 3000;

class AiChatSidebar extends ConsumerStatefulWidget {
  const AiChatSidebar({super.key});

  @override
  ConsumerState<AiChatSidebar> createState() => _AiChatSidebarState();
}

class _AiChatSidebarState extends ConsumerState<AiChatSidebar> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  AgentController? _agentController;

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _addMessage(ChatMessage msg) {
    ref.read(chatMessagesProvider.notifier).state = [
      ...ref.read(chatMessagesProvider),
      msg,
    ];
    _scrollToBottom();
  }

  EditorTab? _activeTabNow() {
    final activeId = ref.read(activeTabIdProvider);
    final tabs = ref.read(openTabsProvider);
    if (activeId == null || tabs.isEmpty) return null;
    return tabs.firstWhere(
      (t) => t.id == activeId,
      orElse: () => tabs.first,
    );
  }

  /// Appends active-file context to the user message so the agent sees what
  /// the user is looking at.
  String _buildUserPrompt(String message, EditorTab? tab) {
    if (tab == null || tab.content.isEmpty) return message;
    final preview = tab.content.length > _activeFileContextChars
        ? '${tab.content.substring(0, _activeFileContextChars)}\n…[truncated]'
        : tab.content;
    return '$message\n\n'
        '--- Context: active file ${tab.path ?? tab.title} '
        '(first $_activeFileContextChars chars) ---\n'
        '$preview';
  }

  Future<void> _sendMessage([String? preset]) async {
    final text = (preset ?? _inputController.text).trim();
    if (text.isEmpty) return;
    if (ref.read(isAiThinkingProvider)) return;

    _inputController.clear();
    _addMessage(ChatMessage(
      role: ChatRole.user,
      content: text,
      timestamp: DateTime.now(),
    ));

    ref.read(isAiThinkingProvider.notifier).state = true;
    ref.read(streamingMessageProvider.notifier).state = '';

    try {
      final groqAsync = await ref.read(groqAiServiceProvider.future);
      final workspaceService = ref.read(workspaceServiceProvider);
      final backend = ref.read(backendServiceProvider);

      final userContent = _buildUserPrompt(text, _activeTabNow());
      final history =
          List<Map<String, dynamic>>.from(ref.read(agentMessagesProvider));
      history.add({'role': 'user', 'content': userContent});

      final controller = AgentController(
        ai: groqAsync,
        backend: backend,
        workspaceRoot: workspaceService.rootPath,
        model: groqAsync.defaultModel,
      );
      _agentController = controller;

      await for (final event in controller.run(history)) {
        if (!mounted) break;
        switch (event) {
          case AgentTextTokenEvent():
            ref.read(streamingMessageProvider.notifier).state =
                ref.read(streamingMessageProvider) + event.token;
            _scrollToBottom();

          case AgentToolStartedEvent():
            _addToolBubble(event.toolCall);

          case AgentToolFinishedEvent():
            _updateToolBubble(event.toolCall);
            _refreshOpenTabAfterTool(event.toolCall);
            // Mirror engine-executed commands into the terminal panel.
            if (event.toolCall.name == 'run_command') {
              final command =
                  event.toolCall.arguments['command']?.toString() ?? '';
              if (command.isNotEmpty) {
                ref
                    .read(terminalServiceProvider)
                    .logAgentRun(command, event.toolCall.result ?? '');
              }
            }

          case AgentDoneEvent():
            ref.read(streamingMessageProvider.notifier).state = '';
            if (event.text.trim().isNotEmpty) {
              _addMessage(ChatMessage(
                role: ChatRole.assistant,
                content: event.text,
                timestamp: DateTime.now(),
              ));
            }

          case AgentErrorEvent():
            ref.read(streamingMessageProvider.notifier).state = '';
            _addMessage(ChatMessage(
              role: ChatRole.error,
              content: 'Error: ${event.message}',
              timestamp: DateTime.now(),
            ));

          case AgentStoppedEvent():
            ref.read(streamingMessageProvider.notifier).state = '';
            _addMessage(ChatMessage(
              role: ChatRole.system,
              content: '⏹ Stopped by user.',
              timestamp: DateTime.now(),
            ));

          case AgentIterationLimitEvent():
            ref.read(streamingMessageProvider.notifier).state = '';
            _addMessage(ChatMessage(
              role: ChatRole.error,
              content:
                  'Stopped after ${event.iterations} tool rounds. The task '
                  'may need a more specific instruction.',
              timestamp: DateTime.now(),
            ));
        }
      }

      // Persist the canonical API history for the next turn.
      ref.read(agentMessagesProvider.notifier).state =
          List<Map<String, dynamic>>.from(controller.workingMessages);
    } catch (e) {
      ref.read(streamingMessageProvider.notifier).state = '';
      _addMessage(ChatMessage(
        role: ChatRole.error,
        content: 'Error: $e',
        timestamp: DateTime.now(),
      ));
    } finally {
      _agentController = null;
      if (mounted) {
        ref.read(isAiThinkingProvider.notifier).state = false;
      }
    }
  }

  void _stopAgent() {
    _agentController?.stop();
  }

  // ─── Tool call bubbles ────────────────────────────────────────────────────

  void _addToolBubble(AgentToolCall call) {
    _addMessage(ChatMessage(
      role: ChatRole.tool,
      content: '',
      timestamp: DateTime.now(),
      toolCall: ToolCallInfo(
        id: call.id,
        toolName: call.name,
        arguments: call.arguments,
        isRunning: true,
      ),
    ));
  }

  void _updateToolBubble(AgentToolCall call) {
    final messages = ref.read(chatMessagesProvider);
    final index = messages.indexWhere(
        (m) => m.role == ChatRole.tool && m.toolCall?.id == call.id);
    if (index < 0) return;
    final updated = messages[index].copyWith(
      toolCall: messages[index].toolCall!.copyWith(
            result: call.result,
            isRunning: false,
            isError: call.status == AgentToolStatus.error,
          ),
    );
    ref.read(chatMessagesProvider.notifier).state =
        List<ChatMessage>.from(messages)..[index] = updated;
    _scrollToBottom();
  }

  /// If the agent created, edited or deleted a file, update tabs and file tree
  /// so the user immediately sees the change in the IDE.
  void _refreshOpenTabAfterTool(AgentToolCall call) {
    if (call.status != AgentToolStatus.success) return;
    final path = call.arguments['path']?.toString();
    final workspaceService = ref.read(workspaceServiceProvider);

    if (call.name == 'create_directory') {
      ref.invalidate(fileTreeProvider);
      return;
    }

    if (call.name == 'delete_file') {
      ref.invalidate(fileTreeProvider);
      if (path != null && path.isNotEmpty) {
        final absPath =
            path.startsWith('/') ? path : '${workspaceService.rootPath}/$path';
        final tabs = ref.read(openTabsProvider);
        final remainingTabs = tabs.where((t) {
          final p = t.path;
          if (p == null) return true;
          return p != absPath && p != path && !p.startsWith('$absPath/');
        }).toList();

        if (remainingTabs.length != tabs.length) {
          ref.read(openTabsProvider.notifier).state = remainingTabs;
          final activeId = ref.read(activeTabIdProvider);
          if (remainingTabs.isEmpty) {
            ref.read(activeTabIdProvider.notifier).state = null;
          } else if (!remainingTabs.any((t) => t.id == activeId)) {
            ref.read(activeTabIdProvider.notifier).state =
                remainingTabs.last.id;
          }
        }
      }
      return;
    }

    if (call.name != 'write_file' && call.name != 'apply_diff') return;
    if (path == null || path.isEmpty) return;

    // The model may have addressed the file by a workspace-relative path;
    // tabs are keyed by absolute paths, so resolve before reading.
    final absPath =
        path.startsWith('/') ? path : '${workspaceService.rootPath}/$path';
    workspaceService.readFile(absPath).then((content) {
      if (!mounted) return;
      final tabs = ref.read(openTabsProvider);
      final idx = tabs.indexWhere((t) => t.path == absPath || t.path == path);
      if (idx >= 0) {
        final updated = tabs[idx].copyWith(content: content, isModified: false);
        ref.read(openTabsProvider.notifier).state = List<EditorTab>.from(tabs)
          ..[idx] = updated;
      }
      ref.invalidate(fileTreeProvider);
    }).catchError((_) {
      ref.invalidate(fileTreeProvider);
    });
  }

  void _clearChat() {
    ref.read(chatMessagesProvider.notifier).state = [];
    ref.read(agentMessagesProvider.notifier).state = [];
    ref.read(streamingMessageProvider.notifier).state = '';
  }

  /// Saves the conversation as a Markdown file in the workspace root
  /// (`chat-export-<timestamp>.md`) and confirms with a snackbar.
  Future<void> _exportChat() async {
    final messages = ref.read(chatMessagesProvider);
    if (messages.isEmpty) return;
    final workspace = ref.read(workspaceServiceProvider);

    final ts = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${ts.year}${two(ts.month)}${two(ts.day)}-${two(ts.hour)}${two(ts.minute)}${two(ts.second)}';
    final fileName = 'chat-export-$stamp.md';

    final buffer = StringBuffer()
      ..writeln('# Hiide AI — Sohbet Dışa Aktarımı')
      ..writeln()
      ..writeln('*${ts.toLocal()}*')
      ..writeln();
    for (final m in messages) {
      switch (m.role) {
        case ChatRole.user:
          buffer
            ..writeln('## 🧑 Kullanıcı')
            ..writeln()
            ..writeln(m.content)
            ..writeln();
        case ChatRole.assistant:
          buffer
            ..writeln('## 🤖 Hiide AI')
            ..writeln()
            ..writeln(m.content)
            ..writeln();
        case ChatRole.error:
          buffer
            ..writeln('## ⚠️ Hata')
            ..writeln()
            ..writeln(m.content)
            ..writeln();
        case ChatRole.system:
          buffer
            ..writeln('> _${m.content}_')
            ..writeln();
        case ChatRole.tool:
          final call = m.toolCall;
          if (call != null) {
            buffer
              ..writeln('> ⚙️ **${call.toolName}**'
                  '${call.isRunning ? ' _(çalışıyor…)_' : ''}')
              ..writeln();
            if (call.result != null && call.result!.isNotEmpty) {
              buffer
                ..writeln('```')
                ..writeln(call.result!)
                ..writeln('```')
                ..writeln();
            }
          }
      }
    }

    try {
      final path = '${workspace.rootPath}/$fileName';
      await workspace.writeFile(path, buffer.toString());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Dışa aktarıldı: $fileName'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Dışa aktarma başarısız: $e'),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(chatMessagesProvider);
    final isThinking = ref.watch(isAiThinkingProvider);
    final streamingText = ref.watch(streamingMessageProvider);
    final cs = Theme.of(context).colorScheme;

    // Editor "Ask AI" actions inject a one-shot prompt here.
    ref.listen<String?>(aiPromptProvider, (prev, next) {
      if (next == null || next.isEmpty) return;
      ref.read(aiPromptProvider.notifier).state = null;
      if (mounted) _sendMessage(next);
    });

    final modelLabel =
        ref.read(groqAiServiceProvider).valueOrNull?.defaultModel ?? '…';

    // Live Groq connectivity (probed against the API, not assumed).
    final connection = ref.watch(groqConnectionProvider);
    final (dotColor, statusLabel) = switch (connection) {
      AsyncData(:final value) => value.ok
          ? (const Color(0xFF3FB950), isThinking ? 'Working' : 'Live')
          : (cs.error, 'Offline'),
      AsyncError() => (cs.error, 'Offline'),
      _ => (Colors.amber, 'Checking…'),
    };
    final offlineReason = switch (connection) {
      AsyncData(:final value) when !value.ok => value.message,
      _ => null,
    };

    return Container(
      color: cs.surface,
      child: Column(
        children: [
          // ─── Header ────────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: DesignTokens.space4, vertical: DesignTokens.space3),
            decoration: BoxDecoration(
              border: Border(
                  bottom: BorderSide(
                      color: cs.outlineVariant,
                      width: DesignTokens.borderWidthThin)),
            ),
            child: Row(
              children: [
                const AiOrb(
                  icon: Icons.auto_awesome,
                  size: DesignTokens.space7,
                  iconSize: DesignTokens.iconMD,
                ),
                const SizedBox(width: DesignTokens.space2),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Hiide AI',
                        style: TextStyle(
                          color: cs.onSurface,
                          fontSize: DesignTokens.fontSizeMD,
                          fontWeight: DesignTokens.fontWeightSemibold,
                        ),
                      ),
                      Text(
                        'Groq · $modelLabel',
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: DesignTokens.fontSizeXS,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                if (isThinking) ...[
                  // Stop button
                  IconButton(
                    icon: const Icon(Icons.stop_circle_outlined,
                        size: DesignTokens.iconSM),
                    color: cs.error,
                    onPressed: _stopAgent,
                    tooltip: 'Stop agent',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 24, minHeight: 24),
                  ),
                  const SizedBox(width: DesignTokens.space2),
                ],
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 4),
                Text(statusLabel,
                    style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: DesignTokens.fontSizeXS)),
                const SizedBox(width: DesignTokens.space2),
                IconButton(
                  icon: Icon(Icons.save_alt,
                      size: DesignTokens.iconSM, color: cs.onSurfaceVariant),
                  onPressed:
                      isThinking || messages.isEmpty ? null : _exportChat,
                  tooltip: 'Sohbeti dışa aktar (Markdown)',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 24, minHeight: 24),
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline,
                      size: DesignTokens.iconSM, color: cs.onSurfaceVariant),
                  onPressed: isThinking ? null : _clearChat,
                  tooltip: 'Clear chat',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 24, minHeight: 24),
                ),
              ],
            ),
          ),

          // ─── Messages (or welcome panel on first run) ─────────────────────
          Expanded(
            child: messages.isEmpty && streamingText.isEmpty
                ? _WelcomePanel(onPrompt: _sendMessage)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(DesignTokens.space3),
                    itemCount:
                        messages.length + (streamingText.isNotEmpty ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == messages.length &&
                          streamingText.isNotEmpty) {
                        return _StreamingBubble(text: streamingText);
                      }
                      return _ChatBubble(message: messages[index]);
                    },
                  ),
          ),

          // ─── AI Thinking Indicator ─────────────────────────────────────────
          if (isThinking && streamingText.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: DesignTokens.space4,
                  vertical: DesignTokens.space2),
              child: Row(
                children: [
                  const _ThinkingDots(),
                  const SizedBox(width: DesignTokens.space2),
                  Text(
                    'Agent is working...',
                    style: TextStyle(
                        color: cs.primary, fontSize: DesignTokens.fontSizeXS),
                  ),
                ],
              ),
            ),

          // ─── Offline banner (Groq unreachable) ────────────────────────────
          if (offlineReason != null)
            _OfflineBanner(
              message: offlineReason,
              onRetry: () => ref.invalidate(groqConnectionProvider),
            ),

          // ─── Input Bar ────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(DesignTokens.space3),
            decoration: BoxDecoration(
              border: Border(
                  top: BorderSide(
                      color: cs.outlineVariant,
                      width: DesignTokens.borderWidthThin)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius:
                          BorderRadius.circular(DesignTokens.radiusMD),
                      border: Border.all(color: cs.outlineVariant),
                    ),
                    child: TextField(
                      controller: _inputController,
                      maxLines: 4,
                      minLines: 1,
                      style: TextStyle(
                          color: cs.onSurface,
                          fontSize: DesignTokens.fontSizeMD),
                      decoration: InputDecoration(
                        hintText: 'Ask Hiide AI to build, fix or explain…',
                        hintStyle: TextStyle(color: cs.onSurfaceVariant),
                        border: InputBorder.none,
                        contentPadding:
                            const EdgeInsets.all(DesignTokens.space3),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                ),
                const SizedBox(width: DesignTokens.space2),
                AnimatedContainer(
                  duration: DesignTokens.durationFast,
                  child: IconButton.filled(
                    onPressed: isThinking ? null : _sendMessage,
                    icon: isThinking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send, size: DesignTokens.iconSM),
                    tooltip: 'Send (Enter)',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Offline banner ───────────────────────────────────────────────────────────

class _OfflineBanner extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _OfflineBanner({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final short =
        message.length > 100 ? '${message.substring(0, 100)}…' : message;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
          DesignTokens.space3, DesignTokens.space2, DesignTokens.space3, 0),
      padding: const EdgeInsets.symmetric(
          horizontal: DesignTokens.space3, vertical: DesignTokens.space1),
      decoration: BoxDecoration(
        color: cs.errorContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(DesignTokens.radiusMD),
        border: Border.all(color: cs.error.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: DesignTokens.iconXS, color: cs.error),
          const SizedBox(width: DesignTokens.space2),
          Expanded(
            child: Text(
              'Groq offline: $short',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.onErrorContainer,
                fontSize: DesignTokens.fontSizeXS,
              ),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding:
                  const EdgeInsets.symmetric(horizontal: DesignTokens.space2),
            ),
            child: Text('Retry',
                style: TextStyle(
                    color: cs.error, fontSize: DesignTokens.fontSizeXS)),
          ),
        ],
      ),
    );
  }
}

// ─── Welcome panel (empty chat) ───────────────────────────────────────────────

class _WelcomePanel extends StatelessWidget {
  const _WelcomePanel({required this.onPrompt});

  final void Function(String prompt) onPrompt;

  static const List<(String, String)> _suggestions = [
    (
      'Explain the active file',
      'Explain what the active file does, its structure and how it fits the project.'
    ),
    (
      'Find and fix bugs',
      'Carefully review the active file for bugs and real issues. Fix them with apply_diff, then verify with a build or test command.'
    ),
    (
      'Write tests',
      'Write unit tests for the active file following the project conventions, then run them and report the results.'
    ),
    (
      'Optimize performance',
      'Review the active file for performance issues and apply concrete, verifiable optimizations.'
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(DesignTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: DesignTokens.space2),
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [cs.primary, cs.tertiary],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(DesignTokens.radiusXL),
            ),
            child: const Icon(Icons.auto_awesome,
                color: Colors.white, size: DesignTokens.iconLG),
          ),
          const SizedBox(height: DesignTokens.space3),
          Text(
            'Hiide AI',
            style: TextStyle(
              color: cs.onSurface,
              fontSize: DesignTokens.fontSize2XL,
              fontWeight: DesignTokens.fontWeightSemibold,
            ),
          ),
          const SizedBox(height: DesignTokens.space1),
          Text(
            'Build, fix or explain — the agent reads your files, edits them '
            'and runs commands in the workspace.',
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: DesignTokens.fontSizeMD,
              height: DesignTokens.lineHeightNormal,
            ),
          ),
          const SizedBox(height: DesignTokens.space5),
          Text(
            'Try asking',
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: DesignTokens.fontSizeXS,
              fontWeight: DesignTokens.fontWeightSemibold,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: DesignTokens.space2),
          Wrap(
            spacing: DesignTokens.space2,
            runSpacing: DesignTokens.space2,
            children: [
              for (final (label, prompt) in _suggestions)
                ActionChip(
                  label: Text(
                    label,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: DesignTokens.fontSizeSM,
                    ),
                  ),
                  avatar: Icon(Icons.auto_awesome,
                      size: DesignTokens.iconXS, color: cs.primary),
                  backgroundColor: cs.primary.withValues(alpha: 0.08),
                  side: BorderSide(color: cs.outlineVariant),
                  onPressed: () => onPrompt(prompt),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Streaming bubble ─────────────────────────────────────────────────────────

class _StreamingBubble extends StatelessWidget {
  final String text;
  const _StreamingBubble({required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: DesignTokens.space1),
        padding: const EdgeInsets.all(DesignTokens.space3),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(DesignTokens.radiusLG),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SelectableText(
                text,
                style: TextStyle(
                    color: cs.onSurface,
                    fontSize: DesignTokens.fontSizeMD,
                    height: 1.5),
              ),
            ),
            const SizedBox(width: 4),
            _BlinkingCursor(),
          ],
        ),
      ),
    );
  }
}

class _BlinkingCursor extends StatefulWidget {
  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _ctrl,
      child: Container(
        width: 2,
        height: 16,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

// ─── Thinking dots animation ──────────────────────────────────────────────────

class _ThinkingDots extends StatefulWidget {
  const _ThinkingDots();

  @override
  State<_ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<_ThinkingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final step = (_ctrl.value * 3).floor();
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: i <= step ? color : color.withValues(alpha: 0.3),
                shape: BoxShape.circle,
              ),
            );
          }),
        );
      },
    );
  }
}

// ─── Chat Bubble ─────────────────────────────────────────────────────────────

class _ChatBubble extends StatelessWidget {
  final ChatMessage message;
  const _ChatBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isUser = message.role == ChatRole.user;
    final isTool = message.role == ChatRole.tool;
    final isError = message.role == ChatRole.error;
    final isSystem = message.role == ChatRole.system;

    // Tool call result bubble
    if (isTool && message.toolCall != null) {
      final info = message.toolCall!;
      return _ToolBubble(info: info, cs: cs);
    }

    // System / informational bubble (e.g. "Stopped by user")
    if (isSystem) {
      return Align(
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: DesignTokens.space1),
          child: Text(
            message.content,
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: DesignTokens.fontSizeXS,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      );
    }

    final bubbleColor = isUser
        ? cs.primaryContainer
        : isError
            ? cs.errorContainer
            : cs.surfaceContainerHighest;

    final textColor = isUser
        ? cs.onPrimaryContainer
        : isError
            ? cs.onErrorContainer
            : cs.onSurface;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: DesignTokens.space1),
        constraints: const BoxConstraints(maxWidth: 280),
        padding: const EdgeInsets.all(DesignTokens.space3),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.circular(DesignTokens.radiusLG),
        ),
        child: SelectableText(
          message.content,
          style: TextStyle(
            color: textColor,
            fontSize: DesignTokens.fontSizeMD,
            height: 1.5,
          ),
        ),
      ),
    );
  }
}

/// A tool invocation card: shows a live spinner while running, then the
/// result with success/error styling.
class _ToolBubble extends StatelessWidget {
  final ToolCallInfo info;
  final ColorScheme cs;

  const _ToolBubble({required this.info, required this.cs});

  @override
  Widget build(BuildContext context) {
    final running = info.isRunning;
    final failed = info.isError;

    final (icon, iconColor) = running
        ? (Icons.hourglass_top, cs.primary)
        : failed
            ? (Icons.error_outline, cs.error)
            : (Icons.check_circle_outline, const Color(0xFF3FB950));

    return Container(
      margin: const EdgeInsets.symmetric(vertical: DesignTokens.space1),
      padding: const EdgeInsets.all(DesignTokens.space2),
      decoration: BoxDecoration(
        color: cs.secondaryContainer.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(DesignTokens.radiusMD),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (running)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(icon, size: DesignTokens.iconXS, color: iconColor),
              const SizedBox(width: DesignTokens.space1),
              Expanded(
                child: Text(
                  '⚙ ${info.toolName}',
                  style: TextStyle(
                    color: cs.secondary,
                    fontWeight: FontWeight.bold,
                    fontSize: DesignTokens.fontSizeXS,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (info.result != null && info.result!.isNotEmpty) ...[
            const SizedBox(height: DesignTokens.space1),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 160),
              padding: const EdgeInsets.all(DesignTokens.space2),
              decoration: BoxDecoration(
                color: cs.surface.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(DesignTokens.radiusSM),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  info.result!,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontFamily: 'JetBrains Mono',
                    fontSize: DesignTokens.fontSizeXS,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
