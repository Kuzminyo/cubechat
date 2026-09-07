import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../util/platform_info.dart';
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

  /// iOS notification category carrying the Reply action. Registered in [init]
  /// and referenced by every message notification.
  static const _categoryId = 'cubechat_message';

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
    // The silhouette, not the launcher icon.
    //
    // Android draws a notification's small icon from its alpha channel alone:
    // every opaque pixel becomes the accent colour, everything else is
    // nothing. A launcher icon is opaque all over, so it arrives as a filled
    // square — reported as a black square in the shade on MIUI, which is
    // precisely what it is rather than a bug in the phone.
    //
    // `ic_notification` is the cube's outline with everything else
    // transparent, at the five densities Android asks for. Built by
    // tool/build_notification_icon.py, which is also where the reasoning about
    // the shape lives — the facets cannot survive a silhouette, so what ships
    // is the hexagon they sit in.
    const android = AndroidInitializationSettings('@drawable/ic_notification');
    // Triggers the iOS system permission prompt on first launch (init() runs
    // unconditionally from main(), before runApp). Without this the app never
    // asks — local notifications are silently dropped and there is nothing for
    // the user to grant from Settings, since iOS only surfaces a
    // Notifications entry for an app once it has requested authorization at
    // least once.
    //
    // The category has to be registered here for [_categoryId] (which every
    // message notification already carried) to mean anything: on iOS an
    // unregistered identifier just yields a banner with no buttons, so the
    // Reply box Android has had all along was missing. Same action id on both
    // platforms, so [_onResponse] handles either one.
    // Not const: DarwinNotificationAction.text is a factory.
    final ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
      notificationCategories: <DarwinNotificationCategory>[
        DarwinNotificationCategory(
          _categoryId,
          actions: <DarwinNotificationAction>[
            DarwinNotificationAction.text(
              _replyActionId,
              'Reply',
              buttonTitle: 'Send',
              placeholder: 'Message',
            ),
          ],
        ),
      ],
    );
    try {
      await _plugin.initialize(
        InitializationSettings(android: android, iOS: ios),
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
  /// Whether the phone should stay quiet at a given moment.
  ///
  /// A function rather than a flag, and set from outside: this service is
  /// called from the transport with no widget tree and no Riverpod around it,
  /// and the window it has to answer against is a user setting. See
  /// `QuietHoursController`, which installs it.
  ///
  /// Silences the notification only. The message is delivered, stored and
  /// unread in the morning either way — a quiet setting that dropped messages
  /// would be a bug wearing a setting's clothes.
  bool Function(DateTime)? quietNow;

  Future<void> showMessage({
    required String threadKey,
    required String title,
    required String body,
    String? senderId,
    bool isGroup = false,
  }) async {
    if (!_ready) await init();
    if (!_ready) return;
    // Quiet hours. The thread is not even opened: nothing here is worth doing
    // for a banner that will not be raised.
    if (quietNow?.call(DateTime.now()) ?? false) return;

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
      iOS: DarwinNotificationDetails(
        // One thread per conversation, not one for the whole app.
        //
        // iOS stacks notifications that share a thread identifier, so a single
        // constant here put every person into the same pile — three people
        // writing looked like one conversation, and the stack had to be opened
        // to find out who. Android has always grouped per chat, through
        // `MessagingStyle` above; this is the same idea said in the way iOS
        // understands.
        //
        // The push that arrives while the app is closed cannot do this and
        // will not: the server sending it knows only that some npub has mail,
        // never whose. That is deliberate, and it is why those still stack
        // together under one heading.
        threadIdentifier: threadKey,
        categoryIdentifier: _categoryId,
        // The number on the app icon, and the reason it never moved before:
        // nothing was setting it. Android has carried a count per conversation
        // since this was written (`number:` above, the figure Telegram shows
        // beside a chat); iOS puts its count on the icon instead, and the icon
        // said nothing at all.
        //
        // Summed across conversations because that is what the icon means on
        // iOS — one number for the whole app, not one per chat. `clearForChat`
        // drops a thread when its chat is opened, so reading takes the badge
        // down the same way arriving put it up.
        badgeNumber: _unreadTotal,
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
      unawaited(_dismissDoorbell());
    } catch (e) {
      debugPrint('NotificationService.showMessage failed: $e');
    }
  }

  /// Take down the generic "New message" banner FCM drew for this.
  ///
  /// Android keeps the process alive behind a foreground service, so on a phone
  /// where that survives, both halves fire for one message: the doorbell rings
  /// (the server has no idea the app is running) and the app itself then shows
  /// the real notification, with the sender's name, their face and the text.
  /// Two banners, one message.
  ///
  /// The real one wins. The placeholder is cancelled by the tag the server
  /// stamps on it — `android.notification.tag` in `sendFcm`, and the two must
  /// stay in step — which is a thing only the native side can do, because a
  /// notification posted by another component is not `flutter_local_
  /// notifications`' to cancel.
  ///
  /// Twice, because the order is not fixed: the relay usually beats Google, but
  /// not always, and a banner that arrives four seconds after the one it
  /// duplicates would otherwise stay. Cancelling a tag that holds nothing costs
  /// a binder call and does nothing visible.
  ///
  /// iOS has no equivalent and needs none: a terminated app is the only case
  /// where APNs delivers, and a terminated app draws nothing of its own.
  Future<void> _dismissDoorbell() async {
    if (!PlatformInfo.isAndroid) return;
    for (final delay in const <Duration>[Duration.zero, Duration(seconds: 4)]) {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      try {
        await _badgeChannel.invokeMethod<void>('dismissDoorbell');
      } on MissingPluginException {
        // A build whose native half predates this. The duplicate stays; it is
        // the same banner the user would have had with no push at all.
        return;
      } catch (e) {
        debugPrint('dismissDoorbell failed: $e');
        return;
      }
    }
  }

  /// Everything waiting across every conversation — what the iOS icon shows.
  int get _unreadTotal =>
      _threads.values.fold(0, (sum, t) => sum + t.inboundCount);

  /// Clears any banner for a chat — called when the user opens that chat. Also
  /// forgets the thread history so a later message starts a fresh conversation.
  Future<void> clearForChat(String threadKey) async {
    _threads.remove(threadKey);
    try {
      await _plugin.cancel(threadKey.hashCode & 0x7fffffff);
    } catch (_) {}
    // The badge does not follow a cancelled banner on iOS — it is a separate
    // number the app owns, and a count that only ever climbs is worse than no
    // count, because it stops meaning anything within a day.
    await _syncBadge();
  }

  /// Push the running total to the app icon.
  ///
  /// `flutter_local_notifications` can only set a badge as part of *showing*
  /// something, which is no use for the moment a chat is read and the number
  /// should fall. This is the one call that does it on its own.
  Future<void> _syncBadge() async {
    if (!PlatformInfo.isIOS) return;
    try {
      await _badgeChannel.invokeMethod<void>('setBadge', _unreadTotal);
    } on MissingPluginException {
      // A build whose native half predates this. The count simply does not
      // move; nothing else is affected.
    } catch (e) {
      debugPrint('NotificationService badge failed: $e');
    }
  }

  static const _badgeChannel = MethodChannel('cubechat/push');

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
