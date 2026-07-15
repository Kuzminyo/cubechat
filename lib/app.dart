import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/ble/background_mode_controller.dart';
import 'core/locale/locale_controller.dart';
import 'core/notifications/notification_service.dart';
import 'core/routing/app_router.dart';
import 'core/transport/messaging_service.dart';
import 'core/util/app_lifecycle.dart';
import 'core/theme/app_theme.dart';
import 'features/chats/data/read_markers_controller.dart';
import 'features/chats/presentation/chats_list_screen.dart';
import 'features/peers/data/known_peers_controller.dart';
import 'l10n/app_localizations.dart';

class CubechatApp extends ConsumerStatefulWidget {
  const CubechatApp({super.key});

  @override
  ConsumerState<CubechatApp> createState() => _CubechatAppState();
}

class _CubechatAppState extends ConsumerState<CubechatApp>
    with WidgetsBindingObserver {
  late final _router = buildRouter();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Seed the foreground flag. didChangeAppLifecycleState only fires on a
    // *transition*, so an app that starts already resumed never gets the
    // callback — isForeground would stay false for the whole session, and
    // AppLifecycle.isViewingChat (foreground && this chat open) could never be
    // true. The visible symptom: notifications for the very chat you're
    // reading, until you background and reopen the app once.
    AppLifecycle.instance.isForeground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    // Route to the conversation when a message notification is tapped.
    NotificationService.instance.onSelectChat = _openChat;
    // Send an inline reply typed into a message notification straight over the
    // mesh, without opening the app.
    NotificationService.instance.onReply = _replyToChat;
    // Cold start via a notification tap: open that chat after first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final payload = await NotificationService.instance.initialChatPayload();
      if (payload != null && payload.isNotEmpty) _openChat(payload);
    });
  }

  /// Opens the chat for [chatId] — a pubkey-hex canonical id, or a `#channel`
  /// name. Resolves the display name from the KnownPeers roster for the header.
  void _openChat(String chatId) {
    // A channel's id starts with '#', which is the URL fragment delimiter and
    // cannot travel in a path. It has its own route.
    if (chatId.startsWith('#')) {
      _router.push(channelRoute(chatId));
      return;
    }
    final known = ref.read(knownPeersControllerProvider)[chatId];
    final name = (known?.displayName.isNotEmpty ?? false)
        ? known!.displayName
        : 'Peer';
    _router.push(
      '/chat/${Uri.encodeComponent(chatId)}'
      '?name=${Uri.encodeQueryComponent(name)}',
    );
  }

  /// Send the text of an inline notification reply to [chatId] — a `#channel`
  /// broadcast or a 1:1 peer send. Best-effort; a send failure is already
  /// surfaced/logged inside the messaging layer.
  void _replyToChat(String chatId, String text) {
    final messaging = ref.read(messagingServiceProvider);
    if (chatId.startsWith('#')) {
      unawaited(messaging.sendChannelText(chatId, text));
    } else {
      unawaited(messaging.sendText(chatId, text));
    }
    // A reply means the user has seen the conversation — clear its badge.
    ref.read(readMarkersControllerProvider.notifier).markRead(chatId);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Track foreground state so the messaging layer only raises a system
    // notification for messages that arrive while the user isn't looking.
    AppLifecycle.instance.isForeground = state == AppLifecycleState.resumed;
    // The engine is pre-warmed in MainApplication, so main() (and this
    // widget) can build while the app is still headless — and Android 12+
    // forbids starting a foreground service from the background. Re-apply
    // background mode whenever we come to the foreground so the service
    // actually starts (or restarts) from an allowed state.
    if (state == AppLifecycleState.resumed) {
      ref.read(backgroundModeProvider.notifier).apply();
      // Coming back into an open chat: whatever piled up for it while we were
      // away has already been read the moment it's on screen.
      final open = AppLifecycle.instance.activeChatId;
      if (open != null) {
        unawaited(NotificationService.instance.clearForChat(open));
        ref.read(readMarkersControllerProvider.notifier).markRead(open);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = ref.watch(localeControllerProvider);
    // Touch the background-mode controller so it builds at startup and applies
    // the persisted preference. (Foreground-service start is (re)triggered on
    // resume above, since a headless start would be blocked.)
    ref.watch(backgroundModeProvider);
    return MaterialApp.router(
      onGenerateTitle: (context) => AppLocalizations.of(context).appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      routerConfig: _router,
    );
  }
}
