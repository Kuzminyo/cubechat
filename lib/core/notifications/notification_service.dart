import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'avatar_bitmap.dart';

/// Rich incoming-message notifications built on flutter_local_notifications.
///
/// Uses Android `MessagingStyle` so a chat's alerts read like a real messenger:
/// the sender's name + identity avatar, a running list of their recent lines
/// under one banner, an unread count, and an inline **Reply** box that sends
/// straight back over the mesh without opening the app. Works headless (from the
/// pre-warmed background engine) since it's all platform-channel calls.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const _channelId = 'cubechat_messages';
  static const _channelName = 'Messages';
  static const _groupKey = 'cubechat.messages';
  static const _replyActionId = 'cubechat_reply';

  /// How many recent lines we keep per conversation for the MessagingStyle
  /// history. Enough to show a burst as a thread, bounded so memory can't grow.
  static const _maxThreadMessages = 8;

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  /// The local user, shown as the author of sent (reply) lines in the thread.
  static const _me = Person(name: 'You', key: 'me');

  /// Per-conversation state so a MessagingStyle notification can show a running
  /// history and a stable sender avatar. Keyed by threadKey (chat id).
  final Map<String, _Thread> _threads = {};

  /// Set by the app: called with the chat id (payload) when a message
  /// notification is tapped, so we can route to that conversation.
  void Function(String chatId)? onSelectChat;

  /// Set by the app: called with (chatId, text) when the user submits the
  /// inline reply. Routed back into the messaging layer to actually send.
  void Function(String chatId, String text)? onReply;

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
        onDidReceiveNotificationResponse: _onResponse,
      );
      // Pre-create the channel so the first notification appears instantly with
      // the right importance + alerting (sound + vibration).
      const channel = AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: 'Incoming cubechat messages',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
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

  /// Handles a tap or an inline-reply submission on a message notification.
  void _onResponse(NotificationResponse resp) {
    final chatId = resp.payload;
    if (chatId == null || chatId.isEmpty) return;
    if (resp.actionId == _replyActionId) {
      final text = resp.input?.trim();
      if (text != null && text.isNotEmpty) {
        // Echo the sent line into the thread history so a follow-up banner keeps
        // context, then hand off to the app to actually send it.
        _threads[chatId]?.add(text, _me);
        onReply?.call(chatId, text);
      }
      return;
    }
    onSelectChat?.call(chatId);
  }

  /// Show an incoming-message notification. [threadKey] (the chat id) groups a
  /// sender's alerts under one MessagingStyle banner; [senderId] seeds the
  /// avatar (defaults to [threadKey]); [isGroup] renders channel alerts as a
  /// group conversation titled after the channel.
  Future<void> showMessage({
    required String threadKey,
    required String title,
    required String body,
    String? senderId,
    bool isGroup = false,
  }) async {
    if (!_ready) await init();
    if (!_ready) return;

    final thread = _threads.putIfAbsent(threadKey, () => _Thread());
    // Build (once) a stable avatar for this sender.
    thread.icon ??= await renderAvatarPng(
      seed: senderId ?? threadKey,
      label: title,
    );
    final sender = Person(
      key: threadKey,
      name: title,
      icon: thread.icon == null ? null : ByteArrayAndroidIcon(thread.icon!),
    );
    thread.add(body, sender, cap: _maxThreadMessages);

    final messaging = MessagingStyleInformation(
      _me,
      conversationTitle: isGroup ? title : null,
      groupConversation: isGroup,
      messages: thread.messages,
    );

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: 'Incoming cubechat messages',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.message,
        styleInformation: messaging,
        groupKey: _groupKey,
        number: thread.inboundCount,
        actions: <AndroidNotificationAction>[
          const AndroidNotificationAction(
            _replyActionId,
            'Reply',
            allowGeneratedReplies: true,
            showsUserInterface: false,
            cancelNotification: false,
            inputs: <AndroidNotificationActionInput>[
              AndroidNotificationActionInput(label: 'Message'),
            ],
          ),
        ],
      ),
      iOS: const DarwinNotificationDetails(
        threadIdentifier: 'cubechat',
        categoryIdentifier: 'cubechat_message',
      ),
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

  /// Clears any banner for a chat — called when the user opens that chat. Also
  /// forgets the thread history so a later message starts a fresh conversation.
  Future<void> clearForChat(String threadKey) async {
    _threads.remove(threadKey);
    try {
      await _plugin.cancel(threadKey.hashCode & 0x7fffffff);
    } catch (_) {}
  }

  /// If the app was launched by tapping a notification (cold start), returns
  /// that notification's chat-id payload so the app can open the chat.
  Future<String?> initialChatPayload() async {
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp ?? false) {
        return details?.notificationResponse?.payload;
      }
    } catch (_) {}
    return null;
  }
}

/// Recent lines for one conversation, feeding the MessagingStyle history.
class _Thread {
  final List<Message> messages = [];
  Uint8List? icon;
  int inboundCount = 0;

  void add(String text, Person person, {int cap = 8}) {
    // A null person key means "me" (a sent reply); anything else is inbound.
    if (person.key != 'me') inboundCount++;
    messages.add(Message(text, DateTime.now(), person));
    if (messages.length > cap) {
      messages.removeRange(0, messages.length - cap);
    }
  }
}
