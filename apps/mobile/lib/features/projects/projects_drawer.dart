import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../theme/app_theme.dart';

class ProjectsDrawer extends StatelessWidget {
  const ProjectsDrawer({
    super.key,
    required this.projectRoots,
    required this.projects,
    required this.selectedProjectId,
    required this.activeProjectId,
    required this.activeProjectPath,
    required this.onSelectProject,
    required this.onSelectProjectRoot,
    required this.onAddFolder,
    this.embedded = false,
  });

  final List<String> projectRoots;
  final List<ProjectItem> projects;
  final String? selectedProjectId;
  final String? activeProjectId;
  final String? activeProjectPath;
  final Future<void> Function(String projectId) onSelectProject;
  final Future<void> Function(String rootPath) onSelectProjectRoot;
  final Future<void> Function() onAddFolder;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final body = Container(
      decoration: AppDecorations.background,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Row(
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      'Projects',
                      style: TextStyle(
                        color: AppPalette.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Add folder',
                    onPressed: () {
                      onAddFolder();
                    },
                    icon: const Icon(Icons.create_new_folder_outlined),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 10),
                children: <Widget>[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 6, 20, 6),
                    child: Text(
                      'Project Locations',
                      style: TextStyle(
                        color: AppPalette.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  if (projectRoots.isEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 2, 20, 10),
                      child: Text(
                        'No project locations yet. Add a folder.',
                        style: TextStyle(color: AppPalette.textMuted),
                      ),
                    ),
                  for (final root in projectRoots)
                    ListTile(
                      dense: true,
                      leading: SizedBox(
                        width: 32,
                        child: Row(
                          children: <Widget>[
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: _isActiveRoot(root, activeProjectPath)
                                    ? AppPalette.mint
                                    : AppPalette.textMuted
                                        .withValues(alpha: 0.25),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Icon(
                              Icons.location_on_outlined,
                              color: AppPalette.textMuted,
                              size: 16,
                            ),
                          ],
                        ),
                      ),
                      title: Text(
                        root,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppPalette.textMuted,
                          fontSize: 12,
                        ),
                      ),
                      onTap: () async {
                        await onSelectProjectRoot(root);
                        if (!embedded) {
                          if (!context.mounted) {
                            return;
                          }
                          Navigator.of(context).pop();
                        }
                      },
                    ),
                  const Divider(height: 20),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 0, 20, 6),
                    child: Text(
                      'Detected Projects',
                      style: TextStyle(
                        color: AppPalette.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  if (projects.isEmpty)
                    const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      child: Text(
                        'No projects found yet. Add a folder location to scan.',
                        style: TextStyle(color: AppPalette.textMuted),
                      ),
                    ),
                  for (final project in projects)
                    _ProjectRow(
                      project: project,
                      selected: project.id == selectedProjectId,
                      active: project.id == activeProjectId,
                      onTap: () async {
                        await onSelectProject(project.id);
                        if (!embedded) {
                          if (!context.mounted) {
                            return;
                          }
                          Navigator.of(context).pop();
                        }
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    if (embedded) {
      return body;
    }

    return Drawer(child: body);
  }

  bool _isActiveRoot(String rootPath, String? activeProjectPath) {
    if (activeProjectPath == null || activeProjectPath.isEmpty) {
      return false;
    }

    final normalizedRoot = _normalizePath(rootPath);
    final normalizedProjectPath = _normalizePath(activeProjectPath);
    return normalizedProjectPath == normalizedRoot ||
        normalizedProjectPath.startsWith('$normalizedRoot/');
  }

  String _normalizePath(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == '/') {
      return trimmed;
    }

    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }
}

class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    required this.project,
    required this.selected,
    required this.active,
    required this.onTap,
  });

  final ProjectItem project;
  final bool selected;
  final bool active;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      selected: selected,
      selectedTileColor: AppPalette.sky.withValues(alpha: 0.12),
      leading: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: active
              ? AppPalette.mint
              : AppPalette.textMuted.withValues(alpha: 0.25),
          shape: BoxShape.circle,
        ),
      ),
      title: Text(
        project.name,
        style: const TextStyle(color: AppPalette.textPrimary),
      ),
      subtitle: Text(
        project.gitBranch == null
            ? project.path
            : '${project.gitBranch}${project.gitDirty ? ' • dirty' : ''} • ${project.path}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppPalette.textMuted),
      ),
      onTap: () {
        onTap();
      },
    );
  }
}
