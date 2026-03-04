import '../models/app_models.dart';

class AppState {
  const AppState({
    required this.loading,
    required this.error,
    required this.serverUrl,
    required this.projectRoots,
    required this.projects,
    required this.models,
    required this.profiles,
    required this.collaborationModes,
    required this.sessions,
    required this.selectedProjectId,
    required this.selectedModelId,
    required this.selectedReasoningEffortId,
    required this.selectedProfileId,
    required this.selectedCollaborationModeId,
    required this.activeSessionId,
    required this.messagesBySession,
    required this.diffBySession,
    required this.terminalSessions,
    required this.activeTerminalId,
    required this.terminalOutputById,
    required this.pendingPermissionRequestId,
    required this.pendingUserInputRequestId,
    required this.pendingUserInputQuestions,
    required this.runtimeReady,
    required this.runtimeStatusMessage,
  });

  factory AppState.initial({String serverUrl = ''}) => AppState(
        loading: false,
        error: null,
        serverUrl: serverUrl,
        projectRoots: <String>[],
        projects: <ProjectItem>[],
        models: <ModelOption>[],
        profiles: <PermissionProfileOption>[],
        collaborationModes: <CollaborationModeOption>[],
        sessions: <ChatSession>[],
        selectedProjectId: null,
        selectedModelId: null,
        selectedReasoningEffortId: null,
        selectedProfileId: null,
        selectedCollaborationModeId: null,
        activeSessionId: null,
        messagesBySession: <String, List<ChatMessage>>{},
        diffBySession: <String, SessionDiffState>{},
        terminalSessions: <TerminalSessionItem>[],
        activeTerminalId: null,
        terminalOutputById: <String, String>{},
        pendingPermissionRequestId: null,
        pendingUserInputRequestId: null,
        pendingUserInputQuestions: <UserInputQuestion>[],
        runtimeReady: false,
        runtimeStatusMessage: null,
      );

  final bool loading;
  final String? error;
  final String serverUrl;
  final List<String> projectRoots;
  final List<ProjectItem> projects;
  final List<ModelOption> models;
  final List<PermissionProfileOption> profiles;
  final List<CollaborationModeOption> collaborationModes;
  final List<ChatSession> sessions;
  final String? selectedProjectId;
  final String? selectedModelId;
  final String? selectedReasoningEffortId;
  final String? selectedProfileId;
  final String? selectedCollaborationModeId;
  final String? activeSessionId;
  final Map<String, List<ChatMessage>> messagesBySession;
  final Map<String, SessionDiffState> diffBySession;
  final List<TerminalSessionItem> terminalSessions;
  final String? activeTerminalId;
  final Map<String, String> terminalOutputById;
  final String? pendingPermissionRequestId;
  final String? pendingUserInputRequestId;
  final List<UserInputQuestion> pendingUserInputQuestions;
  final bool runtimeReady;
  final String? runtimeStatusMessage;

  List<ChatMessage> get activeMessages {
    final sessionId = activeSessionId;
    if (sessionId == null) {
      return const <ChatMessage>[];
    }

    return messagesBySession[sessionId] ?? const <ChatMessage>[];
  }

  SessionDiffState? get activeDiff {
    final sessionId = activeSessionId;
    if (sessionId == null) {
      return null;
    }

    return diffBySession[sessionId];
  }

  String get activeTerminalOutput {
    final terminalId = activeTerminalId;
    if (terminalId == null) {
      return '';
    }

    return terminalOutputById[terminalId] ?? '';
  }

  AppState copyWith({
    bool? loading,
    String? error,
    bool clearError = false,
    String? serverUrl,
    List<String>? projectRoots,
    List<ProjectItem>? projects,
    List<ModelOption>? models,
    List<PermissionProfileOption>? profiles,
    List<CollaborationModeOption>? collaborationModes,
    List<ChatSession>? sessions,
    String? selectedProjectId,
    String? selectedModelId,
    String? selectedReasoningEffortId,
    String? selectedProfileId,
    String? selectedCollaborationModeId,
    String? activeSessionId,
    bool clearActiveSessionId = false,
    Map<String, List<ChatMessage>>? messagesBySession,
    Map<String, SessionDiffState>? diffBySession,
    List<TerminalSessionItem>? terminalSessions,
    String? activeTerminalId,
    bool clearActiveTerminalId = false,
    Map<String, String>? terminalOutputById,
    String? pendingPermissionRequestId,
    bool clearPendingPermissionRequest = false,
    String? pendingUserInputRequestId,
    List<UserInputQuestion>? pendingUserInputQuestions,
    bool clearPendingUserInputRequest = false,
    bool? runtimeReady,
    String? runtimeStatusMessage,
  }) {
    return AppState(
      loading: loading ?? this.loading,
      error: clearError ? null : error ?? this.error,
      serverUrl: serverUrl ?? this.serverUrl,
      projectRoots: projectRoots ?? this.projectRoots,
      projects: projects ?? this.projects,
      models: models ?? this.models,
      profiles: profiles ?? this.profiles,
      collaborationModes: collaborationModes ?? this.collaborationModes,
      sessions: sessions ?? this.sessions,
      selectedProjectId: selectedProjectId ?? this.selectedProjectId,
      selectedModelId: selectedModelId ?? this.selectedModelId,
      selectedReasoningEffortId:
          selectedReasoningEffortId ?? this.selectedReasoningEffortId,
      selectedProfileId: selectedProfileId ?? this.selectedProfileId,
      selectedCollaborationModeId:
          selectedCollaborationModeId ?? this.selectedCollaborationModeId,
      activeSessionId:
          clearActiveSessionId ? null : activeSessionId ?? this.activeSessionId,
      messagesBySession: messagesBySession ?? this.messagesBySession,
      diffBySession: diffBySession ?? this.diffBySession,
      terminalSessions: terminalSessions ?? this.terminalSessions,
      activeTerminalId: clearActiveTerminalId
          ? null
          : activeTerminalId ?? this.activeTerminalId,
      terminalOutputById: terminalOutputById ?? this.terminalOutputById,
      pendingPermissionRequestId: clearPendingPermissionRequest
          ? null
          : pendingPermissionRequestId ?? this.pendingPermissionRequestId,
      pendingUserInputRequestId: clearPendingUserInputRequest
          ? null
          : pendingUserInputRequestId ?? this.pendingUserInputRequestId,
      pendingUserInputQuestions: clearPendingUserInputRequest
          ? <UserInputQuestion>[]
          : pendingUserInputQuestions ?? this.pendingUserInputQuestions,
      runtimeReady: runtimeReady ?? this.runtimeReady,
      runtimeStatusMessage: runtimeStatusMessage ?? this.runtimeStatusMessage,
    );
  }
}
