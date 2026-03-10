import 'dart:typed_data';

class ProjectItem {
  ProjectItem({
    required this.id,
    required this.name,
    required this.path,
    required this.gitBranch,
    required this.gitDirty,
  });

  final String id;
  final String name;
  final String path;
  final String? gitBranch;
  final bool gitDirty;

  factory ProjectItem.fromJson(Map<String, dynamic> json) {
    return ProjectItem(
      id: json['id'] as String,
      name: json['name'] as String,
      path: json['path'] as String,
      gitBranch: json['gitBranch'] as String?,
      gitDirty: (json['gitDirty'] as bool?) ?? false,
    );
  }
}

class ProjectRootsResult {
  ProjectRootsResult({
    required this.roots,
    required this.projects,
  });

  final List<String> roots;
  final List<ProjectItem> projects;
}

class DirectoryEntryItem {
  DirectoryEntryItem({
    required this.name,
    required this.path,
    required this.readable,
  });

  final String name;
  final String path;
  final bool readable;

  factory DirectoryEntryItem.fromJson(Map<String, dynamic> json) {
    return DirectoryEntryItem(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      readable: json['readable'] as bool? ?? true,
    );
  }
}

class DirectoryBrowseResult {
  DirectoryBrowseResult({
    required this.resolvedPath,
    required this.parentPath,
    required this.entries,
  });

  final String resolvedPath;
  final String? parentPath;
  final List<DirectoryEntryItem> entries;

  factory DirectoryBrowseResult.fromJson(Map<String, dynamic> json) {
    return DirectoryBrowseResult(
      resolvedPath: json['resolvedPath'] as String? ?? '',
      parentPath: json['parentPath'] as String?,
      entries: (json['entries'] as List<dynamic>? ?? <dynamic>[])
          .map((dynamic entry) =>
              DirectoryEntryItem.fromJson(entry as Map<String, dynamic>))
          .toList(),
    );
  }
}

class ProjectFileEntry {
  ProjectFileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.extension,
    required this.sizeBytes,
    required this.lastModifiedAt,
    required this.readable,
    required this.writable,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final String? extension;
  final int? sizeBytes;
  final DateTime? lastModifiedAt;
  final bool readable;
  final bool writable;

  factory ProjectFileEntry.fromJson(Map<String, dynamic> json) {
    return ProjectFileEntry(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      isDirectory: json['isDirectory'] == true,
      extension: json['extension'] as String?,
      sizeBytes: (json['sizeBytes'] as num?)?.toInt(),
      lastModifiedAt: json['lastModifiedAt'] == null
          ? null
          : DateTime.tryParse('${json['lastModifiedAt']}'),
      readable: json['readable'] != false,
      writable: json['writable'] != false,
    );
  }
}

class ProjectFileListing {
  ProjectFileListing({
    required this.projectId,
    required this.projectPath,
    required this.currentPath,
    required this.parentPath,
    required this.entries,
  });

  final String projectId;
  final String projectPath;
  final String currentPath;
  final String? parentPath;
  final List<ProjectFileEntry> entries;

  factory ProjectFileListing.fromJson(Map<String, dynamic> json) {
    return ProjectFileListing(
      projectId: json['projectId'] as String? ?? '',
      projectPath: json['projectPath'] as String? ?? '',
      currentPath: json['currentPath'] as String? ?? '',
      parentPath: json['parentPath'] as String?,
      entries: (json['entries'] as List<dynamic>? ?? <dynamic>[])
          .map((dynamic entry) =>
              ProjectFileEntry.fromJson(entry as Map<String, dynamic>))
          .toList(),
    );
  }
}

class ProjectFileDocument {
  ProjectFileDocument({
    required this.projectId,
    required this.projectPath,
    required this.path,
    required this.name,
    required this.extension,
    required this.sizeBytes,
    required this.lastModifiedAt,
    required this.readable,
    required this.writable,
    required this.isBinary,
    required this.tooLarge,
    required this.content,
  });

  final String projectId;
  final String projectPath;
  final String path;
  final String name;
  final String? extension;
  final int sizeBytes;
  final DateTime? lastModifiedAt;
  final bool readable;
  final bool writable;
  final bool isBinary;
  final bool tooLarge;
  final String? content;

  factory ProjectFileDocument.fromJson(Map<String, dynamic> json) {
    return ProjectFileDocument(
      projectId: json['projectId'] as String? ?? '',
      projectPath: json['projectPath'] as String? ?? '',
      path: json['path'] as String? ?? '',
      name: json['name'] as String? ?? '',
      extension: json['extension'] as String?,
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      lastModifiedAt: json['lastModifiedAt'] == null
          ? null
          : DateTime.tryParse('${json['lastModifiedAt']}'),
      readable: json['readable'] != false,
      writable: json['writable'] != false,
      isBinary: json['isBinary'] == true,
      tooLarge: json['tooLarge'] == true,
      content: json['content'] as String?,
    );
  }
}

class ProjectFileUpload {
  ProjectFileUpload({
    required this.fileName,
    required this.bytes,
  });

  final String fileName;
  final Uint8List bytes;
}

class ProjectFileDownload {
  ProjectFileDownload({
    required this.fileName,
    required this.contentType,
    required this.bytes,
  });

  final String fileName;
  final String contentType;
  final Uint8List bytes;
}

class SessionDiffLine {
  SessionDiffLine({
    required this.kind,
    required this.text,
  });

  final String kind;
  final String text;
}

class SessionDiffHunk {
  SessionDiffHunk({
    required this.header,
    required this.lines,
  });

  final String header;
  final List<SessionDiffLine> lines;
}

class SessionDiffFile {
  SessionDiffFile({
    required this.path,
    required this.hunks,
    required this.additions,
    required this.deletions,
  });

  final String path;
  final List<SessionDiffHunk> hunks;
  final int additions;
  final int deletions;
}

class SessionDiffState {
  SessionDiffState({
    required this.rawDiff,
    required this.updatedAt,
    required this.files,
  });

  final String rawDiff;
  final DateTime updatedAt;
  final List<SessionDiffFile> files;
}

class ModelOption {
  ModelOption({
    required this.id,
    required this.displayName,
    required this.capabilities,
    required this.defaultProfileIds,
    required this.supportedReasoningEfforts,
    required this.defaultReasoningEffort,
  });

  final String id;
  final String displayName;
  final List<String> capabilities;
  final List<String> defaultProfileIds;
  final List<String> supportedReasoningEfforts;
  final String defaultReasoningEffort;

  factory ModelOption.fromJson(Map<String, dynamic> json) {
    return ModelOption(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      capabilities:
          (json['capabilities'] as List<dynamic>).map((e) => '$e').toList(),
      defaultProfileIds: (json['defaultProfileIds'] as List<dynamic>)
          .map((e) => '$e')
          .toList(),
      supportedReasoningEfforts:
          (json['supportedReasoningEfforts'] as List<dynamic>? ?? <dynamic>[])
              .map((e) => '$e')
              .toList(),
      defaultReasoningEffort:
          (json['defaultReasoningEffort'] as String?) ?? 'medium',
    );
  }
}

class PermissionProfileOption {
  PermissionProfileOption({
    required this.id,
    required this.name,
  });

  final String id;
  final String name;

  factory PermissionProfileOption.fromJson(Map<String, dynamic> json) {
    return PermissionProfileOption(
      id: json['id'] as String,
      name: json['name'] as String,
    );
  }
}

class CollaborationModeOption {
  CollaborationModeOption({
    required this.id,
    required this.name,
    required this.description,
  });

  final String id;
  final String name;
  final String description;

  factory CollaborationModeOption.fromJson(Map<String, dynamic> json) {
    return CollaborationModeOption(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
    );
  }
}

class RuntimeHealthStatus {
  RuntimeHealthStatus({
    required this.ready,
    required this.message,
  });

  final bool ready;
  final String message;

  factory RuntimeHealthStatus.fromJson(Map<String, dynamic> json) {
    final runtime =
        json['runtime'] as Map<String, dynamic>? ?? <String, dynamic>{};
    final checks = runtime['checks'] as List<dynamic>? ?? <dynamic>[];
    final failedChecks = checks
        .whereType<Map<String, dynamic>>()
        .where((check) => check['ok'] != true)
        .map((check) => '${check['name']}: ${check['message']}')
        .toList();

    final fallback =
        '${runtime['mode'] ?? 'runtime'} (${runtime['transport'] ?? 'unknown'})';
    final message = failedChecks.isNotEmpty
        ? failedChecks.join(' | ')
        : (runtime['error'] as String? ?? fallback);

    return RuntimeHealthStatus(
      ready: json['ready'] == true,
      message: message,
    );
  }
}

class TerminalSessionItem {
  TerminalSessionItem({
    required this.id,
    required this.cwd,
    required this.shell,
    required this.running,
    required this.startedAt,
    required this.endedAt,
  });

  final String id;
  final String cwd;
  final String shell;
  final bool running;
  final DateTime startedAt;
  final DateTime? endedAt;

  factory TerminalSessionItem.fromJson(Map<String, dynamic> json) {
    return TerminalSessionItem(
      id: json['id'] as String? ?? '',
      cwd: json['cwd'] as String? ?? '',
      shell: json['shell'] as String? ?? '',
      running: json['running'] == true,
      startedAt: DateTime.tryParse('${json['startedAt']}') ?? DateTime.now(),
      endedAt: json['endedAt'] == null
          ? null
          : DateTime.tryParse('${json['endedAt']}'),
    );
  }
}

class TerminalSnapshot {
  TerminalSnapshot({
    required this.session,
    required this.output,
  });

  final TerminalSessionItem session;
  final String output;

  factory TerminalSnapshot.fromJson(Map<String, dynamic> json) {
    return TerminalSnapshot(
      session: TerminalSessionItem.fromJson(
        json['session'] as Map<String, dynamic>? ?? <String, dynamic>{},
      ),
      output: json['output'] as String? ?? '',
    );
  }
}

class ChatSession {
  ChatSession({
    required this.id,
    required this.projectId,
    required this.modelId,
    required this.profileId,
    required this.collaborationMode,
    required this.reasoningEffort,
    required this.threadId,
    required this.status,
  });

  final String id;
  final String projectId;
  final String modelId;
  final String profileId;
  final String collaborationMode;
  final String reasoningEffort;
  final String? threadId;
  final String status;

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    return ChatSession(
      id: json['id'] as String,
      projectId: json['projectId'] as String,
      modelId: json['modelId'] as String,
      profileId: json['profileId'] as String,
      collaborationMode: json['collaborationMode'] as String? ?? 'default',
      reasoningEffort: json['reasoningEffort'] as String? ?? 'medium',
      threadId: json['threadId'] as String?,
      status: json['status'] as String,
    );
  }
}

class ResumeSessionResult {
  ResumeSessionResult({
    required this.session,
    required this.messages,
  });

  final ChatSession session;
  final List<ChatMessage> messages;
}

class HistoryThread {
  HistoryThread({
    required this.threadId,
    required this.preview,
    required this.cwd,
    required this.createdAt,
    required this.updatedAt,
    required this.status,
  });

  final String threadId;
  final String preview;
  final String? cwd;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String status;

  factory HistoryThread.fromJson(Map<String, dynamic> json) {
    return HistoryThread(
      threadId: json['threadId'] as String,
      preview: json['preview'] as String? ?? '',
      cwd: json['cwd'] as String?,
      createdAt: DateTime.tryParse('${json['createdAt']}') ?? DateTime.now(),
      updatedAt: DateTime.tryParse('${json['updatedAt']}') ?? DateTime.now(),
      status: json['status'] as String? ?? 'unknown',
    );
  }
}

class HistoryPage {
  HistoryPage({
    required this.data,
    required this.nextCursor,
  });

  final List<HistoryThread> data;
  final String? nextCursor;

  factory HistoryPage.fromJson(Map<String, dynamic> json) {
    return HistoryPage(
      data: (json['data'] as List<dynamic>? ?? <dynamic>[])
          .map((e) => HistoryThread.fromJson(e as Map<String, dynamic>))
          .toList(),
      nextCursor: json['nextCursor'] as String?,
    );
  }
}

class UserInputQuestionOption {
  UserInputQuestionOption({
    required this.label,
    required this.description,
  });

  final String label;
  final String description;

  factory UserInputQuestionOption.fromJson(Map<String, dynamic> json) {
    return UserInputQuestionOption(
      label: json['label'] as String? ?? '',
      description: json['description'] as String? ?? '',
    );
  }
}

class UserInputQuestion {
  UserInputQuestion({
    required this.header,
    required this.id,
    required this.question,
    required this.options,
  });

  final String header;
  final String id;
  final String question;
  final List<UserInputQuestionOption> options;

  factory UserInputQuestion.fromJson(Map<String, dynamic> json) {
    return UserInputQuestion(
      header: json['header'] as String? ?? '',
      id: json['id'] as String? ?? '',
      question: json['question'] as String? ?? '',
      options: (json['options'] as List<dynamic>? ?? <dynamic>[])
          .map((e) =>
              UserInputQuestionOption.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    required this.createdAt,
  });

  final String id;
  final String sessionId;
  final String role;
  final String content;
  final DateTime createdAt;

  ChatMessage copyWith({String? content}) {
    return ChatMessage(
      id: id,
      sessionId: sessionId,
      role: role,
      content: content ?? this.content,
      createdAt: createdAt,
    );
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      sessionId: json['sessionId'] as String,
      role: json['role'] as String,
      content: json['content'] as String,
      createdAt: DateTime.tryParse('${json['createdAt']}') ?? DateTime.now(),
    );
  }
}

class ServerEvent {
  ServerEvent({required this.type, required this.payload});

  final String type;
  final Map<String, dynamic> payload;

  factory ServerEvent.fromJson(Map<String, dynamic> json) {
    return ServerEvent(
      type: json['type'] as String,
      payload:
          (json['payload'] as Map<String, dynamic>? ?? <String, dynamic>{}),
    );
  }
}
