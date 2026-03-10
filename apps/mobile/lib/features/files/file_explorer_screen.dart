import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:highlight/highlight.dart';
import 'package:highlight/languages/all.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/app_models.dart';
import '../../theme/app_theme.dart';

const Map<String, String> _languageByExtension = <String, String>{
  '.c': 'cpp',
  '.cc': 'cpp',
  '.cpp': 'cpp',
  '.cs': 'cs',
  '.css': 'css',
  '.dart': 'dart',
  '.go': 'go',
  '.gradle': 'gradle',
  '.h': 'cpp',
  '.hpp': 'cpp',
  '.html': 'xml',
  '.java': 'java',
  '.js': 'javascript',
  '.json': 'json',
  '.kt': 'kotlin',
  '.kts': 'kotlin',
  '.md': 'markdown',
  '.mjs': 'javascript',
  '.objc': 'objectivec',
  '.php': 'php',
  '.py': 'python',
  '.rb': 'ruby',
  '.rs': 'rust',
  '.sh': 'bash',
  '.sql': 'sql',
  '.swift': 'swift',
  '.toml': 'ini',
  '.ts': 'typescript',
  '.tsx': 'typescript',
  '.txt': 'plaintext',
  '.xml': 'xml',
  '.yaml': 'yaml',
  '.yml': 'yaml',
};

Mode? _languageForDocument(ProjectFileDocument file) {
  final key = _languageByExtension[file.extension?.toLowerCase() ?? ''] ??
      (file.extension == null ? 'plaintext' : null);
  if (key == null) {
    return allLanguages['plaintext'];
  }

  return allLanguages[key] ?? allLanguages['plaintext'];
}

String _formatBytes(int? sizeBytes) {
  if (sizeBytes == null) {
    return 'Directory';
  }

  if (sizeBytes < 1024) {
    return '$sizeBytes B';
  }

  const units = <String>['KB', 'MB', 'GB'];
  double value = sizeBytes / 1024;
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }

  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unitIndex]}';
}

class FileExplorerScreen extends StatefulWidget {
  const FileExplorerScreen({
    super.key,
    required this.project,
    required this.listing,
    required this.openFile,
    required this.openFileDraft,
    required this.hasUnsavedChanges,
    required this.onBrowseDirectory,
    required this.onOpenFile,
    required this.onDraftChanged,
    required this.onRefresh,
    required this.onSaveFile,
    required this.onUploadFiles,
    required this.onDownloadFile,
  });

  final ProjectItem? project;
  final ProjectFileListing? listing;
  final ProjectFileDocument? openFile;
  final String? openFileDraft;
  final bool hasUnsavedChanges;
  final Future<void> Function(String path) onBrowseDirectory;
  final Future<void> Function(String path) onOpenFile;
  final ValueChanged<String> onDraftChanged;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onSaveFile;
  final Future<void> Function(List<ProjectFileUpload> files) onUploadFiles;
  final Future<ProjectFileDownload?> Function(String path) onDownloadFile;

  @override
  State<FileExplorerScreen> createState() => _FileExplorerScreenState();
}

class _FileExplorerScreenState extends State<FileExplorerScreen> {
  Future<void> _pickAndUploadFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
    );
    if (result == null || result.files.isEmpty) {
      return;
    }

    final uploads = <ProjectFileUpload>[];
    for (final file in result.files) {
      final bytes = file.bytes ?? await file.xFile.readAsBytes();
      uploads.add(
        ProjectFileUpload(
          fileName: file.name,
          bytes: bytes,
        ),
      );
    }

    if (!mounted) {
      return;
    }

    await widget.onUploadFiles(uploads);
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          uploads.length == 1
              ? 'Uploaded ${uploads.first.fileName}'
              : 'Uploaded ${uploads.length} files',
        ),
      ),
    );
  }

  Future<void> _downloadFile(ProjectFileDocument file) async {
    final download = await widget.onDownloadFile(file.path);
    if (!mounted || download == null) {
      return;
    }

    try {
      final targetPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save ${download.fileName}',
        fileName: download.fileName,
      );

      if (targetPath != null && targetPath.trim().isNotEmpty) {
        await File(targetPath).writeAsBytes(download.bytes);
        if (!mounted) {
          return;
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved ${download.fileName}')),
        );
        return;
      }
    } catch (_) {
      // Fall back to the native share sheet when save dialogs are unavailable.
    }

    await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[
          XFile.fromData(
            download.bytes,
            mimeType: download.contentType,
          ),
        ],
        fileNameOverrides: <String>[download.fileName],
        title: 'Export ${download.fileName}',
        subject: download.fileName,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    final listing = widget.listing;
    final openFile = widget.openFile;

    if (project == null) {
      return const _FilePanePlaceholder(
        icon: Icons.folder_off_outlined,
        title: 'No Project Selected',
        body: 'Choose a project from the left panel to browse its files.',
      );
    }

    final narrow = MediaQuery.of(context).size.width < 1100;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
      child: Column(
        children: <Widget>[
          _ExplorerHeader(
            project: project,
            listing: listing,
            openFile: openFile,
            hasUnsavedChanges: widget.hasUnsavedChanges,
            onRefresh: widget.onRefresh,
            onUpload: _pickAndUploadFiles,
            onNavigate: (String path) => widget.onBrowseDirectory(path),
            onDownload: openFile == null ? null : () => _downloadFile(openFile),
            onSave: openFile == null ? null : widget.onSaveFile,
          ),
          const SizedBox(height: 14),
          Expanded(
            child: narrow
                ? Column(
                    children: <Widget>[
                      SizedBox(
                        height: 260,
                        child: _ExplorerPane(
                          listing: listing,
                          openFile: openFile,
                          onOpen: widget.onOpenFile,
                          onBrowse: widget.onBrowseDirectory,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Expanded(
                        child: _EditorPane(
                          file: openFile,
                          draft: widget.openFileDraft,
                          onChanged: widget.onDraftChanged,
                          onDownload: openFile == null
                              ? null
                              : () => _downloadFile(openFile),
                        ),
                      ),
                    ],
                  )
                : Row(
                    children: <Widget>[
                      SizedBox(
                        width: 330,
                        child: _ExplorerPane(
                          listing: listing,
                          openFile: openFile,
                          onOpen: widget.onOpenFile,
                          onBrowse: widget.onBrowseDirectory,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: _EditorPane(
                          file: openFile,
                          draft: widget.openFileDraft,
                          onChanged: widget.onDraftChanged,
                          onDownload: openFile == null
                              ? null
                              : () => _downloadFile(openFile),
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

class _ExplorerHeader extends StatelessWidget {
  const _ExplorerHeader({
    required this.project,
    required this.listing,
    required this.openFile,
    required this.hasUnsavedChanges,
    required this.onRefresh,
    required this.onUpload,
    required this.onNavigate,
    required this.onDownload,
    required this.onSave,
  });

  final ProjectItem project;
  final ProjectFileListing? listing;
  final ProjectFileDocument? openFile;
  final bool hasUnsavedChanges;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onUpload;
  final Future<void> Function(String path) onNavigate;
  final Future<void> Function()? onDownload;
  final Future<void> Function()? onSave;

  @override
  Widget build(BuildContext context) {
    final currentPath = listing?.currentPath ?? '';
    final segments = currentPath.isEmpty
        ? const <String>[]
        : currentPath
            .split('/')
            .where((segment) => segment.isNotEmpty)
            .toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppPalette.sky.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.folder_copy_outlined,
                    color: AppPalette.sky,
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      project.name,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      project.path,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppPalette.textMuted,
                          ),
                    ),
                  ],
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () {
                    onUpload();
                  },
                  icon: const Icon(Icons.upload_file_outlined),
                  label: const Text('Upload'),
                ),
                OutlinedButton.icon(
                  onPressed: () {
                    onRefresh();
                  },
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Refresh'),
                ),
                if (openFile != null)
                  OutlinedButton.icon(
                    onPressed: onDownload == null
                        ? null
                        : () {
                            onDownload!();
                          },
                    icon: const Icon(Icons.download_rounded),
                    label: const Text('Download'),
                  ),
                if (openFile != null)
                  FilledButton.icon(
                    onPressed: !hasUnsavedChanges || onSave == null
                        ? null
                        : () {
                            onSave!();
                          },
                    icon: const Icon(Icons.save_outlined),
                    label: Text(hasUnsavedChanges ? 'Save Changes' : 'Saved'),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  ActionChip(
                    avatar: const Icon(
                      Icons.home_outlined,
                      size: 16,
                    ),
                    label: const Text('Root'),
                    onPressed: () {
                      onNavigate('');
                    },
                  ),
                  for (var index = 0;
                      index < segments.length;
                      index++) ...<Widget>[
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: AppPalette.textMuted,
                      ),
                    ),
                    ActionChip(
                      label: Text(segments[index]),
                      onPressed: () {
                        onNavigate(segments.take(index + 1).join('/'));
                      },
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExplorerPane extends StatelessWidget {
  const _ExplorerPane({
    required this.listing,
    required this.openFile,
    required this.onOpen,
    required this.onBrowse,
  });

  final ProjectFileListing? listing;
  final ProjectFileDocument? openFile;
  final Future<void> Function(String path) onOpen;
  final Future<void> Function(String path) onBrowse;

  @override
  Widget build(BuildContext context) {
    final listing = this.listing;
    if (listing == null) {
      return const _FilePanePlaceholder(
        icon: Icons.folder_open_outlined,
        title: 'Loading Explorer',
        body: 'The project directory will appear here.',
      );
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: <Widget>[
                const Icon(Icons.account_tree_outlined, size: 18),
                const SizedBox(width: 8),
                Text(
                  listing.currentPath.isEmpty
                      ? 'Project Files'
                      : listing.currentPath,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Up',
                  onPressed: listing.parentPath == null
                      ? null
                      : () => onBrowse(listing.parentPath ?? ''),
                  icon: const Icon(Icons.arrow_upward_rounded),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: listing.entries.length,
              itemBuilder: (BuildContext context, int index) {
                final entry = listing.entries[index];
                final selected =
                    !entry.isDirectory && openFile?.path == entry.path;

                return ListTile(
                  dense: true,
                  selected: selected,
                  leading: Icon(
                    entry.isDirectory
                        ? Icons.folder_outlined
                        : Icons.description_outlined,
                    color: entry.isDirectory ? AppPalette.sky : AppPalette.mint,
                  ),
                  title: Text(
                    entry.name,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    entry.isDirectory
                        ? 'Folder'
                        : '${entry.extension ?? 'file'} • ${_formatBytes(entry.sizeBytes)}',
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: entry.isDirectory
                      ? const Icon(Icons.chevron_right_rounded)
                      : null,
                  onTap: () {
                    if (entry.isDirectory) {
                      onBrowse(entry.path);
                    } else {
                      onOpen(entry.path);
                    }
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _EditorPane extends StatelessWidget {
  const _EditorPane({
    required this.file,
    required this.draft,
    required this.onChanged,
    required this.onDownload,
  });

  final ProjectFileDocument? file;
  final String? draft;
  final ValueChanged<String> onChanged;
  final Future<void> Function()? onDownload;

  @override
  Widget build(BuildContext context) {
    final file = this.file;
    if (file == null) {
      return const _FilePanePlaceholder(
        icon: Icons.code_off_rounded,
        title: 'Open a File',
        body: 'Choose a source file from the explorer to view or edit it.',
      );
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Icon(Icons.code_rounded, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        file.path,
                        overflow: TextOverflow.ellipsis,
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    Chip(label: Text(_formatBytes(file.sizeBytes))),
                    if (file.extension != null)
                      Chip(label: Text(file.extension!.toUpperCase())),
                    Chip(
                      label: Text(
                        file.writable ? 'Editable' : 'Read only',
                      ),
                    ),
                    if (file.lastModifiedAt != null)
                      Chip(
                        label: Text(
                          'Updated ${file.lastModifiedAt!.toLocal().toString().substring(0, 16)}',
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Builder(
              builder: (BuildContext context) {
                if (file.isBinary) {
                  return _FilePanePlaceholder(
                    icon: Icons.memory_rounded,
                    title: 'Binary File',
                    body:
                        'This file is not editable in the in-app editor. Use download to inspect it with another app.',
                    actionLabel: 'Download',
                    onAction: onDownload,
                  );
                }

                if (file.tooLarge) {
                  return _FilePanePlaceholder(
                    icon: Icons.file_present_outlined,
                    title: 'File Too Large',
                    body:
                        'This file is larger than the in-app editor limit. Download it or open a smaller file.',
                    actionLabel: 'Download',
                    onAction: onDownload,
                  );
                }

                return _CodeEditorSurface(
                  file: file,
                  draft: draft ?? file.content ?? '',
                  onChanged: onChanged,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CodeEditorSurface extends StatefulWidget {
  const _CodeEditorSurface({
    required this.file,
    required this.draft,
    required this.onChanged,
  });

  final ProjectFileDocument file;
  final String draft;
  final ValueChanged<String> onChanged;

  @override
  State<_CodeEditorSurface> createState() => _CodeEditorSurfaceState();
}

class _CodeEditorSurfaceState extends State<_CodeEditorSurface> {
  late CodeController _controller;
  bool _mutatingFromWidget = false;

  @override
  void initState() {
    super.initState();
    _controller = _buildController();
    _controller.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(covariant _CodeEditorSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    final fileChanged = oldWidget.file.path != widget.file.path ||
        oldWidget.file.writable != widget.file.writable ||
        oldWidget.file.extension != widget.file.extension;

    if (fileChanged) {
      _controller.removeListener(_handleControllerChanged);
      _controller.dispose();
      _controller = _buildController();
      _controller.addListener(_handleControllerChanged);
      return;
    }

    if (_controller.fullText != widget.draft) {
      _mutatingFromWidget = true;
      _controller.fullText = widget.draft;
      _mutatingFromWidget = false;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_handleControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  CodeController _buildController() {
    return CodeController(
      text: widget.draft,
      language: _languageForDocument(widget.file),
      readOnly: !widget.file.writable,
    );
  }

  void _handleControllerChanged() {
    if (_mutatingFromWidget) {
      return;
    }

    widget.onChanged(_controller.fullText);
  }

  @override
  Widget build(BuildContext context) {
    return CodeTheme(
      data: CodeThemeData(styles: atomOneDarkTheme),
      child: Container(
        color: const Color(0xFF141A28),
        padding: const EdgeInsets.all(12),
        child: CodeField(
          controller: _controller,
          expands: true,
          maxLines: null,
          wrap: false,
          textStyle: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 13.5,
            height: 1.45,
          ),
          gutterStyle: const GutterStyle(
            width: 54,
            showErrors: false,
            showFoldingHandles: false,
          ),
          decoration: BoxDecoration(
            color: const Color(0xFF141A28),
            borderRadius: BorderRadius.circular(14),
          ),
          background: const Color(0xFF141A28),
        ),
      ),
    );
  }
}

class _FilePanePlaceholder extends StatelessWidget {
  const _FilePanePlaceholder({
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final Future<void> Function()? onAction;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  icon,
                  size: 40,
                  color: AppPalette.textMuted,
                ),
                const SizedBox(height: 14),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppPalette.textMuted,
                        height: 1.45,
                      ),
                ),
                if (actionLabel != null && onAction != null) ...<Widget>[
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () {
                      onAction!();
                    },
                    icon: const Icon(Icons.download_rounded),
                    label: Text(actionLabel!),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
