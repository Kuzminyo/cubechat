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
import 'core/util/platform_info.dart';
import 'core/util/ui_activity.dart';
import 'features/chat/presentation/widgets/voice_mini_player.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'features/chats/data/read_markers_controller.dart';
import 'features/chats/presentation/chats_list_screen.dart';
import 'features/peers/data/known_peers_controller.dart';
import 'features/peers/data/peer_discovery_controller.dart';
import 'features/profile/data/ui_scale_controller.dart';
import 'l10n/app_localizations.dart';

class CubechatApp extends ConsumerStatefulWidget {
  const CubechatApp({super.key, this.seenOnboarding = true});

  /// Read off disk before the first frame, so a first run opens on the intro
  /// instead of flashing the chats list and redirecting away from it.
  final bool seenOnboarding;

  @override
  ConsumerState<CubechatApp> createState() => _CubechatAppState();
}

class _CubechatAppState extends ConsumerState<CubechatApp>
    with WidgetsBindingObserver {
  late final _router = buildRouter(seenOnboarding: widget.seenOnboarding);

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
    final name =
        (known?.displayName.isNotEmpty ?? false) ? known!.displayName : 'Peer';
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

  /// Pending "I'm gone" beacon — see [_announcePresenceDebounced].
  Timer? _goodbyeTimer;

  /// What our contacts currently believe. Starts true because the app is in the
  /// foreground when this observer is installed.
  bool _announcedOnline = true;

  /// How long the app has to come back before its contacts are told it left.
  ///
  /// `inactive` was already excluded for this reason, but Android reports a
  /// full `paused` for the file picker, the camera and the share sheet — so a
  /// tester sending one screenshot produced goodbye/hello pairs seconds apart,
  /// each fanning out to every contact on every relay. Their own log shows the
  /// result: presence flipping four times in fifteen seconds, and
  /// `rate-limited: you are noting too much` on nearly every publish, which
  /// then also refused the file they were trying to send.
  ///
  /// Long enough to cover picking a file, short enough that genuinely leaving
  /// still shows up promptly.
  static const Duration _goodbyeGrace = Duration(seconds: 6);

  void _announcePresenceDebounced({required bool online}) {
    _goodbyeTimer?.cancel();
    _goodbyeTimer = null;

    if (online) {
      // Coming back before the grace ran out means nobody was ever told we
      // left, so there is nothing to correct — staying quiet is the whole
      // point.
      if (_announcedOnline) return;
      _announcedOnline = true;
      unawaited(
        ref.read(messagingServiceProvider).announcePresence(online: true),
      );
      return;
    }

    _goodbyeTimer = Timer(_goodbyeGrace, () {
      _goodbyeTimer = null;
      if (!mounted || !_announcedOnline) return;
      _announcedOnline = false;
      unawaited(
        ref.read(messagingServiceProvider).announcePresence(online: false),
      );
    });
  }

  @override
  void dispose() {
    _goodbyeTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Track foreground state so the messaging layer only raises a system
    // notification for messages that arrive while the user isn't looking.
    AppLifecycle.instance.isForeground = state == AppLifecycleState.resumed;
    _applyIosBackgroundPolicy(resumed: state == AppLifecycleState.resumed);
    // Tell internet-reachable peers we've arrived / are leaving, so their "in
    // the app" dot flips now instead of waiting out the heartbeat. The goodbye
    // is best-effort by nature — the OS can kill us without another callback —
    // which is why the beacon also carries a TTL on the receiving side.
    //
    // Only the two states that actually mean something. `inactive` is the
    // transient step the OS passes through whenever anything covers the app for
    // a moment — the camera, the photo picker, the share sheet, the notification
    // shade — and treating it as "left the app" made every one of those emit a
    // goodbye and then a hello, each fanning out to every peer on every relay.
    // On a real device that read as a burst several times a second and earned a
    // `rate-limited: you are noting too much` from the relays, which then
    // rejected real messages too.
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.paused) {
      _announcePresenceDebounced(
        online: state == AppLifecycleState.resumed,
      );
    }
    // The engine is pre-warmed in MainApplication, so main() (and this
    // widget) can build while the app is still headless — and Android 12+
    // forbids starting a foreground service from the background. Re-apply
    // background mode whenever we come to the foreground so the service
    // actually starts (or restarts) from an allowed state.
    if (state == AppLifecycleState.resumed) {
      ref.read(backgroundModeProvider.notifier).apply();
      // The BLE scan cadence is picked when a window opens, so coming back
      // mid-idle-cycle would leave discovery sluggish for up to 30 s with the
      // user looking straight at the Nearby list. Re-pick it now.
      unawaited(
          ref.read(peerDiscoveryControllerProvider.notifier).retuneScan());
      // Coming back into an open chat: whatever piled up for it while we were
      // away has already been read the moment it's on screen.
      final open = AppLifecycle.instance.activeChatId;
      if (open != null) {
        unawaited(NotificationService.instance.clearForChat(open));
        ref.read(readMarkersControllerProvider.notifier).markRead(open);
      }
    }
  }

  /// Honour the "keep running in the background" preference on iOS.
  ///
  /// On Android that preference is a foreground service: turning it off lets
  /// the OS suspend us and the radio stops by itself. iOS has no equivalent.
  /// Info.plist declares the bluetooth-central/peripheral background modes, so
  /// the process is never suspended — scanning kept cycling the radio, the
  /// peripheral kept advertising, and the timers kept firing, forever, no
  /// matter what the toggle said. The toggle was inert on iOS (the
  /// `cubechat/background` channel only exists in MainApplication.kt), which is
  /// why an iPhone ran hot and flattened its battery where an Android didn't.
  ///
  /// So on iOS we enforce it ourselves: take the radio down on the way out,
  /// bring it back on the way in. With the preference ON nothing changes — the
  /// app stays reachable in the background exactly as before.
  void _applyIosBackgroundPolicy({required bool resumed}) {
    if (!PlatformInfo.isIOS) return;
    if (ref.read(backgroundModeProvider)) return; // user wants to stay live
    final discovery = ref.read(peerDiscoveryControllerProvider.notifier);
    // start() is idempotent and restores scanning and advertising together.
    unawaited(resumed ? discovery.start() : discovery.suspend());
  }

  @override
  Widget build(BuildContext context) {
    final locale = ref.watch(localeControllerProvider);
    // Touch the background-mode controller so it builds at startup and applies
    // the persisted preference. (Foreground-service start is (re)triggered on
    // resume above, since a headless start would be blocked.)
    ref.watch(backgroundModeProvider);
    // Keyed on the palette revision. AppColors' fields are mutated in place
    // (see ThemeController for why), so widgets already built are holding the
    // old colours — changing the key throws the tree away and builds it again.
    final palette = ref.watch(themeControllerProvider);
    return KeyedSubtree(
      key: ValueKey('palette-${palette.id}'),
      child: MaterialApp.router(
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
      // Feeds the app-wide "something is happening" signal that decorative
      // animations park themselves against. A Listener at the root sees every
      // pointer event without claiming any of them, so nothing downstream
      // changes behaviour; `poke` only re-arms a timer.
      // The voice bar wraps everything the router builds, so it survives a
      // push into a profile, a search, or another chat — which is the whole
      // point of playback outliving the bubble that started it.
      builder: (context, child) => _ClampedTextScale(
        child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => UiActivity.instance.poke(),
        onPointerMove: (_) => UiActivity.instance.poke(),
        onPointerSignal: (_) => UiActivity.instance.poke(),
        child: VoiceMiniPlayer(
          // The router lives below this builder, so the bar is handed the
          // one push it needs rather than looking one up it cannot see.
          onOpenChat: (chatId, _) => _openChat(chatId),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
      ),
      ),
    );
  }
}

/// Decide how large this UI draws, and bound how far that can go.
///
/// The app is built from capsules of fixed height — the 56-pixel chat header,
/// the nav bar, the settings rows — so a phone set to its largest font pushed
/// labels out of them, which is what "the text runs off" looked like on some
/// devices. Clamping rather than ignoring: an accessibility setting is a
/// request, and honouring most of it beats honouring none, which is what
/// `textScaler: TextScaler.noScaling` would do.
///
/// The ceiling is where the fixed heights stop coping; below 1 nothing breaks,
/// but going much smaller makes the timestamps unreadable, which is its own
/// accessibility failure.
///
/// On top of that the user can override the phone entirely — see [UiScale] for
/// why anyone would want to. An override is still clamped, so a setting in here
/// can never break the layout either.
class _ClampedTextScale extends ConsumerWidget {
  const _ClampedTextScale({required this.child});

  final Widget child;

  static const double _min = 0.85;
  static const double _max = 1.3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final media = MediaQuery.of(context);
    final chosen = ref.watch(uiScaleControllerProvider).factor;
    final scaler = chosen == null
        ? media.textScaler
        : TextScaler.linear(chosen);
    return MediaQuery(
      data: media.copyWith(
        textScaler: scaler.clamp(
          minScaleFactor: _min,
          maxScaleFactor: _max,
        ),
      ),
      child: child,
    );
  }
}
