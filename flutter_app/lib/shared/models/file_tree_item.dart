import 'package:flutter/material.dart';

class FileTreeItem {
  final String name;
  final String path;
  final bool isFile;
  final List<FileTreeItem> children;
  final IconData icon;

  const FileTreeItem({
    required this.name,
    required this.path,
    this.isFile = false,
    this.children = const [],
    this.icon = Icons.description_outlined,
  });

  FileTreeItem copyWith({
    String? name,
    String? path,
    bool? isFile,
    List<FileTreeItem>? children,
    IconData? icon,
  }) {
    return FileTreeItem(
      name: name ?? this.name,
      path: path ?? this.path,
      isFile: isFile ?? this.isFile,
      children: children ?? this.children,
      icon: icon ?? this.icon,
    );
  }
}
