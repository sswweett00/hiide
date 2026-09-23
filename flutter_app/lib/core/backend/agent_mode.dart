import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AgentMode { plan, code }

extension AgentModeX on AgentMode {
  String get label => switch (this) {
    AgentMode.plan => 'Plan',
    AgentMode.code => 'Code',
  };

  String get description => switch (this) {
    AgentMode.plan => 'Kapsamı, bağımlılıkları, riskleri ve doğrulamayı çıkarır; dosya değiştirmez.',
    AgentMode.code => 'İsteği uygular, dosyaları düzenler, testleri çalıştırır ve sonucu doğrular.',
  };

  IconData get icon => switch (this) {
    AgentMode.plan => Icons.account_tree_outlined,
    AgentMode.code => Icons.code_rounded,
  };
}

final agentModeProvider = StateProvider<AgentMode>((ref) => AgentMode.code);
final lastPlanProvider = StateProvider<String?>((ref) => null);