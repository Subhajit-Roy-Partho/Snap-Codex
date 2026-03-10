import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/chat/chat_screen.dart';
import '../features/files/file_explorer_screen.dart';
import '../features/projects/projects_drawer.dart';
import '../models/app_models.dart';
import '../theme/app_theme.dart';
import '../widgets/dna_c_logo.dart';
import 'app_controller.dart';
import 'app_state.dart';

class CodexMobileApp extends ConsumerStatefulWidget {
  const CodexMobileApp({super.key});

  @override
  ConsumerState<CodexMobileApp> createState() => _CodexMobileAppState();
}

class _CodexMobileAppState extends ConsumerState<CodexMobileApp> {
  List<String> _reasoningOptionsForState(AppState state) {
    final selectedModel = state.models
        .where((model) => model.id == state.selectedModelId)
        .toList();
    if (selectedModel.isEmpty) {
      return const <String>['low', 'medium', 'high', 'xhigh'];
    }

    final options = selectedModel.first.supportedReasoningEfforts
        .where(
          (entry) =>
              entry == 'low' ||
              entry == 'medium' ||
              entry == 'high' ||
              entry == 'xhigh',
        )
        .toList();
    if (options.isEmpty) {
      return const <String>['low', 'medium', 'high', 'xhigh'];
    }
    return options;
  }

  Future<void> _showServerUrlDialog(
    BuildContext context,
    AppController controller,
    String currentUrl,
  ) async {
    final textController = TextEditingController(text: currentUrl);
    final nextUrl = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Backend Server URL'),
          content: TextField(
            controller: textController,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'http://192.168.1.10:8787',
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(textController.text.trim()),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (!mounted || nextUrl == null || nextUrl.isEmpty) {
      return;
    }

    await controller.updateServerUrl(nextUrl);
  }

  Future<void> _showAddFolderDialog(
    BuildContext context,
    AppController controller,
    List<String> projectRoots,
  ) async {
    final folderPath = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return _AddFolderDialog(
          initialPath: projectRoots.isNotEmpty ? projectRoots.first : '.',
          onBrowse: controller.browseDirectories,
          onSuggest: controller.suggestDirectories,
        );
      },
    );

    if (!mounted || folderPath == null || folderPath.isEmpty) {
      return;
    }

    await controller.addProjectRoot(folderPath);
  }

  Future<void> _showErrorDetailsDialog(
    BuildContext context,
    AppController controller,
    String errorText,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Row(
            children: <Widget>[
              Icon(Icons.error_outline_rounded, color: AppPalette.coral),
              SizedBox(width: 8),
              Text('Error Details'),
            ],
          ),
          content: SizedBox(
            width: 700,
            child: SingleChildScrollView(
              child: SelectableText(
                errorText,
                style: const TextStyle(
                  color: AppPalette.textPrimary,
                  fontFamily: 'monospace',
                  height: 1.35,
                ),
              ),
            ),
          ),
          actions: <Widget>[
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: errorText));
                messenger.showSnackBar(
                  const SnackBar(content: Text('Error copied to clipboard')),
                );
              },
              icon: const Icon(Icons.copy_all_rounded),
              label: const Text('Copy'),
            ),
            TextButton(
              onPressed: () {
                controller.clearError();
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Clear'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showCurrentErrorDialog(
    BuildContext context,
    AppController controller,
  ) async {
    final errorText = ref.read(appControllerProvider).error;
    if (errorText == null || errorText.trim().isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No error details available')),
      );
      return;
    }

    await _showErrorDetailsDialog(context, controller, errorText);
  }

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() {
      ref.read(appControllerProvider.notifier).initialize();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final controller = ref.read(appControllerProvider.notifier);
    final reasoningOptions = _reasoningOptionsForState(state);
    final onSelectProject = state.activeWorkspaceViewId == 'files'
        ? controller.selectProjectForFiles
        : controller.selectProjectAndSwitch;
    final onSelectProjectRoot = state.activeWorkspaceViewId == 'files'
        ? controller.selectProjectRootForFiles
        : controller.selectProjectRootAndSwitch;
    String? activeProjectId;
    String? activeProjectPath;
    if (state.activeWorkspaceViewId == 'files') {
      activeProjectId = state.selectedProjectId;
    } else {
      for (final session in state.sessions) {
        if (session.id == state.activeSessionId) {
          activeProjectId = session.projectId;
          break;
        }
      }
    }
    ProjectItem? selectedProject;
    for (final project in state.projects) {
      if (project.id == activeProjectId) {
        activeProjectPath = project.path;
      }
      if (project.id == state.selectedProjectId) {
        selectedProject = project;
      }
    }
    ref.listen(appControllerProvider, (previous, next) {
      final error = next.error;
      if (error == null || error == previous?.error || !mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
    });

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Codex Mobile',
      theme: AppTheme.dark,
      home: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final showSidePanel = constraints.maxWidth >= 980;

          return Scaffold(
            appBar: AppBar(
              title: const Row(
                children: <Widget>[
                  DnaCLogo(size: 30),
                  SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      'Codex Control Room',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              actions: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: SegmentedButton<String>(
                    segments: const <ButtonSegment<String>>[
                      ButtonSegment<String>(
                        value: 'chat',
                        icon: Icon(Icons.chat_bubble_outline_rounded),
                        label: Text('Chat'),
                      ),
                      ButtonSegment<String>(
                        value: 'files',
                        icon: Icon(Icons.folder_copy_outlined),
                        label: Text('Files'),
                      ),
                    ],
                    selected: <String>{state.activeWorkspaceViewId},
                    showSelectedIcon: false,
                    onSelectionChanged: (Set<String> selection) {
                      final nextView =
                          selection.isEmpty ? 'chat' : selection.first;
                      controller.setWorkspaceView(nextView);
                    },
                  ),
                ),
                Tooltip(
                  message: 'Server: ${state.serverUrl}',
                  child: IconButton(
                    onPressed: () => _showServerUrlDialog(
                      context,
                      controller,
                      state.serverUrl,
                    ),
                    icon: const Icon(Icons.settings_ethernet_rounded),
                  ),
                ),
                if (state.error != null)
                  Tooltip(
                    message: state.error,
                    child: IconButton(
                      tooltip: 'Show full error',
                      onPressed: () =>
                          _showCurrentErrorDialog(context, controller),
                      icon: const Icon(
                        Icons.error_outline_rounded,
                        color: AppPalette.coral,
                      ),
                    ),
                  ),
                Tooltip(
                  message: state.runtimeStatusMessage ??
                      'Runtime status unavailable',
                  child: Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Icon(
                      state.runtimeReady
                          ? Icons.cloud_done_outlined
                          : Icons.cloud_off_outlined,
                    ),
                  ),
                ),
              ],
            ),
            drawer: showSidePanel
                ? null
                : ProjectsDrawer(
                    projectRoots: state.projectRoots,
                    projects: state.projects,
                    selectedProjectId: state.selectedProjectId,
                    activeProjectId: activeProjectId,
                    activeProjectPath: activeProjectPath,
                    onSelectProject: onSelectProject,
                    onSelectProjectRoot: onSelectProjectRoot,
                    onAddFolder: () => _showAddFolderDialog(
                        context, controller, state.projectRoots),
                  ),
            endDrawer: ChatSettingsDrawer(
              models: state.models,
              profiles: state.profiles,
              collaborationModes: state.collaborationModes,
              sessions: state.sessions,
              terminalSessions: state.terminalSessions,
              activeSessionId: state.activeSessionId,
              activeTerminalId: state.activeTerminalId,
              selectedModelId: state.selectedModelId,
              selectedReasoningEffortId: state.selectedReasoningEffortId,
              selectedProfileId: state.selectedProfileId,
              selectedCollaborationModeId: state.selectedCollaborationModeId,
              showDetailedToolbarLabels: state.showDetailedToolbarLabels,
              reasoningOptions: reasoningOptions,
              onModelSelected: controller.selectModel,
              onReasoningEffortSelected: controller.selectReasoningEffort,
              onProfileSelected: controller.selectProfile,
              onCollaborationModeSelected: controller.selectCollaborationMode,
              onSessionSelected: controller.setActiveSession,
              onTerminalSelected: controller.setActiveTerminal,
              onShowDetailedToolbarLabelsChanged:
                  controller.setShowDetailedToolbarLabels,
            ),
            body: Stack(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    if (showSidePanel)
                      SizedBox(
                        width: 320,
                        child: ProjectsDrawer(
                          embedded: true,
                          projectRoots: state.projectRoots,
                          projects: state.projects,
                          selectedProjectId: state.selectedProjectId,
                          activeProjectId: activeProjectId,
                          activeProjectPath: activeProjectPath,
                          onSelectProject: onSelectProject,
                          onSelectProjectRoot: onSelectProjectRoot,
                          onAddFolder: () => _showAddFolderDialog(
                              context, controller, state.projectRoots),
                        ),
                      ),
                    Expanded(
                      child: state.activeWorkspaceViewId == 'files'
                          ? FileExplorerScreen(
                              project: selectedProject,
                              listing: state.projectFileListing,
                              openFile: state.openProjectFile,
                              openFileDraft: state.openProjectFileDraft,
                              hasUnsavedChanges:
                                  state.hasUnsavedOpenProjectFileChanges,
                              onBrowseDirectory: (String path) =>
                                  controller.browseProjectFiles(path: path),
                              onOpenFile: controller.openProjectFile,
                              onDraftChanged:
                                  controller.updateOpenProjectFileDraft,
                              onRefresh: () => controller.browseProjectFiles(
                                path:
                                    state.projectFileListing?.currentPath ?? '',
                              ),
                              onSaveFile: controller.saveOpenProjectFile,
                              onUploadFiles: controller.uploadProjectFiles,
                              onDownloadFile: controller.downloadProjectFile,
                            )
                          : ChatScreen(
                              messages: state.activeMessages,
                              activeDiff: state.activeDiff,
                              models: state.models,
                              profiles: state.profiles,
                              collaborationModes: state.collaborationModes,
                              sessions: state.sessions,
                              terminalSessions: state.terminalSessions,
                              activeSessionId: state.activeSessionId,
                              activeTerminalId: state.activeTerminalId,
                              activeTerminalOutput: state.activeTerminalOutput,
                              selectedModelId: state.selectedModelId,
                              selectedReasoningEffortId:
                                  state.selectedReasoningEffortId,
                              selectedProfileId: state.selectedProfileId,
                              selectedCollaborationModeId:
                                  state.selectedCollaborationModeId,
                              pendingPermissionRequestId:
                                  state.pendingPermissionRequestId,
                              pendingUserInputRequestId:
                                  state.pendingUserInputRequestId,
                              pendingUserInputQuestions:
                                  state.pendingUserInputQuestions,
                              showDetailedToolbarLabels:
                                  state.showDetailedToolbarLabels,
                              onModelSelected: controller.selectModel,
                              onReasoningEffortSelected:
                                  controller.selectReasoningEffort,
                              onProfileSelected: controller.selectProfile,
                              onCollaborationModeSelected:
                                  controller.selectCollaborationMode,
                              onSessionSelected: controller.setActiveSession,
                              onTerminalSelected: controller.setActiveTerminal,
                              onLoadHistory: controller.loadHistory,
                              onResumeHistory: controller.resumeHistoryThread,
                              onStartSession: () {
                                controller.startNewSession();
                              },
                              onEnsureTerminal:
                                  controller.ensureTerminalSession,
                              onStartTerminal: controller.createTerminalSession,
                              onCloseTerminal: controller.closeActiveTerminal,
                              onRefreshChat: controller.refreshActiveChat,
                              onSend: controller.sendMessage,
                              onSendTerminalInput: controller.sendTerminalInput,
                              onResizeTerminal: controller.resizeTerminal,
                              onInterrupt: () {
                                controller.interrupt();
                              },
                              onApprovePermission: () =>
                                  controller.respondPermission(true),
                              onDenyPermission: () =>
                                  controller.respondPermission(false),
                              onRespondUserInput: controller.respondUserInput,
                            ),
                    ),
                  ],
                ),
                if (state.loading)
                  const ColoredBox(
                    color: Color(0x4D0B1020),
                    child: Center(child: CircularProgressIndicator()),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _AddFolderDialog extends StatefulWidget {
  const _AddFolderDialog({
    required this.initialPath,
    required this.onBrowse,
    required this.onSuggest,
  });

  final String initialPath;
  final Future<DirectoryBrowseResult> Function(
    String path, {
    int limit,
  }) onBrowse;
  final Future<List<String>> Function(
    String query, {
    String? basePath,
    int limit,
  }) onSuggest;

  @override
  State<_AddFolderDialog> createState() => _AddFolderDialogState();
}

class _AddFolderDialogState extends State<_AddFolderDialog> {
  late final TextEditingController _pathController;

  List<DirectoryEntryItem> _entries = const <DirectoryEntryItem>[];
  List<String> _suggestions = const <String>[];
  String _currentPath = '.';
  String? _parentPath;
  String? _error;
  bool _loading = false;
  bool _loadingSuggestions = false;

  @override
  void initState() {
    super.initState();
    _pathController = TextEditingController(text: widget.initialPath);
    _loadPath(widget.initialPath, updateField: true);
  }

  Future<void> _loadPath(String inputPath, {bool updateField = false}) async {
    final trimmed = inputPath.trim();
    if (trimmed.isEmpty) {
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = await widget.onBrowse(trimmed, limit: 200);
      if (!mounted) {
        return;
      }

      setState(() {
        _currentPath = result.resolvedPath;
        _parentPath = result.parentPath;
        _entries = result.entries;
        _error = null;
      });

      if (updateField) {
        _pathController.value = TextEditingValue(
          text: result.resolvedPath,
          selection:
              TextSelection.collapsed(offset: result.resolvedPath.length),
        );
      }

      await _loadSuggestions();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadSuggestions() async {
    final query = _pathController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _suggestions = const <String>[];
      });
      return;
    }

    setState(() {
      _loadingSuggestions = true;
    });

    try {
      final suggestions = await widget.onSuggest(
        query,
        basePath: _currentPath,
        limit: 8,
      );
      if (!mounted) {
        return;
      }

      setState(() {
        _suggestions = suggestions;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _suggestions = const <String>[];
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingSuggestions = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Folder Location'),
      content: SizedBox(
        width: 760,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: _pathController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Folder path on backend host',
                hintText: '/home/user/projects or ../projects',
              ),
              onChanged: (_) => _loadSuggestions(),
              onSubmitted: (String value) =>
                  _loadPath(value, updateField: true),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: _parentPath == null || _loading
                      ? null
                      : () => _loadPath(_parentPath!, updateField: true),
                  icon: const Icon(Icons.arrow_upward),
                  label: const Text('Up'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _loading
                      ? null
                      : () => _loadPath(
                            _pathController.text,
                            updateField: true,
                          ),
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Browse'),
                ),
                const Spacer(),
                if (_loadingSuggestions)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (_suggestions.isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              SizedBox(
                height: 110,
                child: Card(
                  margin: EdgeInsets.zero,
                  child: ListView.builder(
                    itemCount: _suggestions.length,
                    itemBuilder: (BuildContext context, int index) {
                      final suggestion = _suggestions[index];
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.auto_awesome_outlined),
                        title: Text(
                          suggestion,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _loadPath(suggestion, updateField: true),
                      );
                    },
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            SelectableText(
              'Current: $_currentPath',
              style: const TextStyle(
                color: AppPalette.textMuted,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 8),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error!,
                  style: const TextStyle(color: AppPalette.coral),
                ),
              ),
            Expanded(
              child: Card(
                margin: EdgeInsets.zero,
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _entries.isEmpty
                        ? const Center(
                            child: Text(
                              'No subfolders found.',
                              style: TextStyle(color: AppPalette.textMuted),
                            ),
                          )
                        : ListView.separated(
                            itemCount: _entries.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (BuildContext context, int index) {
                              final entry = _entries[index];
                              return ListTile(
                                dense: true,
                                leading: Icon(
                                  entry.readable
                                      ? Icons.folder_outlined
                                      : Icons.folder_off_outlined,
                                ),
                                title: Text(entry.name),
                                subtitle: Text(
                                  entry.path,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: entry.readable
                                    ? () =>
                                        _loadPath(entry.path, updateField: true)
                                    : null,
                              );
                            },
                          ),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(_pathController.text.trim()),
          child: const Text('Add'),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }
}
