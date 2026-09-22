import 'dart:io';

import 'package:flutter/material.dart';
import '../../core/backend/workspace_service.dart';
import '../../core/design_system/tokens.dart';

/// Interactive folder browser for picking a workspace root. Returns the
/// selected absolute path via `Navigator.pop`, or null when cancelled.
///
/// Robustness guarantees:
/// - The path bar only advances to directories that were actually read; a
///   missing/unreadable directory shows an inline error and disables the
///   confirm button, so an invalid folder can never be selected.
/// - Dotfiles are hidden by default and toggleable.
/// - A "Sistem seçici" button opens the native OS picker when one is
///   available (zenity/kdialog on Linux, FolderBrowserDialog on Windows).
class FolderBrowserDialog extends StatefulWidget {
  final String initialPath;

  const FolderBrowserDialog({super.key, required this.initialPath});

  @override
  State<FolderBrowserDialog> createState() => _FolderBrowserDialogState();
}

class _FolderBrowserDialogState extends State<FolderBrowserDialog> {
  late String currentPath;
  List<FileSystemEntity> entities = const [];
  String? _error;
  bool _showHidden = false;
  late final String _homeDir;

  @override
  void initState() {
    super.initState();
    _homeDir = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '/';
    final initial =
        widget.initialPath.trim().isEmpty ? _homeDir : widget.initialPath;
    currentPath = initial;
    _reload();
  }

  /// (Re)reads [currentPath]. On failure the path is kept but an inline error
  /// is shown and the confirm action becomes disabled — the user is never
  /// offered to select a folder that does not exist or cannot be read.
  void _reload() {
    _error = null;
    List<FileSystemEntity> list;
    try {
      final dir = Directory(currentPath);
      if (!dir.existsSync()) {
        _error = 'Klasör bulunamadı: $currentPath';
        setState(() {});
        return;
      }
      list = dir.listSync(followLinks: false);
    } catch (e) {
      _error = 'Klasör okunamadı: $e';
      setState(() {});
      return;
    }

    final visible =
        _showHidden ? list : list.where((e) => !_entryName(e).startsWith('.'));
    final sorted = [...visible]..sort((a, b) {
        final aDir = a is Directory;
        final bDir = b is Directory;
        if (aDir != bDir) return aDir ? -1 : 1;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
    setState(() {
      entities = sorted;
    });
  }

  void _loadDirectory(String path) {
    if (path == currentPath) {
      _reload();
      return;
    }
    currentPath = path;
    _reload();
  }

  void _goUp() {
    final parent = Directory(currentPath).parent;
    if (parent.path != currentPath) {
      _loadDirectory(parent.path);
    }
  }

  void _goHome() => _loadDirectory(_homeDir);

  /// Last path segment, robust to trailing separators (e.g. the root `/`).
  String _entryName(FileSystemEntity e) => pathBasename(e.path);

  Future<void> _openNativePicker() async {
    final result = await WorkspaceService.pickDirectoryWithNativeDialog();
    if (!mounted) return;
    if (result.path != null) {
      Navigator.pop(context, result.path);
      return;
    }
    // A plain cancel has no message; anything else is surfaced so the button
    // never fails silently.
    if (result.message.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result.message),
        duration: const Duration(seconds: 4),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // The current path is selectable only when it is an existing directory.
    final canSelect = _error == null && _isReadableDir(currentPath);

    final media = MediaQuery.sizeOf(context);
    final dialogWidth = media.width < 640 ? media.width - 24 : 600.0;
    final dialogHeight = media.height < 620 ? media.height - 32 : 500.0;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: dialogWidth.clamp(280.0, 600.0),
          maxHeight: dialogHeight.clamp(280.0, 500.0),
        ),
        child: Padding(
          padding: const EdgeInsets.all(DesignTokens.space4),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.folder_special, color: cs.primary),
                const SizedBox(width: DesignTokens.space2),
                Expanded(
                  child: Text(
                    'Dosya Yöneticisi — Proje Klasörü Seç',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: cs.onSurface,
                        fontSize: DesignTokens.fontSizeLG,
                        fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context, null),
                ),
              ],
            ),
            const Divider(),
            // Path Navigation Header
            LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 430;
                final pathBox = Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    currentPath,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontFamily: 'JetBrains Mono',
                      fontSize: DesignTokens.fontSizeSM,
                    ),
                  ),
                );

                Widget visibilityButton() => IconButton(
                      icon: Icon(
                        _showHidden ? Icons.visibility : Icons.visibility_off,
                        size: DesignTokens.iconSM,
                      ),
                      tooltip: 'Gizli dosyalar',
                      onPressed: () {
                        setState(() => _showHidden = !_showHidden);
                        _reload();
                      },
                    );

                return compact
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.arrow_upward),
                                onPressed: _goUp,
                                tooltip: 'Üst Klasör',
                              ),
                              IconButton(
                                icon: const Icon(Icons.home_outlined),
                                onPressed: _goHome,
                                tooltip: 'Ana Klasör',
                              ),
                              const Spacer(),
                              visibilityButton(),
                            ],
                          ),
                          pathBox,
                        ],
                      )
                    : Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_upward),
                            onPressed: _goUp,
                            tooltip: 'Üst Klasör',
                          ),
                          IconButton(
                            icon: const Icon(Icons.home_outlined),
                            onPressed: _goHome,
                            tooltip: 'Ana Klasör',
                          ),
                          Expanded(child: pathBox),
                          visibilityButton(),
                        ],
                      );
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: DesignTokens.space2),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    horizontal: DesignTokens.space3,
                    vertical: DesignTokens.space1),
                decoration: BoxDecoration(
                  color: cs.errorContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  _error!,
                  style: TextStyle(
                      color: cs.onErrorContainer,
                      fontSize: DesignTokens.fontSizeXS),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            const SizedBox(height: DesignTokens.space2),
            // Directory Contents List
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: cs.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: entities.isEmpty
                    ? Center(
                        child: Text(
                          'Bu klasörde öğe yok',
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                      )
                    : ListView.builder(
                        itemCount: entities.length,
                        itemBuilder: (context, index) {
                          final item = entities[index];
                          final isDir = item is Directory;
                          final name = _entryName(item);

                            return ListTile(
                              dense: true,
                              leading: Icon(
                                isDir ? Icons.folder : Icons.insert_drive_file,
                                color: isDir ? cs.primary : cs.onSurfaceVariant,
                              ),
                              title: Text(
                                name,
                                style: TextStyle(
                                  color: cs.onSurface,
                                  fontWeight:
                                      isDir ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                              trailing: isDir
                                  ? OutlinedButton.icon(
                                      style: OutlinedButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: DesignTokens.space2),
                                      ),
                                      icon: const Icon(Icons.check,
                                          size: DesignTokens.iconXS),
                                      label: const Text('Seç',
                                          style: TextStyle(
                                              fontSize: DesignTokens.fontSizeXS)),
                                      onPressed: () =>
                                          Navigator.pop(context, item.path),
                                    )
                                  : null,
                              onTap: () {
                                if (isDir) {
                                  _loadDirectory(item.path);
                                }
                              },
                            );
                        },
                      ),
              ),
            ),
            const SizedBox(height: DesignTokens.space3),
            // Action Buttons — a Wrap so narrow dialogs wrap instead of
            // overflowing the flex row.
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: DesignTokens.space2,
              runSpacing: DesignTokens.space1,
              children: [
                TextButton.icon(
                  onPressed: _openNativePicker,
                  icon: const Icon(Icons.laptop, size: DesignTokens.iconSM),
                  label: const Text('Sistem seçici'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, null),
                  child: const Text('İptal'),
                ),
                ElevatedButton.icon(
                  onPressed: canSelect
                      ? () => Navigator.pop(context, currentPath)
                      : null,
                  icon: const Icon(Icons.check),
                  label: const Text('Bu Klasörü Çalışma Alanı Yap'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
    );
  }

  bool _isReadableDir(String path) {
    try {
      return Directory(path).existsSync();
    } catch (_) {
      return false;
    }
  }
}
