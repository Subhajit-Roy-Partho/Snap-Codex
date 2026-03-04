import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_models.dart';
import '../services/api_client.dart';
import '../services/chat_socket_service.dart';
import '../services/notification_service.dart';
import 'app_state.dart';

final backendBaseUrlProvider = Provider<String>((ref) {
  return const String.fromEnvironment(
    'BACKEND_URL',
    defaultValue: 'http://127.0.0.1:8787',
  );
});

final authTokenProvider = Provider<String>((ref) {
  return const String.fromEnvironment('AUTH_TOKEN', defaultValue: 'dev-token');
});

final socketServiceProvider = Provider<ChatSocketService>((ref) {
  final service = ChatSocketService();
  ref.onDispose(service.dispose);
  return service;
});

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService();
});

final appControllerProvider =
    StateNotifierProvider<AppController, AppState>((ref) {
  final controller = AppController(
    socketService: ref.watch(socketServiceProvider),
    notificationService: ref.watch(notificationServiceProvider),
    token: ref.watch(authTokenProvider),
    defaultBackendBaseUrl: ref.watch(backendBaseUrlProvider),
  );

  ref.onDispose(controller.dispose);
  return controller;
});

class AppController extends StateNotifier<AppState> {
  AppController({
    required ChatSocketService socketService,
    required NotificationService notificationService,
    required String token,
    required String defaultBackendBaseUrl,
  })  : _socketService = socketService,
        _notificationService = notificationService,
        _token = token,
        _backendBaseUrl = _normalizeUrl(defaultBackendBaseUrl),
        super(
            AppState.initial(serverUrl: _normalizeUrl(defaultBackendBaseUrl))) {
    _apiClient = ApiClient(baseUrl: _backendBaseUrl, token: _token);
    _socketSubscription = _socketService.events.listen(_handleServerEvent);
  }

  static const String _serverUrlPreferenceKey = 'backend_server_url';
  static const int _maxTerminalOutputLength = 400000;

  late ApiClient _apiClient;
  final ChatSocketService _socketService;
  final NotificationService _notificationService;
  final String _token;
  String _backendBaseUrl;

  StreamSubscription<ServerEvent>? _socketSubscription;
  bool _initialized = false;

  Future<void> initialize({bool force = false}) async {
    if (_initialized && !force) {
      return;
    }

    state = state.copyWith(
        loading: true, clearError: true, serverUrl: _backendBaseUrl);

    try {
      await _loadPersistedServerUrl();
      _ensureSocketConnected();

      await _notificationService.initialize(_apiClient);

      final results = await Future.wait<dynamic>(<Future<dynamic>>[
        _apiClient.fetchProjectRoots(),
        _apiClient.fetchProjects(),
        _apiClient.fetchModels(),
        _apiClient.fetchProfiles(),
        _apiClient.fetchCollaborationModes(),
        _apiClient.fetchSessions(),
        _apiClient.fetchTerminalSessions(),
        _apiClient.fetchHealthStatus(),
      ]);

      final projectRoots = results[0] as List<String>;
      final projects = results[1] as List<ProjectItem>;
      final models = results[2] as List<ModelOption>;
      final profiles = results[3] as List<PermissionProfileOption>;
      final collaborationModes = results[4] as List<CollaborationModeOption>;
      final sessions = results[5] as List<ChatSession>;
      final terminalSessions = results[6] as List<TerminalSessionItem>;
      final runtimeHealth = results[7] as RuntimeHealthStatus;

      String? selectedProjectId = _pickExistingOrFirst(
        state.selectedProjectId,
        projects.map((project) => project.id).toList(),
      );
      String? selectedModelId = _pickExistingOrFirst(
        state.selectedModelId,
        models.map((model) => model.id).toList(),
      );
      String? selectedReasoningEffortId = _pickReasoningEffort(
        modelId: selectedModelId,
        currentReasoningEffortId: state.selectedReasoningEffortId,
        models: models,
      );
      String? selectedProfileId = _pickExistingOrFirst(
        state.selectedProfileId,
        profiles.map((profile) => profile.id).toList(),
      );
      String? selectedCollaborationModeId = _pickExistingOrFirst(
        state.selectedCollaborationModeId,
        collaborationModes.map((mode) => mode.id).toList(),
      );

      String? activeSessionId = state.activeSessionId;
      if (activeSessionId != null &&
          !sessions.any((session) => session.id == activeSessionId)) {
        activeSessionId = null;
      }

      if (activeSessionId == null && sessions.isNotEmpty) {
        final recent = sessions.last;
        activeSessionId = recent.id;
        selectedProjectId = recent.projectId;
        selectedModelId = recent.modelId;
        selectedReasoningEffortId = recent.reasoningEffort;
        selectedProfileId = recent.profileId;
        selectedCollaborationModeId = recent.collaborationMode;
      }

      String? activeTerminalId = state.activeTerminalId;
      if (activeTerminalId != null &&
          !terminalSessions
              .any((terminal) => terminal.id == activeTerminalId)) {
        activeTerminalId = null;
      }
      if (activeTerminalId == null && terminalSessions.isNotEmpty) {
        final running = terminalSessions.where((terminal) => terminal.running);
        activeTerminalId =
            running.isNotEmpty ? running.last.id : terminalSessions.last.id;
      }

      state = state.copyWith(
        loading: false,
        projectRoots: projectRoots,
        projects: projects,
        models: models,
        profiles: profiles,
        collaborationModes: collaborationModes,
        sessions: sessions,
        terminalSessions: terminalSessions,
        selectedProjectId: selectedProjectId,
        selectedModelId: selectedModelId,
        selectedReasoningEffortId: selectedReasoningEffortId,
        selectedProfileId: selectedProfileId,
        selectedCollaborationModeId: selectedCollaborationModeId,
        activeSessionId: activeSessionId,
        activeTerminalId: activeTerminalId,
        serverUrl: _backendBaseUrl,
        runtimeReady: runtimeHealth.ready,
        runtimeStatusMessage: runtimeHealth.message,
      );

      if (activeSessionId != null) {
        await _activateSession(activeSessionId);
      }
      if (activeTerminalId != null) {
        await _activateTerminal(activeTerminalId);
      }

      _initialized = true;
    } catch (error) {
      state = state.copyWith(
        loading: false,
        error: '$error',
      );
    }
  }

  Future<void> updateServerUrl(String nextServerUrl) async {
    final normalized = _normalizeUrl(nextServerUrl);
    if (normalized.isEmpty) {
      state = state.copyWith(
        clearError: true,
        error: 'Invalid server URL. Use host:port or http(s)://host:port.',
      );
      return;
    }

    if (normalized == _backendBaseUrl) {
      state = state.copyWith(serverUrl: normalized, clearError: true);
      return;
    }

    state = state.copyWith(
      loading: true,
      clearError: true,
      serverUrl: normalized,
      projectRoots: const <String>[],
      sessions: const <ChatSession>[],
      messagesBySession: const <String, List<ChatMessage>>{},
      diffBySession: const <String, SessionDiffState>{},
      terminalSessions: const <TerminalSessionItem>[],
      terminalOutputById: const <String, String>{},
      clearActiveSessionId: true,
      clearActiveTerminalId: true,
      clearPendingPermissionRequest: true,
      clearPendingUserInputRequest: true,
      runtimeReady: false,
      runtimeStatusMessage: 'Checking runtime status...',
    );

    _socketService.disconnect();
    _backendBaseUrl = normalized;
    _apiClient = ApiClient(baseUrl: _backendBaseUrl, token: _token);

    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_serverUrlPreferenceKey, _backendBaseUrl);

    _initialized = false;
    await initialize(force: true);
  }

  void clearError() {
    if (state.error == null) {
      return;
    }

    state = state.copyWith(clearError: true);
  }

  Future<void> selectProjectAndSwitch(String projectId) async {
    state = state.copyWith(selectedProjectId: projectId);

    final existing = state.sessions
        .where((session) => session.projectId == projectId)
        .toList();
    if (existing.isNotEmpty) {
      await _activateSession(existing.last.id);
      return;
    }

    await startNewSession(projectIdOverride: projectId);
  }

  Future<void> selectProjectRootAndSwitch(String rootPath) async {
    final normalizedRoot = _normalizeFsPath(rootPath);
    if (normalizedRoot.isEmpty) {
      return;
    }

    state = state.copyWith(clearError: true);

    var project = _bestProjectForRoot(normalizedRoot, state.projects);
    if (project == null) {
      final refreshed = await _refreshProjectsAndRoots();
      if (!refreshed) {
        return;
      }

      project = _bestProjectForRoot(normalizedRoot, state.projects);
      if (project == null) {
        state = state.copyWith(
          error:
              'No project found under "$normalizedRoot". Add or scan this folder first.',
        );
        return;
      }
    }

    state = state.copyWith(selectedProjectId: project.id);

    final projectsById = <String, ProjectItem>{
      for (final item in state.projects) item.id: item,
    };

    final matchingSessions = state.sessions.where((session) {
      final sessionProject = projectsById[session.projectId];
      if (sessionProject == null) {
        return false;
      }
      return _isPathWithinRoot(sessionProject.path, normalizedRoot);
    }).toList();

    if (matchingSessions.isNotEmpty) {
      await _activateSession(matchingSessions.last.id);
      return;
    }

    await startNewSession(projectIdOverride: project.id);
  }

  void selectModel(String modelId) {
    final nextReasoningEffortId = _pickReasoningEffort(
      modelId: modelId,
      currentReasoningEffortId: state.selectedReasoningEffortId,
      models: state.models,
    );

    state = state.copyWith(
      selectedModelId: modelId,
      selectedReasoningEffortId: nextReasoningEffortId,
    );
  }

  void selectReasoningEffort(String reasoningEffortId) {
    state = state.copyWith(selectedReasoningEffortId: reasoningEffortId);
  }

  void selectProfile(String profileId) {
    state = state.copyWith(selectedProfileId: profileId);
  }

  void selectCollaborationMode(String collaborationModeId) {
    state = state.copyWith(selectedCollaborationModeId: collaborationModeId);
  }

  Future<void> addProjectRoot(String folderPath) async {
    final trimmed = folderPath.trim();
    if (trimmed.isEmpty) {
      return;
    }

    state = state.copyWith(loading: true, clearError: true);
    try {
      final result = await _apiClient.addProjectRoot(trimmed);
      final projects = result.projects;
      final selectedProjectId = _pickExistingOrFirst(
        state.selectedProjectId,
        projects.map((project) => project.id).toList(),
      );
      state = state.copyWith(
        loading: false,
        projectRoots: result.roots,
        projects: projects,
        selectedProjectId: selectedProjectId,
      );
    } catch (error) {
      state = state.copyWith(loading: false, error: '$error');
    }
  }

  Future<DirectoryBrowseResult> browseDirectories(
    String directoryPath, {
    int limit = 200,
  }) {
    final normalized =
        directoryPath.trim().isEmpty ? '.' : directoryPath.trim();
    return _apiClient.browseDirectories(path: normalized, limit: limit);
  }

  Future<List<String>> suggestDirectories(
    String query, {
    String? basePath,
    int limit = 20,
  }) {
    return _apiClient.suggestDirectories(
      query: query,
      basePath: basePath,
      limit: limit,
    );
  }

  Future<HistoryPage> loadHistory({
    String? cursor,
    bool includeAllWorkspaces = false,
  }) async {
    final selectedProject = state.projects
        .where((project) => project.id == state.selectedProjectId)
        .toList();
    final cwd = includeAllWorkspaces || selectedProject.isEmpty
        ? null
        : selectedProject.first.path;
    final page = await _apiClient.fetchHistory(
      cursor: cursor,
      cwd: cwd,
      limit: 20,
    );

    if (!includeAllWorkspaces &&
        cursor == null &&
        cwd != null &&
        page.data.isEmpty) {
      return _apiClient.fetchHistory(
        cursor: null,
        cwd: null,
        limit: 20,
      );
    }

    return page;
  }

  Future<bool> _refreshProjectsAndRoots() async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final results = await Future.wait<dynamic>(<Future<dynamic>>[
        _apiClient.fetchProjectRoots(),
        _apiClient.fetchProjects(),
      ]);

      final roots = results[0] as List<String>;
      final projects = results[1] as List<ProjectItem>;
      final selectedProjectId = _pickExistingOrFirst(
        state.selectedProjectId,
        projects.map((project) => project.id).toList(),
      );

      state = state.copyWith(
        loading: false,
        projectRoots: roots,
        projects: projects,
        selectedProjectId: selectedProjectId,
      );
      return true;
    } catch (error) {
      state = state.copyWith(
        loading: false,
        error: 'Failed to refresh projects: $error',
      );
      return false;
    }
  }

  Future<bool> resumeHistoryThread(HistoryThread thread) async {
    final project = await _findProjectForThread(thread);
    if (project == null) {
      state = state.copyWith(
        error:
            'Project for history thread was not found. Add its folder first.',
      );
      return false;
    }

    final modelId = state.selectedModelId ??
        _pickExistingOrFirst(null, state.models.map((e) => e.id).toList());
    final profileId = state.selectedProfileId ??
        _pickExistingOrFirst(null, state.profiles.map((e) => e.id).toList());
    final collaborationModeId = state.selectedCollaborationModeId ??
        _pickExistingOrFirst(
            null, state.collaborationModes.map((e) => e.id).toList());
    final reasoningEffortId = _pickReasoningEffort(
      modelId: modelId,
      currentReasoningEffortId: state.selectedReasoningEffortId,
      models: state.models,
    );

    if (modelId == null ||
        profileId == null ||
        collaborationModeId == null ||
        reasoningEffortId == null) {
      state = state.copyWith(
        error:
            'Cannot resume history until model, profile, and mode are available.',
      );
      return false;
    }

    state = state.copyWith(loading: true, clearError: true);
    try {
      final result = await _apiClient.resumeSession(
        threadId: thread.threadId,
        projectId: project.id,
        modelId: modelId,
        profileId: profileId,
        reasoningEffort: reasoningEffortId,
        collaborationMode: collaborationModeId,
      );
      final session = result.session;

      final exists = state.sessions.any((item) => item.id == session.id);
      final updatedSessions =
          exists ? state.sessions : <ChatSession>[...state.sessions, session];

      final updatedMessagesBySession = Map<String, List<ChatMessage>>.from(
        state.messagesBySession,
      )..[session.id] = result.messages;

      state = state.copyWith(
        loading: false,
        sessions: updatedSessions,
        selectedProjectId: project.id,
        messagesBySession: updatedMessagesBySession,
      );

      await _activateSession(session.id);
      return true;
    } catch (error) {
      state = state.copyWith(loading: false, error: '$error');
      return false;
    }
  }

  Future<void> startNewSession({String? projectIdOverride}) async {
    final projectId = projectIdOverride ?? state.selectedProjectId;
    final hydratedSelections = _hydrateSessionSelections(
      modelId: state.selectedModelId,
      reasoningEffortId: state.selectedReasoningEffortId,
      profileId: state.selectedProfileId,
      collaborationModeId: state.selectedCollaborationModeId,
    );
    final modelId = hydratedSelections.modelId;
    final reasoningEffort = hydratedSelections.reasoningEffortId;
    final profileId = hydratedSelections.profileId;
    final collaborationModeId =
        hydratedSelections.collaborationModeId ?? 'default';

    if (projectId == null ||
        modelId == null ||
        profileId == null ||
        reasoningEffort == null) {
      state = state.copyWith(
        error:
            'Cannot start session yet. Ensure project, model, profile, and reasoning are available.',
      );
      return;
    }

    state = state.copyWith(loading: true, clearError: true);

    try {
      final session = await _apiClient.createSession(
        projectId: projectId,
        modelId: modelId,
        profileId: profileId,
        reasoningEffort: reasoningEffort,
        collaborationMode: collaborationModeId,
      );

      final updatedSessions = <ChatSession>[...state.sessions, session];

      state = state.copyWith(
        loading: false,
        sessions: updatedSessions,
        activeSessionId: session.id,
      );

      await _activateSession(session.id);
    } catch (error) {
      state = state.copyWith(loading: false, error: '$error');
    }
  }

  Future<void> setActiveSession(String sessionId) async {
    await _activateSession(sessionId);
  }

  Future<void> refreshActiveChat() async {
    final sessionId = state.activeSessionId;
    if (sessionId == null) {
      return;
    }

    state = state.copyWith(clearError: true);
    _ensureSocketConnected();
    _socketService.subscribeSession(sessionId);

    try {
      final latestSession = await _apiClient.fetchSession(sessionId);
      final updatedSessions = state.sessions
          .map((session) =>
              session.id == latestSession.id ? latestSession : session)
          .toList();
      state = state.copyWith(sessions: updatedSessions);
    } catch (_) {
      // Continue and still refresh messages.
    }

    try {
      final messages = await _apiClient.fetchMessages(sessionId);
      final updatedMap =
          Map<String, List<ChatMessage>>.from(state.messagesBySession)
            ..[sessionId] = messages;
      state = state.copyWith(messagesBySession: updatedMap);
    } catch (error) {
      state = state.copyWith(error: '$error');
    }
  }

  Future<void> sendMessage(String content,
      {bool requestPermission = false}) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      return;
    }

    var sessionId = state.activeSessionId;
    if (sessionId == null) {
      await startNewSession();
      sessionId = state.activeSessionId;
    }

    if (sessionId == null) {
      return;
    }

    try {
      _ensureSocketConnected();
      _socketService.subscribeSession(sessionId);

      final message = await _apiClient.sendMessage(
        sessionId: sessionId,
        content: trimmed,
        requestPermission: requestPermission,
      );
      _upsertMessage(message);
    } catch (error) {
      state = state.copyWith(error: '$error');
    }
  }

  Future<void> ensureTerminalSession() async {
    final activeTerminalId = state.activeTerminalId;
    if (activeTerminalId != null &&
        state.terminalSessions
            .any((terminal) => terminal.id == activeTerminalId)) {
      await _activateTerminal(activeTerminalId);
      return;
    }

    final cwd = _selectedProjectPath();
    await createTerminalSession(cwd: cwd);
  }

  Future<void> createTerminalSession({String? cwd}) async {
    final threadId = _activeSessionThreadId();
    final bootstrapCommands = <String>[
      if (threadId != null && threadId.trim().isNotEmpty)
        'codex --yolo resume ${threadId.trim()}',
    ];

    try {
      final snapshot = await _apiClient.createTerminalSession(
        cwd: cwd,
        shell: '/bin/zsh',
        bootstrap: bootstrapCommands,
      );
      final updatedSessions = _upsertTerminalSession(snapshot.session);
      final updatedOutput = Map<String, String>.from(state.terminalOutputById)
        ..[snapshot.session.id] = _trimTerminalOutput(snapshot.output);
      state = state.copyWith(
        terminalSessions: updatedSessions,
        terminalOutputById: updatedOutput,
        activeTerminalId: snapshot.session.id,
      );
      await _activateTerminal(snapshot.session.id);
    } catch (error) {
      state = state.copyWith(error: '$error');
    }
  }

  Future<void> setActiveTerminal(String terminalId) async {
    await _activateTerminal(terminalId);
  }

  Future<void> sendTerminalInput(String input, {bool raw = false}) async {
    if (input.isEmpty) {
      return;
    }

    final command = raw ? input : input.trimRight();
    if (command.isEmpty) {
      return;
    }

    var terminalId = state.activeTerminalId;
    if (terminalId == null) {
      await ensureTerminalSession();
      terminalId = state.activeTerminalId;
    }
    if (terminalId == null) {
      return;
    }

    final payload =
        raw ? command : (command.endsWith('\n') ? command : '$command\n');

    try {
      _ensureSocketConnected();
      _socketService.subscribeTerminal(terminalId);
      _socketService.sendTerminalInput(terminalId: terminalId, input: payload);
    } catch (_) {
      try {
        await _apiClient.sendTerminalInput(
          terminalId: terminalId,
          input: payload,
        );
      } catch (error) {
        state = state.copyWith(error: '$error');
      }
    }
  }

  Future<void> resizeTerminal({
    required int cols,
    required int rows,
  }) async {
    final terminalId = state.activeTerminalId;
    if (terminalId == null) {
      return;
    }

    final normalizedCols = cols.clamp(20, 400).toInt();
    final normalizedRows = rows.clamp(5, 200).toInt();
    try {
      await _apiClient.resizeTerminalSession(
        terminalId: terminalId,
        cols: normalizedCols,
        rows: normalizedRows,
      );
    } catch (_) {
      // Best-effort only: some backend versions do not expose resize APIs.
    }
  }

  Future<void> closeActiveTerminal() async {
    final terminalId = state.activeTerminalId;
    if (terminalId == null) {
      return;
    }

    try {
      await _apiClient.closeTerminalSession(terminalId);
      _socketService.unsubscribeTerminal(terminalId);

      final existing = state.terminalSessions
          .where((terminal) => terminal.id != terminalId)
          .toList();
      final nextActive = existing.isEmpty ? null : existing.last.id;

      state = state.copyWith(
        activeTerminalId: nextActive,
      );

      if (nextActive != null) {
        await _activateTerminal(nextActive);
      }
    } catch (error) {
      state = state.copyWith(error: '$error');
    }
  }

  Future<void> interrupt() async {
    final sessionId = state.activeSessionId;
    if (sessionId == null) {
      return;
    }

    await _apiClient.sendAction(sessionId: sessionId, action: 'interrupt');
  }

  Future<void> respondPermission(bool approved) async {
    final sessionId = state.activeSessionId;
    final requestId = state.pendingPermissionRequestId;
    if (sessionId == null || requestId == null) {
      return;
    }

    _ensureSocketConnected();
    _socketService.subscribeSession(sessionId);
    _socketService.respondPermission(
      sessionId: sessionId,
      requestId: requestId,
      approved: approved,
    );
  }

  Future<void> respondUserInput(
    Map<String, String> selectedAnswersByQuestionId,
  ) async {
    final sessionId = state.activeSessionId;
    final requestId = state.pendingUserInputRequestId;
    if (sessionId == null || requestId == null) {
      return;
    }

    final payload = <String, Map<String, List<String>>>{};
    for (final entry in selectedAnswersByQuestionId.entries) {
      payload[entry.key] = <String, List<String>>{
        'answers': <String>[entry.value],
      };
    }

    _ensureSocketConnected();
    _socketService.subscribeSession(sessionId);
    _socketService.respondUserInput(
      sessionId: sessionId,
      requestId: requestId,
      answers: payload,
    );
  }

  Future<void> _activateSession(String sessionId) async {
    final activeSession =
        state.sessions.where((session) => session.id == sessionId);
    if (activeSession.isEmpty) {
      return;
    }

    final session = activeSession.first;

    final previousSessionId = state.activeSessionId;
    if (previousSessionId != null && previousSessionId != sessionId) {
      _socketService.unsubscribeSession(previousSessionId);
    }

    _ensureSocketConnected();
    _socketService.subscribeSession(sessionId);

    state = state.copyWith(
      activeSessionId: sessionId,
      selectedProjectId: session.projectId,
      selectedModelId: session.modelId,
      selectedReasoningEffortId: session.reasoningEffort,
      selectedProfileId: session.profileId,
      selectedCollaborationModeId: session.collaborationMode,
      clearPendingPermissionRequest: true,
      clearPendingUserInputRequest: true,
    );

    try {
      final messages = await _apiClient.fetchMessages(sessionId);
      final updatedMap =
          Map<String, List<ChatMessage>>.from(state.messagesBySession)
            ..[sessionId] = messages;
      state = state.copyWith(messagesBySession: updatedMap);
    } catch (error) {
      state = state.copyWith(error: '$error');
    }
  }

  Future<void> _activateTerminal(String terminalId) async {
    final terminal =
        state.terminalSessions.where((item) => item.id == terminalId).toList();
    if (terminal.isEmpty) {
      return;
    }

    final previousTerminalId = state.activeTerminalId;
    if (previousTerminalId != null && previousTerminalId != terminalId) {
      _socketService.unsubscribeTerminal(previousTerminalId);
    }

    _ensureSocketConnected();
    _socketService.subscribeTerminal(terminalId);

    state = state.copyWith(
      activeTerminalId: terminalId,
    );

    try {
      final snapshot = await _apiClient.fetchTerminalSnapshot(terminalId);
      final updatedSessions = _upsertTerminalSession(snapshot.session);
      final updatedOutput = Map<String, String>.from(state.terminalOutputById)
        ..[terminalId] = _trimTerminalOutput(snapshot.output);
      state = state.copyWith(
        terminalSessions: updatedSessions,
        terminalOutputById: updatedOutput,
      );
    } catch (error) {
      state = state.copyWith(error: '$error');
    }
  }

  void _handleServerEvent(ServerEvent event) {
    if (_shouldNotifyForEvent(event)) {
      _notificationService.notifyFromEvent(event);
    }

    if (event.type == 'terminal.started') {
      final payload = event.payload;
      final startedSession = TerminalSessionItem(
        id: '${payload['terminalId'] ?? ''}',
        cwd: '${payload['cwd'] ?? ''}',
        shell: '${payload['shell'] ?? ''}',
        running: payload['running'] == true,
        startedAt:
            DateTime.tryParse('${payload['startedAt']}') ?? DateTime.now(),
        endedAt: null,
      );
      final updatedSessions = _upsertTerminalSession(startedSession);
      state = state.copyWith(
        terminalSessions: updatedSessions,
        activeTerminalId: state.activeTerminalId ?? startedSession.id,
      );
      return;
    }

    if (event.type == 'terminal.snapshot') {
      final payload = event.payload;
      final snapshot = TerminalSnapshot.fromJson(payload);
      final updatedSessions = _upsertTerminalSession(snapshot.session);
      final updatedOutput = Map<String, String>.from(state.terminalOutputById)
        ..[snapshot.session.id] = _trimTerminalOutput(snapshot.output);
      state = state.copyWith(
        terminalSessions: updatedSessions,
        terminalOutputById: updatedOutput,
      );
      return;
    }

    if (event.type == 'terminal.output') {
      final payload = event.payload;
      final terminalId = '${payload['terminalId'] ?? ''}';
      if (terminalId.isEmpty) {
        return;
      }
      final data = '${payload['data'] ?? ''}';
      if (data.isEmpty) {
        return;
      }

      final existing = state.terminalOutputById[terminalId] ?? '';
      final next = _trimTerminalOutput('$existing$data');
      final updated = Map<String, String>.from(state.terminalOutputById)
        ..[terminalId] = next;
      state = state.copyWith(terminalOutputById: updated);
      return;
    }

    if (event.type == 'terminal.exited') {
      final payload = event.payload;
      final terminalId = '${payload['terminalId'] ?? ''}';
      if (terminalId.isEmpty) {
        return;
      }

      final timestampText = '${payload['timestamp'] ?? ''}';
      final endedAt = DateTime.tryParse(timestampText) ?? DateTime.now();
      final updatedSessions = state.terminalSessions
          .map((terminal) => terminal.id == terminalId
              ? TerminalSessionItem(
                  id: terminal.id,
                  cwd: terminal.cwd,
                  shell: terminal.shell,
                  running: false,
                  startedAt: terminal.startedAt,
                  endedAt: endedAt,
                )
              : terminal)
          .toList();

      state = state.copyWith(terminalSessions: updatedSessions);
      return;
    }

    if (event.type == 'project.scan.updated') {
      final projects = (event.payload['projects'] as List<dynamic>)
          .map((dynamic e) => ProjectItem.fromJson(e as Map<String, dynamic>))
          .toList();
      state = state.copyWith(projects: projects);
      return;
    }

    if (event.type == 'session.started') {
      final newSession = ChatSession.fromJson(event.payload);
      final exists =
          state.sessions.any((session) => session.id == newSession.id);
      if (!exists) {
        state = state
            .copyWith(sessions: <ChatSession>[...state.sessions, newSession]);
      }
      return;
    }

    if (event.type == 'session.state.changed') {
      final sessionId = '${event.payload['sessionId']}';
      final status = '${event.payload['status']}';
      final updated = state.sessions
          .map((session) => session.id == sessionId
              ? ChatSession(
                  id: session.id,
                  projectId: session.projectId,
                  modelId: session.modelId,
                  profileId: session.profileId,
                  collaborationMode: session.collaborationMode,
                  reasoningEffort: session.reasoningEffort,
                  threadId: session.threadId,
                  status: status,
                )
              : session)
          .toList();
      state = state.copyWith(sessions: updated);

      if (status == 'running') {
        _appendTimelineEvent(sessionId, 'Thinking...');
      }
      return;
    }

    if (event.type == 'tool.started') {
      final sessionId = '${event.payload['sessionId']}';
      final toolName = '${event.payload['toolName']}';
      final inputSummary = '${event.payload['inputSummary'] ?? ''}';
      final normalized = inputSummary.trim();
      final summaryText = normalized.isEmpty ? '' : ' $normalized';
      _appendTimelineEvent(sessionId, 'Running $toolName$summaryText');
      return;
    }

    if (event.type == 'tool.completed') {
      final sessionId = '${event.payload['sessionId']}';
      final toolName = '${event.payload['toolName']}';
      final success = event.payload['success'] == true;
      final outputSummary = '${event.payload['outputSummary'] ?? ''}';
      final normalized = outputSummary.trim();
      final summaryText = normalized.isEmpty ? '' : ': $normalized';
      _appendTimelineEvent(
        sessionId,
        success
            ? '$toolName completed$summaryText'
            : '$toolName failed$summaryText',
      );
      return;
    }

    if (event.type == 'turn.diff.updated') {
      final sessionId = '${event.payload['sessionId']}';
      final diff = '${event.payload['diff'] ?? ''}';
      _upsertSessionDiff(sessionId: sessionId, diff: diff);
      return;
    }

    if (event.type == 'permission.requested') {
      state = state.copyWith(
        pendingPermissionRequestId: '${event.payload['requestId']}',
      );
      return;
    }

    if (event.type == 'permission.resolved') {
      state = state.copyWith(clearPendingPermissionRequest: true);
      return;
    }

    if (event.type == 'user.input.requested') {
      final questions =
          (event.payload['questions'] as List<dynamic>? ?? <dynamic>[])
              .map(
                (dynamic entry) =>
                    UserInputQuestion.fromJson(entry as Map<String, dynamic>),
              )
              .toList();

      state = state.copyWith(
        pendingUserInputRequestId: '${event.payload['requestId']}',
        pendingUserInputQuestions: questions,
      );
      return;
    }

    if (event.type == 'user.input.resolved') {
      state = state.copyWith(clearPendingUserInputRequest: true);
      return;
    }

    if (event.type == 'message.delta') {
      final sessionId = '${event.payload['sessionId']}';
      final messageId = '${event.payload['messageId']}';
      final delta = '${event.payload['delta']}';
      _upsertStreamingMessage(
          sessionId: sessionId, messageId: messageId, delta: delta);
      return;
    }

    if (event.type == 'message.completed') {
      final message = ChatMessage.fromJson(event.payload);
      _upsertMessage(message);
      return;
    }

    if (event.type == 'error') {
      state = state.copyWith(error: '${event.payload['message']}');
    }
  }

  void _upsertStreamingMessage({
    required String sessionId,
    required String messageId,
    required String delta,
  }) {
    final sessionMessages = <ChatMessage>[
      ...(state.messagesBySession[sessionId] ?? const <ChatMessage>[])
    ];

    final messageIndex =
        sessionMessages.indexWhere((message) => message.id == messageId);

    if (messageIndex == -1) {
      sessionMessages.add(
        ChatMessage(
          id: messageId,
          sessionId: sessionId,
          role: 'assistant',
          content: delta,
          createdAt: DateTime.now(),
        ),
      );
    } else {
      final current = sessionMessages[messageIndex];
      sessionMessages[messageIndex] =
          current.copyWith(content: '${current.content}$delta');
    }

    final updatedMap =
        Map<String, List<ChatMessage>>.from(state.messagesBySession)
          ..[sessionId] = sessionMessages;

    state = state.copyWith(messagesBySession: updatedMap);
  }

  void _upsertMessage(ChatMessage message) {
    final sessionMessages = <ChatMessage>[
      ...(state.messagesBySession[message.sessionId] ?? const <ChatMessage>[])
    ];

    final messageIndex =
        sessionMessages.indexWhere((item) => item.id == message.id);

    if (messageIndex == -1) {
      sessionMessages.add(message);
    } else {
      sessionMessages[messageIndex] = message;
    }

    sessionMessages.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    final updatedMap =
        Map<String, List<ChatMessage>>.from(state.messagesBySession)
          ..[message.sessionId] = sessionMessages;

    state = state.copyWith(messagesBySession: updatedMap);
  }

  void _appendTimelineEvent(String sessionId, String content) {
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      return;
    }

    final sessionMessages = <ChatMessage>[
      ...(state.messagesBySession[sessionId] ?? const <ChatMessage>[])
    ];

    if (sessionMessages.isNotEmpty) {
      final last = sessionMessages.last;
      if (last.role == 'system' && last.content == trimmed) {
        return;
      }
    }

    sessionMessages.add(
      ChatMessage(
        id: 'evt-${DateTime.now().microsecondsSinceEpoch}',
        sessionId: sessionId,
        role: 'system',
        content: trimmed,
        createdAt: DateTime.now(),
      ),
    );

    final updatedMap =
        Map<String, List<ChatMessage>>.from(state.messagesBySession)
          ..[sessionId] = sessionMessages;
    state = state.copyWith(messagesBySession: updatedMap);
  }

  void _upsertSessionDiff({
    required String sessionId,
    required String diff,
  }) {
    final parsedFiles = _parseUnifiedDiff(diff);
    final updated = Map<String, SessionDiffState>.from(state.diffBySession)
      ..[sessionId] = SessionDiffState(
        rawDiff: diff,
        updatedAt: DateTime.now(),
        files: parsedFiles,
      );

    state = state.copyWith(diffBySession: updated);
  }

  List<SessionDiffFile> _parseUnifiedDiff(String rawDiff) {
    final trimmed = rawDiff.trim();
    if (trimmed.isEmpty) {
      return const <SessionDiffFile>[];
    }

    final lines = const LineSplitter().convert(rawDiff);
    final files = <SessionDiffFile>[];

    var hasActiveFile = false;
    var currentPath = 'Changes';
    var additions = 0;
    var deletions = 0;
    var hunks = <SessionDiffHunk>[];
    String? hunkHeader;
    var hunkLines = <SessionDiffLine>[];

    void beginMetaHunkIfNeeded(String defaultHeader) {
      if (hunkHeader == null && hunkLines.isEmpty) {
        hunkHeader = defaultHeader;
      }
    }

    void pushHunkIfAny() {
      if (hunkHeader == null && hunkLines.isEmpty) {
        return;
      }

      hunks.add(
        SessionDiffHunk(
          header: hunkHeader ?? '@@',
          lines: List<SessionDiffLine>.from(hunkLines),
        ),
      );
      hunkHeader = null;
      hunkLines = <SessionDiffLine>[];
    }

    void pushFileIfAny() {
      pushHunkIfAny();
      if (!hasActiveFile) {
        return;
      }

      if (hunks.isEmpty) {
        return;
      }

      files.add(
        SessionDiffFile(
          path: currentPath,
          hunks: List<SessionDiffHunk>.from(hunks),
          additions: additions,
          deletions: deletions,
        ),
      );

      hasActiveFile = false;
      currentPath = 'Changes';
      additions = 0;
      deletions = 0;
      hunks = <SessionDiffHunk>[];
      hunkHeader = null;
      hunkLines = <SessionDiffLine>[];
    }

    for (final line in lines) {
      if (line.startsWith('diff --git ')) {
        pushFileIfAny();
        hasActiveFile = true;
        final parts = line.split(' ');
        if (parts.length >= 4) {
          currentPath = parts[3].replaceFirst('b/', '');
        } else {
          currentPath = 'Changes';
        }
        beginMetaHunkIfNeeded('@@ metadata @@');
        hunkLines.add(SessionDiffLine(kind: 'meta', text: line));
        continue;
      }

      if (!hasActiveFile) {
        hasActiveFile = true;
        currentPath = 'Changes';
      }

      if (line.startsWith('+++ ')) {
        beginMetaHunkIfNeeded('@@ metadata @@');
        hunkLines.add(SessionDiffLine(kind: 'meta', text: line));
        final nextPath = line.substring(4).trim();
        if (nextPath.isNotEmpty && nextPath != '/dev/null') {
          currentPath =
              nextPath.startsWith('b/') ? nextPath.substring(2) : nextPath;
        }
        continue;
      }

      if (line.startsWith('--- ')) {
        beginMetaHunkIfNeeded('@@ metadata @@');
        hunkLines.add(SessionDiffLine(kind: 'meta', text: line));
        continue;
      }

      if (line.startsWith('@@')) {
        pushHunkIfAny();
        hunkHeader = line;
        continue;
      }

      if (line.startsWith('+')) {
        if (!line.startsWith('+++')) {
          additions += 1;
          beginMetaHunkIfNeeded('@@');
          hunkLines.add(SessionDiffLine(kind: 'added', text: line));
        }
        continue;
      }

      if (line.startsWith('-')) {
        if (!line.startsWith('---')) {
          deletions += 1;
          beginMetaHunkIfNeeded('@@');
          hunkLines.add(SessionDiffLine(kind: 'removed', text: line));
        }
        continue;
      }

      if (line.startsWith('\\ No newline at end of file') ||
          line.startsWith('index ') ||
          line.startsWith('new file mode') ||
          line.startsWith('deleted file mode') ||
          line.startsWith('similarity index') ||
          line.startsWith('rename from ') ||
          line.startsWith('rename to ')) {
        beginMetaHunkIfNeeded('@@ metadata @@');
        hunkLines.add(SessionDiffLine(kind: 'meta', text: line));
        continue;
      }

      beginMetaHunkIfNeeded('@@');
      hunkLines.add(SessionDiffLine(kind: 'context', text: line));
    }

    pushFileIfAny();

    if (files.isNotEmpty) {
      return files;
    }

    return <SessionDiffFile>[
      SessionDiffFile(
        path: 'Changes',
        hunks: <SessionDiffHunk>[
          SessionDiffHunk(
            header: '@@',
            lines: lines
                .map((line) => SessionDiffLine(kind: 'context', text: line))
                .toList(),
          ),
        ],
        additions: 0,
        deletions: 0,
      ),
    ];
  }

  List<TerminalSessionItem> _upsertTerminalSession(
      TerminalSessionItem session) {
    final existing = <TerminalSessionItem>[...state.terminalSessions];
    final index = existing.indexWhere((item) => item.id == session.id);
    if (index == -1) {
      existing.add(session);
    } else {
      existing[index] = session;
    }
    existing.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    return existing;
  }

  String? _selectedProjectPath() {
    final projectId = state.selectedProjectId;
    if (projectId == null) {
      return null;
    }
    for (final project in state.projects) {
      if (project.id == projectId) {
        return project.path;
      }
    }
    return null;
  }

  String? _activeSessionThreadId() {
    final sessionId = state.activeSessionId;
    if (sessionId == null) {
      return null;
    }

    for (final session in state.sessions) {
      if (session.id == sessionId) {
        return session.threadId;
      }
    }

    return null;
  }

  String _trimTerminalOutput(String output) {
    if (output.length <= _maxTerminalOutputLength) {
      return output;
    }
    return output.substring(output.length - _maxTerminalOutputLength);
  }

  void _ensureSocketConnected() {
    if (_socketService.isConnected) {
      return;
    }

    _socketService.connect(baseWsUrl: _wsBaseUrl(), token: _token);
  }

  bool _shouldNotifyForEvent(ServerEvent event) {
    if (event.type == 'notification.dispatched' ||
        event.type == 'message.delta') {
      return false;
    }

    if (event.type == 'session.state.changed') {
      final status = '${event.payload['status']}';
      return status == 'completed' ||
          status == 'failed' ||
          status == 'cancelled';
    }

    if (event.type == 'message.completed') {
      final role = '${event.payload['role']}';
      return role == 'assistant';
    }

    return event.type == 'permission.requested' ||
        event.type == 'user.input.requested' ||
        event.type == 'error';
  }

  Future<void> _loadPersistedServerUrl() async {
    final preferences = await SharedPreferences.getInstance();
    final stored = preferences.getString(_serverUrlPreferenceKey);
    final normalized = _normalizeUrl(stored ?? '');

    if (normalized.isNotEmpty && normalized != _backendBaseUrl) {
      _backendBaseUrl = normalized;
      _apiClient = ApiClient(baseUrl: _backendBaseUrl, token: _token);
    }

    state = state.copyWith(serverUrl: _backendBaseUrl);
  }

  String _wsBaseUrl() {
    final uri = Uri.parse(_backendBaseUrl);
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    final normalizedPath = uri.path == '/' ? '' : uri.path;

    return Uri(
      scheme: scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: normalizedPath,
    ).toString();
  }

  String? _pickExistingOrFirst(String? current, List<String> values) {
    if (values.isEmpty) {
      return null;
    }

    if (current != null && values.contains(current)) {
      return current;
    }

    return values.first;
  }

  ({
    String? modelId,
    String? reasoningEffortId,
    String? profileId,
    String? collaborationModeId,
  }) _hydrateSessionSelections({
    required String? modelId,
    required String? reasoningEffortId,
    required String? profileId,
    required String? collaborationModeId,
  }) {
    final nextModelId = _pickExistingOrFirst(
      modelId,
      state.models.map((model) => model.id).toList(),
    );
    final nextReasoningEffortId = _pickReasoningEffort(
      modelId: nextModelId,
      currentReasoningEffortId: reasoningEffortId,
      models: state.models,
    );
    final nextProfileId = _pickExistingOrFirst(
      profileId,
      state.profiles.map((item) => item.id).toList(),
    );
    final nextCollaborationModeId = _pickExistingOrFirst(
          collaborationModeId,
          state.collaborationModes.map((item) => item.id).toList(),
        ) ??
        'default';

    state = state.copyWith(
      selectedModelId: nextModelId,
      selectedReasoningEffortId: nextReasoningEffortId,
      selectedProfileId: nextProfileId,
      selectedCollaborationModeId: nextCollaborationModeId,
    );

    return (
      modelId: nextModelId,
      reasoningEffortId: nextReasoningEffortId,
      profileId: nextProfileId,
      collaborationModeId: nextCollaborationModeId,
    );
  }

  Future<ProjectItem?> _findProjectForThread(HistoryThread thread) async {
    final cwd = thread.cwd?.trim();
    if (cwd == null || cwd.isEmpty) {
      return null;
    }

    ProjectItem? match = _bestProjectMatch(cwd, state.projects);
    if (match != null) {
      return match;
    }

    await addProjectRoot(cwd);
    match = _bestProjectMatch(cwd, state.projects);
    return match;
  }

  ProjectItem? _bestProjectMatch(String cwd, List<ProjectItem> projects) {
    final normalizedCwd = cwd.endsWith('/') && cwd.length > 1
        ? cwd.substring(0, cwd.length - 1)
        : cwd;
    ProjectItem? best;
    var bestScore = -1;
    var bestLen = -1;

    for (final project in projects) {
      final normalizedProject =
          project.path.endsWith('/') && project.path.length > 1
              ? project.path.substring(0, project.path.length - 1)
              : project.path;

      var score = -1;
      if (normalizedProject == normalizedCwd) {
        score = 3;
      } else if (normalizedCwd.startsWith('$normalizedProject/')) {
        score = 2;
      } else if (normalizedProject.startsWith('$normalizedCwd/')) {
        score = 1;
      }

      if (score < 0) {
        continue;
      }

      final len = normalizedProject.length;
      if (score > bestScore || (score == bestScore && len > bestLen)) {
        bestScore = score;
        bestLen = len;
        best = project;
      }
    }

    return best;
  }

  ProjectItem? _bestProjectForRoot(
      String rootPath, List<ProjectItem> projects) {
    final normalizedRoot = _normalizeFsPath(rootPath);
    ProjectItem? bestNested;
    var bestNestedLen = 1 << 30;

    for (final project in projects) {
      final normalizedProject = _normalizeFsPath(project.path);
      if (normalizedProject == normalizedRoot) {
        return project;
      }

      if (!normalizedProject.startsWith('$normalizedRoot/')) {
        continue;
      }

      if (normalizedProject.length < bestNestedLen) {
        bestNestedLen = normalizedProject.length;
        bestNested = project;
      }
    }

    return bestNested;
  }

  bool _isPathWithinRoot(String pathValue, String rootPath) {
    final normalizedPath = _normalizeFsPath(pathValue);
    final normalizedRoot = _normalizeFsPath(rootPath);
    return normalizedPath == normalizedRoot ||
        normalizedPath.startsWith('$normalizedRoot/');
  }

  String _normalizeFsPath(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return '';
    }

    if (trimmed == '/') {
      return '/';
    }

    if (trimmed.endsWith('/')) {
      return trimmed.substring(0, trimmed.length - 1);
    }

    return trimmed;
  }

  String? _pickReasoningEffort({
    required String? modelId,
    required String? currentReasoningEffortId,
    required List<ModelOption> models,
  }) {
    if (modelId == null) {
      return null;
    }

    final selectedModel = models.where((model) => model.id == modelId).toList();
    if (selectedModel.isEmpty) {
      return null;
    }

    final model = selectedModel.first;
    final allowed = model.supportedReasoningEfforts
        .where(
          (entry) =>
              entry == 'low' ||
              entry == 'medium' ||
              entry == 'high' ||
              entry == 'xhigh',
        )
        .toList();

    if (allowed.isEmpty) {
      return model.defaultReasoningEffort;
    }

    if (currentReasoningEffortId != null &&
        allowed.contains(currentReasoningEffortId)) {
      return currentReasoningEffortId;
    }

    if (allowed.contains(model.defaultReasoningEffort)) {
      return model.defaultReasoningEffort;
    }

    return allowed.first;
  }

  static String _normalizeUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return '';
    }

    final withScheme = trimmed.contains('://') ? trimmed : 'http://$trimmed';
    final parsed = Uri.tryParse(withScheme);

    if (parsed == null || parsed.host.isEmpty) {
      return '';
    }

    var path = parsed.path;
    if (path.endsWith('/') && path.length > 1) {
      path = path.substring(0, path.length - 1);
    }

    return parsed
        .replace(
          path: path,
          query: parsed.query.isEmpty ? null : parsed.query,
          fragment: null,
        )
        .toString();
  }

  @override
  void dispose() {
    _socketSubscription?.cancel();
    _socketService.disconnect();
    super.dispose();
  }
}
