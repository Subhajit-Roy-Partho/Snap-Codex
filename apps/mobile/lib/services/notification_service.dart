import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/app_models.dart';
import 'api_client.dart';

class NotificationService {
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _nextNotificationId =
      DateTime.now().millisecondsSinceEpoch.remainder(0x7fffffff);

  Future<void> initialize(ApiClient apiClient) async {
    if (!_ready) {
      const androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosSettings = DarwinInitializationSettings();

      await _localNotifications.initialize(
        const InitializationSettings(
          android: androidSettings,
          iOS: iosSettings,
        ),
      );

      await _localNotifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }

    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      final pushToken = await messaging.getToken();
      if (pushToken != null) {
        await apiClient.registerPushToken(
          pushToken: pushToken,
          platform: Platform.isIOS ? 'ios' : 'android',
        );
      }

      if (!_ready) {
        FirebaseMessaging.onMessage.listen((RemoteMessage message) {
          _showLocal(
            title: message.notification?.title ?? 'Codex event',
            body: message.notification?.body ?? 'You have a new event.',
          );
        });
      }
    } catch (_) {
      // Firebase can be unavailable in local/dev environments.
    }

    _ready = true;
  }

  Future<void> notifyFromEvent(ServerEvent event) async {
    if (!_ready) {
      return;
    }

    final payload = event.payload;
    final (title, body) = switch (event.type) {
      'session.state.changed' => (
          'Task status',
          'Session ${payload['sessionId']}: ${payload['status']}',
        ),
      'user.input.requested' => (
          'Input required',
          'Codex is waiting for your answer.',
        ),
      'permission.requested' => (
          'Permission required',
          '${payload['prompt'] ?? 'Codex needs approval.'}',
        ),
      'message.completed' => (
          'Codex replied',
          _summarize(event),
        ),
      _ => (
          'Codex ${event.type}',
          _summarize(event),
        ),
    };

    await _showLocal(
      title: title,
      body: body,
    );
  }

  Future<void> _showLocal({required String title, required String body}) async {
    const androidDetails = AndroidNotificationDetails(
      'codex_events',
      'Codex Events',
      channelDescription: 'All Codex server events',
      importance: Importance.max,
      priority: Priority.high,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(),
    );

    _nextNotificationId = (_nextNotificationId + 1).remainder(0x7fffffff);

    await _localNotifications.show(
      _nextNotificationId,
      title,
      body,
      details,
    );
  }

  String _summarize(ServerEvent event) {
    if (event.type == 'message.completed') {
      final text = '${event.payload['role']}: ${event.payload['content']}';
      return text.length > 80 ? '${text.substring(0, 80)}...' : text;
    }

    if (event.type == 'error') {
      return '${event.payload['message']}';
    }

    return event.payload.toString();
  }
}
