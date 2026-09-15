import 'package:flutter/material.dart';
import '../../core/routing/router.dart';

enum ActivityItem {
  files('files', Icons.folder_outlined, Icons.folder, RoutePath.explorer),
  search('search', Icons.search_outlined, Icons.search, RoutePath.search),
  sourceControl('sourceControl', Icons.source_outlined, Icons.source,
      RoutePath.sourceControl),
  debug('debug', Icons.bug_report_outlined, Icons.bug_report, RoutePath.debug),
  extensions('extensions', Icons.extension_outlined, Icons.extension,
      RoutePath.extensions),
  ai('ai', Icons.auto_awesome_outlined, Icons.auto_awesome, RoutePath.dashboard),
  settings(
      'settings', Icons.settings_outlined, Icons.settings, RoutePath.settings);

  final String id;
  final IconData icon;
  final IconData activeIcon;
  final RoutePath? route;

  const ActivityItem(this.id, this.icon, this.activeIcon, this.route);
}
