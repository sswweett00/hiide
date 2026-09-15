enum ChatRole { user, assistant, system, tool, error }

class ToolCallInfo {
  final String? id;
  final String toolName;
  final Map<String, dynamic> arguments;
  final String? result;
  final bool isRunning;
  final bool isError;

  const ToolCallInfo({
    this.id,
    required this.toolName,
    required this.arguments,
    this.result,
    this.isRunning = false,
    this.isError = false,
  });

  ToolCallInfo copyWith({
    String? id,
    String? toolName,
    Map<String, dynamic>? arguments,
    String? result,
    bool? isRunning,
    bool? isError,
  }) {
    return ToolCallInfo(
      id: id ?? this.id,
      toolName: toolName ?? this.toolName,
      arguments: arguments ?? this.arguments,
      result: result ?? this.result,
      isRunning: isRunning ?? this.isRunning,
      isError: isError ?? this.isError,
    );
  }
}

class ChatMessage {
  final ChatRole role;
  final String content;
  final DateTime? timestamp;
  final ToolCallInfo? toolCall;

  const ChatMessage({
    required this.role,
    required this.content,
    this.timestamp,
    this.toolCall,
  });

  ChatMessage copyWith({
    ChatRole? role,
    String? content,
    DateTime? timestamp,
    ToolCallInfo? toolCall,
  }) {
    return ChatMessage(
      role: role ?? this.role,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      toolCall: toolCall ?? this.toolCall,
    );
  }
}
