import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/app_models.dart';

class ChatSocketService {
  WebSocketChannel? _channel;
  final StreamController<ServerEvent> _eventController =
      StreamController<ServerEvent>.broadcast();

  Stream<ServerEvent> get events => _eventController.stream;

  bool get isConnected => _channel != null;

  void connect({required String baseWsUrl, required String token}) {
    if (_channel != null) {
      return;
    }

    final uri = Uri.parse('$baseWsUrl/ws?token=$token');
    _channel = WebSocketChannel.connect(uri);

    _channel!.stream.listen(
      (dynamic event) {
        if (event is! String) {
          return;
        }

        final decoded = jsonDecode(event) as Map<String, dynamic>;
        _eventController.add(ServerEvent.fromJson(decoded));
      },
      onError: (Object error, StackTrace stackTrace) {
        _eventController.add(
          ServerEvent(
            type: 'error',
            payload: <String, dynamic>{
              'code': 'socket_error',
              'message': '$error',
            },
          ),
        );
      },
      onDone: disconnect,
      cancelOnError: false,
    );
  }

  void disconnect() {
    _channel?.sink.close();
    _channel = null;
  }

  void subscribeSession(String sessionId) {
    _sendEvent('session.subscribe', <String, dynamic>{'sessionId': sessionId});
  }

  void unsubscribeSession(String sessionId) {
    _sendEvent(
        'session.unsubscribe', <String, dynamic>{'sessionId': sessionId});
  }

  void subscribeTerminal(String terminalId) {
    _sendEvent(
      'terminal.subscribe',
      <String, dynamic>{'terminalId': terminalId},
    );
  }

  void unsubscribeTerminal(String terminalId) {
    _sendEvent(
      'terminal.unsubscribe',
      <String, dynamic>{'terminalId': terminalId},
    );
  }

  void sendTerminalInput({
    required String terminalId,
    required String input,
  }) {
    _sendEvent(
      'terminal.input',
      <String, dynamic>{
        'terminalId': terminalId,
        'input': input,
      },
    );
  }

  void sendTerminalResize({
    required String terminalId,
    required int cols,
    required int rows,
  }) {
    _sendEvent(
      'terminal.resize',
      <String, dynamic>{
        'terminalId': terminalId,
        'cols': cols,
        'rows': rows,
      },
    );
  }

  void sendMessage({required String sessionId, required String content}) {
    _sendEvent(
      'message.send',
      <String, dynamic>{
        'sessionId': sessionId,
        'content': content,
      },
    );
  }

  void interruptSession(String sessionId) {
    _sendEvent('session.interrupt', <String, dynamic>{'sessionId': sessionId});
  }

  void respondPermission({
    required String sessionId,
    required String requestId,
    required bool approved,
  }) {
    _sendEvent(
      'permission.response',
      <String, dynamic>{
        'sessionId': sessionId,
        'requestId': requestId,
        'approved': approved,
      },
    );
  }

  void respondUserInput({
    required String sessionId,
    required String requestId,
    required Map<String, Map<String, List<String>>> answers,
  }) {
    _sendEvent(
      'user.input.respond',
      <String, dynamic>{
        'sessionId': sessionId,
        'requestId': requestId,
        'answers': answers,
      },
    );
  }

  void _sendEvent(String type, Map<String, dynamic> payload) {
    final channel = _channel;
    if (channel == null) {
      return;
    }

    channel.sink.add(
      jsonEncode(
        <String, dynamic>{
          'type': type,
          'payload': payload,
        },
      ),
    );
  }

  Future<void> dispose() async {
    disconnect();
    await _eventController.close();
  }
}
