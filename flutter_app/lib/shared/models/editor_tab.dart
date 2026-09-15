import 'package:flutter/material.dart';

class EditorTab {
  final String id;
  final String title;
  final String? path;
  final String content;
  final IconData? icon;
  final bool isModified;
  final bool isActive;

  const EditorTab({
    required this.id,
    required this.title,
    this.path,
    this.content = '',
    this.icon,
    this.isModified = false,
    this.isActive = false,
  });

  EditorTab copyWith({
    String? id,
    String? title,
    String? path,
    String? content,
    IconData? icon,
    bool? isModified,
    bool? isActive,
  }) {
    return EditorTab(
      id: id ?? this.id,
      title: title ?? this.title,
      path: path ?? this.path,
      content: content ?? this.content,
      icon: icon ?? this.icon,
      isModified: isModified ?? this.isModified,
      isActive: isActive ?? this.isActive,
    );
  }
}
