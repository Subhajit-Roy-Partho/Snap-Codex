import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/app_models.dart';

class ApiClient {
  ApiClient({required this.baseUrl, required this.token});

  final String baseUrl;
  final String token;

  Map<String, String> get _headers => <String, String>{
        'content-type': 'application/json',
        'x-api-token': token,
      };

  String _extractErrorMessage(http.Response response, String fallback) {
    final status = response.statusCode;
    final rawBody = response.body.trim();
    if (rawBody.isEmpty) {
      return '$fallback (HTTP $status)';
    }

    try {
      final parsed = jsonDecode(rawBody);
      if (parsed is Map<String, dynamic>) {
        final error = parsed['error'];
        if (error is String && error.trim().isNotEmpty) {
          return '$fallback: ${error.trim()}';
        }

        if (error != null) {
          return '$fallback: ${jsonEncode(error)}';
        }
      }
    } catch (_) {
      // Fall through to raw body.
    }

    return '$fallback (HTTP $status): $rawBody';
  }

  Future<String> verifyToken() async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/token/verify'),
      headers: const <String, String>{'content-type': 'application/json'},
      body: jsonEncode(<String, dynamic>{'token': token}),
    );

    if (response.statusCode != 200) {
      throw Exception('Token verification failed');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return '${body['jwt']}';
  }

  Future<List<ProjectItem>> fetchProjects() async {
    final response =
        await http.get(Uri.parse('$baseUrl/projects'), headers: _headers);
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch projects');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['projects'] as List<dynamic>)
        .map((e) => ProjectItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<String>> fetchProjectRoots() async {
    final response =
        await http.get(Uri.parse('$baseUrl/project-roots'), headers: _headers);
    if (response.statusCode != 200) {
      throw Exception(
          _extractErrorMessage(response, 'Failed to fetch project roots'));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['roots'] as List<dynamic>? ?? <dynamic>[])
        .map((dynamic entry) => '$entry')
        .toList();
  }

  Future<ProjectRootsResult> addProjectRoot(String folderPath) async {
    final response = await http.post(
      Uri.parse('$baseUrl/project-roots'),
      headers: _headers,
      body: jsonEncode(<String, dynamic>{
        'path': folderPath,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(
          _extractErrorMessage(response, 'Failed to add project root'));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ProjectRootsResult(
      roots: (body['roots'] as List<dynamic>? ?? <dynamic>[])
          .map((dynamic entry) => '$entry')
          .toList(),
      projects: (body['projects'] as List<dynamic>? ?? <dynamic>[])
          .map((dynamic entry) =>
              ProjectItem.fromJson(entry as Map<String, dynamic>))
          .toList(),
    );
  }

  Future<DirectoryBrowseResult> browseDirectories({
    required String path,
    int limit = 200,
  }) async {
    final uri = Uri.parse('$baseUrl/fs/dirs').replace(
      queryParameters: <String, String>{
        'path': path,
        'limit': '$limit',
      },
    );

    final response = await http.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw Exception(
          _extractErrorMessage(response, 'Failed to browse directories'));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return DirectoryBrowseResult.fromJson(body);
  }

  Future<List<String>> suggestDirectories({
    required String query,
    String? basePath,
    int limit = 20,
  }) async {
    final uri = Uri.parse('$baseUrl/fs/dir-suggest').replace(
      queryParameters: <String, String>{
        'query': query,
        if (basePath != null && basePath.trim().isNotEmpty)
          'base': basePath.trim(),
        'limit': '$limit',
      },
    );

    final response = await http.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw Exception(
          _extractErrorMessage(response, 'Failed to suggest directories'));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['suggestions'] as List<dynamic>? ?? <dynamic>[])
        .map((dynamic entry) => '$entry')
        .toList();
  }

  Future<ProjectFileListing> fetchProjectFiles({
    required String projectId,
    String path = '',
    int limit = 400,
  }) async {
    final uri = Uri.parse('$baseUrl/projects/$projectId/files').replace(
      queryParameters: <String, String>{
        'path': path,
        'limit': '$limit',
      },
    );

    final response = await http.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw Exception(
        _extractErrorMessage(response, 'Failed to load project files'),
      );
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ProjectFileListing.fromJson(body);
  }

  Future<ProjectFileDocument> fetchProjectFile({
    required String projectId,
    required String path,
  }) async {
    final uri = Uri.parse('$baseUrl/projects/$projectId/files/content').replace(
      queryParameters: <String, String>{'path': path},
    );

    final response = await http.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw Exception(
        _extractErrorMessage(response, 'Failed to open file'),
      );
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ProjectFileDocument.fromJson(body);
  }

  Future<ProjectFileDocument> saveProjectFile({
    required String projectId,
    required String path,
    required String content,
  }) async {
    final response = await http.put(
      Uri.parse('$baseUrl/projects/$projectId/files/content'),
      headers: _headers,
      body: jsonEncode(<String, dynamic>{
        'path': path,
        'content': content,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(
        _extractErrorMessage(response, 'Failed to save file'),
      );
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ProjectFileDocument.fromJson(body);
  }

  Future<ProjectFileEntry> uploadProjectFile({
    required String projectId,
    required String directoryPath,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/projects/$projectId/files/upload'),
      headers: _headers,
      body: jsonEncode(<String, dynamic>{
        'directoryPath': directoryPath,
        'fileName': fileName,
        'contentBase64': base64Encode(bytes),
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(
        _extractErrorMessage(response, 'Failed to upload file'),
      );
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ProjectFileEntry.fromJson(
      body['file'] as Map<String, dynamic>? ?? <String, dynamic>{},
    );
  }

  Future<ProjectFileDownload> downloadProjectFile({
    required String projectId,
    required String path,
  }) async {
    final uri =
        Uri.parse('$baseUrl/projects/$projectId/files/download').replace(
      queryParameters: <String, String>{'path': path},
    );
    final response = await http.get(
      uri,
      headers: <String, String>{'x-api-token': token},
    );

    if (response.statusCode != 200) {
      throw Exception(
        _extractErrorMessage(response, 'Failed to download file'),
      );
    }

    final fileName = response.headers['x-codex-file-name'] ??
        path.split('/').where((segment) => segment.isNotEmpty).last;

    return ProjectFileDownload(
      fileName: fileName,
      contentType:
          response.headers['content-type'] ?? 'application/octet-stream',
      bytes: response.bodyBytes,
    );
  }

  Future<List<ModelOption>> fetchModels() async {
    final response =
        await http.get(Uri.parse('$baseUrl/models'), headers: _headers);
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch models');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['models'] as List<dynamic>)
        .map((e) => ModelOption.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<PermissionProfileOption>> fetchProfiles() async {
    final response =
        await http.get(Uri.parse('$baseUrl/profiles'), headers: _headers);
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch profiles');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['profiles'] as List<dynamic>)
        .map((e) => PermissionProfileOption.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<CollaborationModeOption>> fetchCollaborationModes() async {
    final response = await http.get(
      Uri.parse('$baseUrl/collaboration-modes'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch collaboration modes');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['modes'] as List<dynamic>)
        .map((e) => CollaborationModeOption.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<RuntimeHealthStatus> fetchHealthStatus() async {
    final response = await http.get(Uri.parse('$baseUrl/health'));
    if (response.statusCode != 200 && response.statusCode != 503) {
      throw Exception('Failed to fetch health status');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return RuntimeHealthStatus.fromJson(body);
  }

  Future<List<ChatSession>> fetchSessions() async {
    final response =
        await http.get(Uri.parse('$baseUrl/sessions'), headers: _headers);
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch sessions');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['sessions'] as List<dynamic>)
        .map((e) => ChatSession.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<TerminalSessionItem>> fetchTerminalSessions() async {
    final response = await http.get(
      Uri.parse('$baseUrl/terminal/sessions'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw Exception(
          _extractErrorMessage(response, 'Failed to fetch terminal sessions'));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['sessions'] as List<dynamic>? ?? <dynamic>[])
        .map((dynamic e) =>
            TerminalSessionItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<TerminalSnapshot> createTerminalSession({
    String? cwd,
    String? shell,
    List<String>? bootstrap,
    int? cols,
    int? rows,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/terminal/sessions'),
      headers: _headers,
      body: jsonEncode(<String, dynamic>{
        if (cwd != null && cwd.trim().isNotEmpty) 'cwd': cwd.trim(),
        if (shell != null && shell.trim().isNotEmpty) 'shell': shell.trim(),
        if (bootstrap != null && bootstrap.isNotEmpty)
          'bootstrap': bootstrap.map((entry) => entry.trim()).toList(),
        if (cols != null) 'cols': cols,
        if (rows != null) 'rows': rows,
      }),
    );
    if (response.statusCode != 200) {
      throw Exception(
          _extractErrorMessage(response, 'Failed to create terminal session'));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return TerminalSnapshot.fromJson(body);
  }

  Future<TerminalSnapshot> fetchTerminalSnapshot(String terminalId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/terminal/sessions/$terminalId'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw Exception(
          _extractErrorMessage(response, 'Failed to fetch terminal session'));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return TerminalSnapshot.fromJson(body);
  }

  Future<void> sendTerminalInput({
    required String terminalId,
    required String input,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/terminal/sessions/$terminalId/input'),
      headers: _headers,
      body: jsonEncode(<String, dynamic>{
        'input': input,
      }),
    );
    if (response.statusCode != 200) {
      throw Exception(
          _extractErrorMessage(response, 'Failed to send terminal input'));
    }
  }

  Future<void> closeTerminalSession(String terminalId) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/terminal/sessions/$terminalId'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw Exception(
          _extractErrorMessage(response, 'Failed to close terminal session'));
    }
  }

  Future<void> resizeTerminalSession({
    required String terminalId,
    required int cols,
    required int rows,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/terminal/sessions/$terminalId/resize'),
      headers: _headers,
      body: jsonEncode(<String, dynamic>{
        'cols': cols,
        'rows': rows,
      }),
    );
    if (response.statusCode != 200) {
      throw Exception(
          _extractErrorMessage(response, 'Failed to resize terminal session'));
    }
  }

  Future<ChatSession> createSession({
    required String projectId,
    required String modelId,
    required String profileId,
    required String reasoningEffort,
    required String collaborationMode,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/sessions'),
      headers: _headers,
      body: jsonEncode(<String, dynamic>{
        'projectId': projectId,
        'modelId': modelId,
        'profileId': profileId,
        'reasoningEffort': reasoningEffort,
        'collaborationMode': collaborationMode,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to create session: ${response.body}');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ChatSession.fromJson(body['session'] as Map<String, dynamic>);
  }

  Future<ResumeSessionResult> resumeSession({
    required String threadId,
    required String projectId,
    required String modelId,
    required String profileId,
    required String reasoningEffort,
    required String collaborationMode,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/sessions/resume'),
      headers: _headers,
      body: jsonEncode(<String, dynamic>{
        'threadId': threadId,
        'projectId': projectId,
        'modelId': modelId,
        'profileId': profileId,
        'reasoningEffort': reasoningEffort,
        'collaborationMode': collaborationMode,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(
          _extractErrorMessage(response, 'Failed to resume session'));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final messages = (body['messages'] as List<dynamic>? ?? <dynamic>[])
        .map((dynamic item) =>
            ChatMessage.fromJson(item as Map<String, dynamic>))
        .toList();

    return ResumeSessionResult(
      session: ChatSession.fromJson(body['session'] as Map<String, dynamic>),
      messages: messages,
    );
  }

  Future<HistoryPage> fetchHistory({
    String? cwd,
    String? cursor,
    int limit = 20,
  }) async {
    final params = <String, String>{
      'limit': '$limit',
      if (cwd != null && cwd.trim().isNotEmpty) 'cwd': cwd.trim(),
      if (cursor != null && cursor.trim().isNotEmpty) 'cursor': cursor.trim(),
    };
    final uri = Uri.parse('$baseUrl/history').replace(queryParameters: params);
    final response = await http.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch history');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return HistoryPage.fromJson(body);
  }

  Future<ChatSession> fetchSession(String sessionId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/sessions/$sessionId'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw Exception(
          _extractErrorMessage(response, 'Failed to fetch session'));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ChatSession.fromJson(body['session'] as Map<String, dynamic>);
  }

  Future<List<ChatMessage>> fetchMessages(String sessionId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/sessions/$sessionId/messages'),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to fetch messages');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['messages'] as List<dynamic>)
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ChatMessage> sendMessage({
    required String sessionId,
    required String content,
    bool requestPermission = false,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/sessions/$sessionId/messages'),
      headers: _headers,
      body: jsonEncode(<String, dynamic>{
        'content': content,
        'requestPermission': requestPermission,
      }),
    );

    if (response.statusCode != 202) {
      throw Exception(_extractErrorMessage(response, 'Failed to send message'));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ChatMessage.fromJson(body['message'] as Map<String, dynamic>);
  }

  Future<void> sendAction({
    required String sessionId,
    required String action,
    String? requestId,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/sessions/$sessionId/actions'),
      headers: _headers,
      body: jsonEncode(<String, dynamic>{
        'action': action,
        if (requestId != null) 'requestId': requestId,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(
          _extractErrorMessage(response, 'Failed to send session action'));
    }
  }

  Future<void> registerPushToken({
    required String pushToken,
    required String platform,
  }) async {
    await http.post(
      Uri.parse('$baseUrl/devices/push-token'),
      headers: _headers,
      body: jsonEncode(<String, dynamic>{
        'token': pushToken,
        'platform': platform,
      }),
    );
  }
}
