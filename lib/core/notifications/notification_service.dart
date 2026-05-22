import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Thin wrapper around flutter_local_notifications for incoming-message
/// alerts. Works headless (from the cached background engine) since it's a
/// platform-channel call — no UI required.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const _channelId = 'cubechat_messages';
  static const _channelName = 'Messages';

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    try {
      await _plugin.initialize(
        const InitializationSettings(android: android, iOS: ios),
      );
      // Pre-create the channel so the first notification appears instantly
      // with the right importance.
      const channel = AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: 'Incoming cubechat messages',
        importance: Importance.high,
      );
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);
      _ready = true;
    } catch (e) {
      debugPrint('NotificationService.init failed: $e');
    }
  }

  /// Show an incoming-message notification. [threadKey] (the chat id) groups
  /// repeated alerts from the same sender under one stable notification id so
  /// a burst of messages doesn't spawn a stack of separate banners.
  Future<void> showMessage({
    required String threadKey,
    required String title,
    required String body,
  }) async {
    if (!_ready) await init();
    if (!_ready) return;
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: 'Incoming cubechat messages',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.message,
      ),
      iOS: DarwinNotificationDetails(),
    );
    try {
      await _plugin.show(
        threadKey.hashCode & 0x7fffffff,
        title,
        body,
        details,
        payload: threadKey,
      );
    } catch (e) {
      debugPrint('NotificationService.showMessage failed: $e');
    }
  }

  /// Clears any banner for a chat — called when the user opens that chat.
  Future<void> clearForChat(String threadKey) async {
    try {
      await _plugin.cancel(threadKey.hashCode & 0x7fffffff);
    } catch (_) {}
  }
}
