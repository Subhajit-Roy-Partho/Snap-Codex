import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:xterm/xterm.dart';

import '../../models/app_models.dart';
import '../../theme/app_theme.dart';

enum _ConversationViewMode { chat, terminal }

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.messages,
    required this.activeDiff,
    required this.models,
    required this.profiles,
    required this.collaborationModes,
    required this.sessions,
    required this.terminalSessions,
    required this.activeSessionId,
    required this.activeTerminalId,
    required this.activeTerminalOutput,
    required this.selectedModelId,
    required this.selectedReasoningEffortId,
    required this.selectedProfileId,
    required this.selectedCollaborationModeId,
    required this.pendingPermissionRequestId,
    required this.pendingUserInputRequestId,
    required this.pendingUserInputQuestions,
    required this.onModelSelected,
    required this.onReasoningEffortSelected,
    required this.onProfileSelected,
    required this.onCollaborationModeSelected,
    required this.onSessionSelected,
    required this.onTerminalSelected,
    required this.onLoadHistory,
    required this.onResumeHistory,
    required this.onStartSession,
    required this.onEnsureTerminal,
    required this.onCloseTerminal,
    required this.onRefreshChat,
    required this.onSend,
    required this.onSendTerminalInput,
    required this.onResizeTerminal,
    required this.onInterrupt,
    required this.onApprovePermission,
    required this.onDenyPermission,
    required this.onRespondUserInput,
  });

  final List<ChatMessage> messages;
  final SessionDiffState? activeDiff;
  final List<ModelOption> models;
  final List<PermissionProfileOption> profiles;
  final List<CollaborationModeOption> collaborationModes;
  final List<ChatSession> sessions;
  final List<TerminalSessionItem> terminalSessions;
  final String? activeSessionId;
  final String? activeTerminalId;
  final String activeTerminalOutput;
  final String? selectedModelId;
  final String? selectedReasoningEffortId;
  final String? selectedProfileId;
  final String? selectedCollaborationModeId;
  final String? pendingPermissionRequestId;
  final String? pendingUserInputRequestId;
  final List<UserInputQuestion> pendingUserInputQuestions;

  final ValueChanged<String> onModelSelected;
  final ValueChanged<String> onReasoningEffortSelected;
  final ValueChanged<String> onProfileSelected;
  final ValueChanged<String> onCollaborationModeSelected;
  final ValueChanged<String> onSessionSelected;
  final ValueChanged<String> onTerminalSelected;
  final Future<HistoryPage> Function({
    String? cursor,
    bool includeAllWorkspaces,
  }) onLoadHistory;
  final Future<bool> Function(HistoryThread thread) onResumeHistory;
  final VoidCallback onStartSession;
  final Future<void> Function() onEnsureTerminal;
  final Future<void> Function() onCloseTerminal;
  final Future<void> Function() onRefreshChat;
  final Future<void> Function(String text, {bool requestPermission}) onSend;
  final Future<void> Function(String input, {bool raw}) onSendTerminalInput;
  final Future<void> Function({required int cols, required int rows})
      onResizeTerminal;
  final VoidCallback onInterrupt;
  final VoidCallback onApprovePermission;
  final VoidCallback onDenyPermission;
  final Future<void> Function(Map<String, String>) onRespondUserInput;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late Terminal _terminal;
  _ConversationViewMode _viewMode = _ConversationViewMode.chat;
  bool _refreshingChat = false;
  String? _renderedTerminalId;
  int _renderedTerminalOutputLength = 0;

  @override
  void initState() {
    super.initState();
    _terminal = _buildTerminal();
    _syncTerminalOutput(forceFullReplay: true);
  }

  Terminal _buildTerminal() {
    return Terminal(
      maxLines: 20000,
      onOutput: (String data) {
        widget.onSendTerminalInput(data, raw: true);
      },
    )..onResize = (int width, int height, int _, int __) {
        widget.onResizeTerminal(cols: width, rows: height);
      };
  }

  void _syncTerminalOutput({bool forceFullReplay = false}) {
    final terminalId = widget.activeTerminalId;
    final output = widget.activeTerminalOutput;

    if (terminalId == null) {
      _renderedTerminalId = null;
      _renderedTerminalOutputLength = 0;
      return;
    }

    final terminalChanged = _renderedTerminalId != terminalId;
    final outputReset = output.length < _renderedTerminalOutputLength;

    if (terminalChanged || outputReset || forceFullReplay) {
      _terminal = _buildTerminal();
      _renderedTerminalId = terminalId;
      _renderedTerminalOutputLength = 0;
    }

    if (output.isEmpty) {
      _renderedTerminalOutputLength = 0;
      return;
    }

    if (output.length < _renderedTerminalOutputLength) {
      _renderedTerminalOutputLength = 0;
    }

    if (output.length == _renderedTerminalOutputLength) {
      return;
    }

    final nextChunk = output.substring(_renderedTerminalOutputLength);
    _terminal.write(nextChunk);
    _renderedTerminalOutputLength = output.length;
    _renderedTerminalId = terminalId;
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previousDiffStamp = oldWidget.activeDiff?.updatedAt;
    final nextDiffStamp = widget.activeDiff?.updatedAt;
    if (oldWidget.activeTerminalId != widget.activeTerminalId ||
        oldWidget.activeTerminalOutput != widget.activeTerminalOutput) {
      _syncTerminalOutput();
    }
    if (oldWidget.messages.length != widget.messages.length ||
        previousDiffStamp != nextDiffStamp) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) {
          return;
        }

        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      });
    }
  }

  Future<void> _openHistoryDialog() async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return _HistoryDialog(
          onLoadHistory: widget.onLoadHistory,
          onResumeHistory: widget.onResumeHistory,
        );
      },
    );
  }

  Future<void> _openUserInputDialog() async {
    if (widget.pendingUserInputQuestions.isEmpty) {
      return;
    }

    final selectedAnswers = <String, String>{
      for (final question in widget.pendingUserInputQuestions)
        question.id:
            question.options.isNotEmpty ? question.options.first.label : '',
    };

    final submit = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            return AlertDialog(
              title: const Text('Answer Required'),
              content: SizedBox(
                width: 560,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: widget.pendingUserInputQuestions.map((question) {
                      final value = selectedAnswers[question.id];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              question.header,
                              style: const TextStyle(
                                color: AppPalette.textMuted,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(question.question),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              initialValue:
                                  value == null || value.isEmpty ? null : value,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: 'Select an option',
                              ),
                              items: question.options
                                  .map(
                                    (option) => DropdownMenuItem<String>(
                                      value: option.label,
                                      child: Text(option.label),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (String? next) {
                                if (next == null) {
                                  return;
                                }
                                setState(() {
                                  selectedAnswers[question.id] = next;
                                });
                              },
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Later'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Submit'),
                ),
              ],
            );
          },
        );
      },
    );

    if (submit != true) {
      return;
    }

    final filtered = <String, String>{
      for (final entry in selectedAnswers.entries)
        if (entry.value.trim().isNotEmpty) entry.key: entry.value.trim(),
    };
    if (filtered.isEmpty) {
      return;
    }

    await widget.onRespondUserInput(filtered);
  }

  Future<void> _refreshChat() async {
    if (_refreshingChat) {
      return;
    }

    setState(() {
      _refreshingChat = true;
    });
    try {
      await widget.onRefreshChat();
    } finally {
      if (mounted) {
        setState(() {
          _refreshingChat = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AppDecorations.background,
      child: SafeArea(
        child: Column(
          children: <Widget>[
            _TopToolbar(
              viewMode: _viewMode,
              activeTerminalId: widget.activeTerminalId,
              refreshingChat: _refreshingChat,
              onViewModeChanged: (_ConversationViewMode nextMode) {
                setState(() {
                  _viewMode = nextMode;
                });
                if (nextMode == _ConversationViewMode.terminal) {
                  widget.onEnsureTerminal();
                }
              },
              onOpenHistory: _openHistoryDialog,
              onStartSession: widget.onStartSession,
              onRefreshChat: _refreshChat,
              onOpenSettings: () {
                Scaffold.maybeOf(context)?.openEndDrawer();
              },
              onStartTerminal: () {
                widget.onEnsureTerminal();
              },
              onCloseTerminal: () {
                widget.onCloseTerminal();
              },
              onInterrupt: widget.onInterrupt,
            ),
            if (widget.pendingPermissionRequestId != null)
              _PermissionBanner(
                onApprove: widget.onApprovePermission,
                onDeny: widget.onDenyPermission,
              ),
            if (widget.pendingUserInputRequestId != null)
              _UserInputBanner(
                questionCount: widget.pendingUserInputQuestions.length,
                onRespond: _openUserInputDialog,
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: _viewMode == _ConversationViewMode.terminal
                    ? _TerminalSurface(
                        terminal: _terminal,
                        hasTerminalSession: widget.activeTerminalId != null,
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        itemCount: widget.messages.length +
                            (widget.activeDiff == null ? 0 : 1),
                        itemBuilder: (BuildContext context, int index) {
                          if (widget.activeDiff != null && index == 0) {
                            return _DiffPanel(diff: widget.activeDiff!);
                          }

                          final offset =
                              widget.activeDiff == null ? index : index - 1;
                          final message = widget.messages[offset];
                          return _MessageBubble(message: message);
                        },
                      ),
              ),
            ),
            _Composer(
              controller: _controller,
              isTerminalMode: _viewMode == _ConversationViewMode.terminal,
              showPermissionButton: _viewMode != _ConversationViewMode.terminal,
              onSend: () async {
                final text = _controller.text.trim();
                if (text.isEmpty) {
                  return;
                }

                _controller.clear();
                if (_viewMode == _ConversationViewMode.terminal) {
                  await widget.onSendTerminalInput(text, raw: false);
                } else {
                  await widget.onSend(text);
                }
              },
              onSendWithPermission: () async {
                if (_viewMode == _ConversationViewMode.terminal) {
                  return;
                }
                final text = _controller.text.trim();
                if (text.isEmpty) {
                  return;
                }

                _controller.clear();
                await widget.onSend(text, requestPermission: true);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

class ChatSettingsDrawer extends StatelessWidget {
  const ChatSettingsDrawer({
    super.key,
    required this.models,
    required this.profiles,
    required this.collaborationModes,
    required this.sessions,
    required this.terminalSessions,
    required this.activeSessionId,
    required this.activeTerminalId,
    required this.selectedModelId,
    required this.selectedReasoningEffortId,
    required this.selectedProfileId,
    required this.selectedCollaborationModeId,
    required this.reasoningOptions,
    required this.onModelSelected,
    required this.onReasoningEffortSelected,
    required this.onProfileSelected,
    required this.onCollaborationModeSelected,
    required this.onSessionSelected,
    required this.onTerminalSelected,
  });

  final List<ModelOption> models;
  final List<PermissionProfileOption> profiles;
  final List<CollaborationModeOption> collaborationModes;
  final List<ChatSession> sessions;
  final List<TerminalSessionItem> terminalSessions;
  final String? activeSessionId;
  final String? activeTerminalId;
  final String? selectedModelId;
  final String? selectedReasoningEffortId;
  final String? selectedProfileId;
  final String? selectedCollaborationModeId;
  final List<String> reasoningOptions;
  final ValueChanged<String> onModelSelected;
  final ValueChanged<String> onReasoningEffortSelected;
  final ValueChanged<String> onProfileSelected;
  final ValueChanged<String> onCollaborationModeSelected;
  final ValueChanged<String> onSessionSelected;
  final ValueChanged<String> onTerminalSelected;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: Container(
        decoration: AppDecorations.background,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 18),
            children: <Widget>[
              Row(
                children: const <Widget>[
                  Icon(Icons.tune_rounded, color: AppPalette.sky),
                  SizedBox(width: 8),
                  Text(
                    'Chat Settings',
                    style: TextStyle(
                      color: AppPalette.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _SettingsDropdown<String>(
                label: 'Model',
                value: selectedModelId,
                items: models
                    .map(
                      (model) => DropdownMenuItem<String>(
                        value: model.id,
                        child: Text(model.displayName),
                      ),
                    )
                    .toList(),
                onChanged: (String? value) {
                  if (value != null) {
                    onModelSelected(value);
                  }
                },
              ),
              _SettingsDropdown<String>(
                label: 'Reasoning',
                value: selectedReasoningEffortId != null &&
                        reasoningOptions.contains(selectedReasoningEffortId)
                    ? selectedReasoningEffortId
                    : null,
                items: reasoningOptions
                    .map(
                      (effort) => DropdownMenuItem<String>(
                        value: effort,
                        child: Text(effort.toUpperCase()),
                      ),
                    )
                    .toList(),
                onChanged: (String? value) {
                  if (value != null) {
                    onReasoningEffortSelected(value);
                  }
                },
              ),
              _SettingsDropdown<String>(
                label: 'Permission',
                value: selectedProfileId,
                items: profiles
                    .map(
                      (profile) => DropdownMenuItem<String>(
                        value: profile.id,
                        child: Text(
                            profile.id == 'xhigh' || profile.id == 'yolo'
                                ? '${profile.name} (${profile.id})'
                                : profile.name),
                      ),
                    )
                    .toList(),
                onChanged: (String? value) {
                  if (value != null) {
                    onProfileSelected(value);
                  }
                },
              ),
              _SettingsDropdown<String>(
                label: 'Collaboration',
                value: selectedCollaborationModeId,
                items: collaborationModes
                    .map(
                      (mode) => DropdownMenuItem<String>(
                        value: mode.id,
                        child: Text(mode.name),
                      ),
                    )
                    .toList(),
                onChanged: (String? value) {
                  if (value != null) {
                    onCollaborationModeSelected(value);
                  }
                },
              ),
              _SettingsDropdown<String>(
                label: 'Session',
                value: activeSessionId,
                items: sessions
                    .map(
                      (session) => DropdownMenuItem<String>(
                        value: session.id,
                        child: Text(
                            '${session.id.substring(0, 8)} • ${session.status}'),
                      ),
                    )
                    .toList(),
                onChanged: (String? value) {
                  if (value != null) {
                    onSessionSelected(value);
                  }
                },
              ),
              _SettingsDropdown<String>(
                label: 'Terminal',
                value: activeTerminalId,
                items: terminalSessions
                    .map(
                      (terminal) => DropdownMenuItem<String>(
                        value: terminal.id,
                        child: Text(
                          '${terminal.id.substring(0, 8)} • ${terminal.running ? 'running' : 'stopped'}',
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (String? value) {
                  if (value != null) {
                    onTerminalSelected(value);
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopToolbar extends StatelessWidget {
  const _TopToolbar({
    required this.viewMode,
    required this.activeTerminalId,
    required this.refreshingChat,
    required this.onViewModeChanged,
    required this.onOpenHistory,
    required this.onStartSession,
    required this.onRefreshChat,
    required this.onOpenSettings,
    required this.onStartTerminal,
    required this.onCloseTerminal,
    required this.onInterrupt,
  });

  final _ConversationViewMode viewMode;
  final String? activeTerminalId;
  final bool refreshingChat;
  final ValueChanged<_ConversationViewMode> onViewModeChanged;
  final VoidCallback onOpenHistory;
  final VoidCallback onStartSession;
  final VoidCallback onRefreshChat;
  final VoidCallback onOpenSettings;
  final VoidCallback onStartTerminal;
  final VoidCallback onCloseTerminal;
  final VoidCallback onInterrupt;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          SegmentedButton<_ConversationViewMode>(
            selected: <_ConversationViewMode>{viewMode},
            showSelectedIcon: false,
            segments: const <ButtonSegment<_ConversationViewMode>>[
              ButtonSegment<_ConversationViewMode>(
                value: _ConversationViewMode.chat,
                label: Text('Chat'),
                icon: Icon(Icons.chat_bubble_outline),
              ),
              ButtonSegment<_ConversationViewMode>(
                value: _ConversationViewMode.terminal,
                label: Text('Terminal'),
                icon: Icon(Icons.terminal_rounded),
              ),
            ],
            onSelectionChanged: (Set<_ConversationViewMode> selected) {
              if (selected.isEmpty) {
                return;
              }
              onViewModeChanged(selected.first);
            },
          ),
          if (viewMode == _ConversationViewMode.chat)
            FilledButton.tonal(
              onPressed: onStartSession,
              child: const Text('New'),
            ),
          if (viewMode == _ConversationViewMode.chat)
            OutlinedButton(
              onPressed: onOpenHistory,
              child: const Text('History'),
            ),
          if (viewMode == _ConversationViewMode.chat)
            OutlinedButton(
              onPressed: onInterrupt,
              child: const Text('Interrupt'),
            ),
          if (viewMode == _ConversationViewMode.terminal)
            FilledButton.tonal(
              onPressed: onStartTerminal,
              child: const Text('New Term'),
            ),
          if (viewMode == _ConversationViewMode.terminal)
            OutlinedButton(
              onPressed: activeTerminalId == null ? null : onCloseTerminal,
              child: const Text('Close Term'),
            ),
          OutlinedButton.icon(
            onPressed: refreshingChat ? null : onRefreshChat,
            icon: refreshingChat
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
            label: const Text('Refresh'),
          ),
          OutlinedButton.icon(
            onPressed: onOpenSettings,
            icon: const Icon(Icons.tune_rounded),
            label: const Text('Settings'),
          ),
        ],
      ),
    );
  }
}

class _SettingsDropdown<T> extends StatelessWidget {
  const _SettingsDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final T? value;
  final String label;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<T>(
        initialValue: value,
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: AppPalette.slate.withValues(alpha: 0.6),
        ),
        dropdownColor: AppPalette.slate,
        items: items,
        onChanged: onChanged,
      ),
    );
  }
}

class _TerminalSurface extends StatelessWidget {
  const _TerminalSurface({
    required this.terminal,
    required this.hasTerminalSession,
  });

  final Terminal terminal;
  final bool hasTerminalSession;

  @override
  Widget build(BuildContext context) {
    if (!hasTerminalSession) {
      return Container(
        decoration: BoxDecoration(
          color: AppPalette.slate.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: AppPalette.textMuted.withValues(alpha: 0.2),
          ),
        ),
        padding: const EdgeInsets.all(12),
        alignment: Alignment.centerLeft,
        child: const Text(
          'No active terminal. Click "New Term" to start one.',
          style: TextStyle(color: AppPalette.textMuted),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF09111F),
          border: Border.all(
            color: AppPalette.textMuted.withValues(alpha: 0.2),
          ),
        ),
        child: TerminalView(
          terminal,
          autofocus: true,
          backgroundOpacity: 1,
          padding: const EdgeInsets.all(10),
        ),
      ),
    );
  }
}

class _PermissionBanner extends StatelessWidget {
  const _PermissionBanner({required this.onApprove, required this.onDeny});

  final VoidCallback onApprove;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(14, 2, 14, 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            const Expanded(
              child: Text(
                'Permission required for next command execution.',
                style: TextStyle(color: AppPalette.textPrimary),
              ),
            ),
            TextButton(onPressed: onDeny, child: const Text('Deny')),
            FilledButton(onPressed: onApprove, child: const Text('Approve')),
          ],
        ),
      ),
    );
  }
}

class _UserInputBanner extends StatelessWidget {
  const _UserInputBanner({
    required this.questionCount,
    required this.onRespond,
  });

  final int questionCount;
  final VoidCallback onRespond;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(14, 2, 14, 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Agent needs input for $questionCount question(s).',
                style: const TextStyle(color: AppPalette.textPrimary),
              ),
            ),
            FilledButton.tonal(
              onPressed: onRespond,
              child: const Text('Answer'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiffPanel extends StatelessWidget {
  const _DiffPanel({required this.diff});

  final SessionDiffState diff;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(0, 4, 0, 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(
                  Icons.edit_document,
                  size: 16,
                  color: AppPalette.mint,
                ),
                const SizedBox(width: 6),
                Text(
                  'File Changes • ${diff.files.length} file(s)',
                  style: const TextStyle(
                    color: AppPalette.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            for (final file in diff.files) _MiniDiffCard(file: file),
          ],
        ),
      ),
    );
  }
}

class _MiniDiffCard extends StatelessWidget {
  const _MiniDiffCard({required this.file});

  final SessionDiffFile file;

  Color _lineColor(String kind) {
    if (kind == 'added') {
      return AppPalette.mint.withValues(alpha: 0.22);
    }
    if (kind == 'removed') {
      return AppPalette.coral.withValues(alpha: 0.22);
    }
    if (kind == 'meta') {
      return AppPalette.sky.withValues(alpha: 0.18);
    }
    return AppPalette.slate.withValues(alpha: 0.45);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppPalette.slate.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppPalette.textMuted.withValues(alpha: 0.2)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 10),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          title: Text(
            file.path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppPalette.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            '+${file.additions}  -${file.deletions}',
            style: const TextStyle(
              color: AppPalette.textMuted,
              fontSize: 12,
            ),
          ),
          children: file.hunks.map((hunk) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    hunk.header,
                    style: const TextStyle(
                      color: AppPalette.sky,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    width: double.infinity,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minWidth: 520),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: hunk.lines.map((line) {
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              color: _lineColor(line.kind),
                              child: Text(
                                line.text,
                                style: const TextStyle(
                                  color: AppPalette.textPrimary,
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  bool get _isUser => message.role == 'user';
  bool get _isSystem => message.role == 'system';

  @override
  Widget build(BuildContext context) {
    if (_isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: AppPalette.slate.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              message.content,
              style: const TextStyle(
                color: AppPalette.textMuted,
                fontSize: 12,
              ),
            ),
          ),
        ),
      );
    }

    return Align(
      alignment: _isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        constraints: const BoxConstraints(maxWidth: 540),
        decoration: BoxDecoration(
          color: _isUser
              ? AppPalette.sky.withValues(alpha: 0.22)
              : AppPalette.slate.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _isUser
                ? AppPalette.sky.withValues(alpha: 0.5)
                : AppPalette.textMuted.withValues(alpha: 0.2),
          ),
        ),
        child: Column(
          crossAxisAlignment:
              _isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              message.role.toUpperCase(),
              style: const TextStyle(
                color: AppPalette.textMuted,
                fontSize: 11,
                letterSpacing: 1,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            SelectableText(
              message.content,
              style: const TextStyle(
                color: AppPalette.textPrimary,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.isTerminalMode,
    required this.showPermissionButton,
    required this.onSend,
    required this.onSendWithPermission,
  });

  final TextEditingController controller;
  final bool isTerminalMode;
  final bool showPermissionButton;
  final VoidCallback onSend;
  final VoidCallback onSendWithPermission;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: isTerminalMode
                    ? 'Type a command or task for Codex CLI...'
                    : 'Ask Codex to inspect, edit, or run...',
              ),
              onSubmitted: (_) => onSend(),
            ),
          ),
          if (showPermissionButton) const SizedBox(width: 10),
          if (showPermissionButton)
            IconButton.filledTonal(
              tooltip: 'Send with permission prompt',
              onPressed: onSendWithPermission,
              icon: const Icon(Icons.verified_user_outlined),
            ),
          if (showPermissionButton) const SizedBox(width: 8),
          IconButton.filled(
            onPressed: onSend,
            icon: const Icon(Icons.send_rounded),
          ),
        ],
      ),
    );
  }
}

class _HistoryDialog extends StatefulWidget {
  const _HistoryDialog({
    required this.onLoadHistory,
    required this.onResumeHistory,
  });

  final Future<HistoryPage> Function({
    String? cursor,
    bool includeAllWorkspaces,
  }) onLoadHistory;
  final Future<bool> Function(HistoryThread thread) onResumeHistory;

  @override
  State<_HistoryDialog> createState() => _HistoryDialogState();
}

class _HistoryDialogState extends State<_HistoryDialog> {
  final List<HistoryThread> _items = <HistoryThread>[];
  String? _nextCursor;
  String? _error;
  bool _loading = false;
  bool _loadingMore = false;
  bool _includeAllWorkspaces = true;
  final DateFormat _absoluteDateFormat = DateFormat('yyyy-MM-dd HH:mm');

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({required bool reset}) async {
    if (_loading || _loadingMore) {
      return;
    }

    setState(() {
      if (reset) {
        _loading = true;
      } else {
        _loadingMore = true;
      }
    });

    try {
      final page = await widget.onLoadHistory(
        cursor: reset ? null : _nextCursor,
        includeAllWorkspaces: _includeAllWorkspaces,
      );

      setState(() {
        _error = null;
        if (reset) {
          _items
            ..clear()
            ..addAll(page.data);
        } else {
          _items.addAll(page.data);
        }
        _nextCursor = page.nextCursor;
      });
    } catch (error) {
      setState(() {
        _error = '$error';
      });
    } finally {
      setState(() {
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _resume(HistoryThread thread) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final resumed = await widget.onResumeHistory(thread);
      if (mounted && resumed) {
        Navigator.of(context).pop();
      }
      if (!resumed && mounted) {
        setState(() {
          _error = 'Unable to open this history thread.';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  String _formatRelativeEditedTime(DateTime editedAt) {
    final now = DateTime.now();
    final difference = now.difference(editedAt);

    if (difference.isNegative || difference.inSeconds < 30) {
      return 'just now';
    }

    if (difference.inMinutes < 1) {
      return '${difference.inSeconds}s ago';
    }

    if (difference.inHours < 1) {
      return '${difference.inMinutes}m ago';
    }

    if (difference.inDays < 1) {
      return '${difference.inHours}h ago';
    }

    if (difference.inDays < 30) {
      return '${difference.inDays}d ago';
    }

    final months = (difference.inDays / 30).floor();
    if (months < 12) {
      return '${months}mo ago';
    }

    final years = (difference.inDays / 365).floor();
    return '${years}y ago';
  }

  String _formatAbsoluteEditedTime(DateTime editedAt) {
    return _absoluteDateFormat.format(editedAt.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Session History'),
      content: SizedBox(
        width: 760,
        height: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SwitchListTile.adaptive(
              value: _includeAllWorkspaces,
              onChanged: (bool value) {
                setState(() {
                  _includeAllWorkspaces = value;
                });
                _load(reset: true);
              },
              title: const Text('Show all workspaces'),
            ),
            if (_error != null)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text(
                  _error!,
                  style: const TextStyle(color: AppPalette.coral),
                ),
              ),
            const SizedBox(height: 6),
            if (_loading && _items.isEmpty)
              const Expanded(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_items.isEmpty)
              const Expanded(
                child: Center(
                  child: Text(
                    'No history found for this filter.',
                    style: TextStyle(color: AppPalette.textMuted),
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.separated(
                  itemCount: _items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (BuildContext context, int index) {
                    final thread = _items[index];
                    final editedRelative =
                        _formatRelativeEditedTime(thread.updatedAt);
                    final editedAbsolute =
                        _formatAbsoluteEditedTime(thread.updatedAt);
                    return ListTile(
                      dense: false,
                      title: Text(
                        thread.preview.isEmpty
                            ? '(No preview)'
                            : thread.preview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${thread.threadId.substring(0, 8)} • ${thread.status}\n'
                        '${thread.cwd ?? '(unknown cwd)'}\n'
                        'Edited $editedRelative ($editedAbsolute)',
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: FilledButton.tonal(
                        onPressed: _loading ? null : () => _resume(thread),
                        child: const Text('Resume'),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton.icon(
          onPressed: _loading || _loadingMore ? null : () => _load(reset: true),
          icon: const Icon(Icons.refresh),
          label: const Text('Refresh'),
        ),
        if (_nextCursor != null)
          TextButton(
            onPressed: _loadingMore ? null : () => _load(reset: false),
            child: Text(_loadingMore ? 'Loading...' : 'Load More'),
          ),
        TextButton(
          onPressed: _loading ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
