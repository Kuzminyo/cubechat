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
import 'features/chat/data/messages_controller.dart';
import 'features/chats/data/read_markers_controller.dart';
import 'features/chats/presentation/chats_list_screen.dart';
import 'features/map/data/map_presence_controller.dart';
import 'features/peers/data/known_peers_controller.dart';
import 'features/peers/data/peer_discovery_controller.dart';
import 'features/peers/data/peripheral_controller.dart';
import 'features/profile/data/ui_scale_controller.dart';
import 'l10n/app_localizations.dart';

/// What opening a conversation from a notification should do to the stack.
enum ChatOpenAction {
  /// It is already the screen you are looking at.
  alreadyThere,

  /// Some other conversation is open — swap it for this one.
  replace,

  /// Nothing conversational is open — push on top of whatever is.
  push,
}

/// Decide it from where the router is and where it is being sent.
///
/// Pulled out as a function of two strings because the bug it fixes is a
/// three-line rule that was not written down anywhere: the handler pushed,
/// always, and pushing the conversation you are *already reading* puts a second
/// copy of it on the stack. Back then popped one copy and left you exactly
/// where you were, which reads as the button not working.
///
/// Compared by **path only**. The name rides in the query string and is
/// re-resolved from the roster on every call, so a contact who has since been
/// renamed would otherwise look like a different destination and get stacked on
/// top of itself.
ChatOpenAction notificationOpenAction({
  required Uri current,
  required String target,
}) {
  final wanted = Uri.parse(target).path;
  if (current.path == wanted) return ChatOpenAction.alreadyThere;
  final onAConversation =
      current.path.startsWith('/chat/') || current.path.startsWith('/channel/');
  return onAConversation ? ChatOpenAction.replace : ChatOpenAction.push;
}

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
      _startDiscovery();
    });
  }

  /// Bring Bluetooth up when the app does, not when somebody opens Nearby.
  ///
  /// This used to be called from exactly one place — `PeersScreen.initState` —
  /// and the Nearby branch is deliberately the one tab the router does not
  /// preload. Between them, a phone that launched into Chats and stayed there
  /// never advertised, never scanned, and held no links: the mesh was off for
  /// the entire session and every send fell through to the relay. A field log
  /// caught it as two minutes with not one BLE line in it, on an app whose
  /// whole premise is working without a relay to fall through to.
  ///
  /// It does not undo the heat work. What that changed was the *cadence*, and
  /// the cadence is picked per scan window by `shouldScanActively` — active
  /// only while somebody is watching the Nearby list or we owe a delivery, idle
  /// everywhere else. Starting the scanner at launch runs it at the idle
  /// cadence, which is the state that fix was aiming for; what it was not
  /// aiming for was no radio at all.
  void _startDiscovery() {
    if (!PlatformInfo.isMobile) return;
    // Idempotent, so the Peers screen calling it again on mount is harmless.
    unawaited(ref.read(peerDiscoveryControllerProvider.notifier).start());
  }

  /// Opens the chat for [chatId] — a pubkey-hex canonical id, or a `#channel`
  /// name. Resolves the display name from the KnownPeers roster for the header.
  void _openChat(String chatId) {
    // A channel's id starts with '#', which is the URL fragment delimiter and
    // cannot travel in a path. It has its own route.
    final String target;
    if (chatId.startsWith('#')) {
      target = channelRoute(chatId);
    } else {
      final known = ref.read(knownPeersControllerProvider)[chatId];
      final name =
          (known?.displayName.isNotEmpty ?? false) ? known!.displayName : 'Peer';
      target = '/chat/${Uri.encodeComponent(chatId)}'
          '?name=${Uri.encodeQueryComponent(name)}';
    }

    final current = _router.routerDelegate.currentConfiguration.uri;
    switch (notificationOpenAction(current: current, target: target)) {
      case ChatOpenAction.alreadyThere:
        // Nothing to do. This is the case that was reported: minimise while
        // reading somebody, they write, tap the notification — and the same
        // conversation was pushed a second time on top of itself, so Back
        // landed you in the chat you were trying to leave.
        return;
      case ChatOpenAction.replace:
        // A *different* conversation, with one already on screen. Swapping
        // rather than stacking is what makes Back mean "the list of chats"
        // instead of walking you through everybody who happened to write while
        // the app was in your pocket.
        _router.pushReplacement(target);
      case ChatOpenAction.push:
        _router.push(target);
    }
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
  ///
  /// Six seconds was the first answer and it read as a lag: leaving the app
  /// and watching the other phone, the dot stayed lit long enough to look
  /// broken. Three is the compromise — a picker or a camera round trip is
  /// almost always longer than that, so it costs the occasional extra pair of
  /// beacons, and the twenty-second floor inside the transport is what stops
  /// that becoming a storm.
  static const Duration _goodbyeGrace = Duration(seconds: 3);

  /// A finger on the glass is proof of being in the app, and the only proof
  /// that cannot be missed.
  ///
  /// The lifecycle callback fires on a *transition*, and on Android the engine
  /// is pre-warmed headless in MainApplication — so the seed in [initState]
  /// reads whatever the process was born into, and an Activity that attaches
  /// without producing a transition this observer sees leaves the flag stuck at
  /// false. The phone then never claims to be online however long its owner
  /// uses it, while the identical build on another phone works, because there
  /// the callback happened to arrive. Both were in the logs.
  ///
  /// Nothing is sent unless the flag was actually wrong, so this costs one
  /// comparison per touch.
  void _noticeTouch() {
    if (AppLifecycle.instance.isForeground) return;
    AppLifecycle.instance.isForeground = true;
    // Deliberately not through [_announcePresenceDebounced]: that one holds
    // `_announcedOnline`, which starts life claiming we already said so — and
    // in this exact case we never did, because the beacon was suppressed for
    // not being in the foreground. Going straight to the service repairs that;
    // it throttles a repeat on its own.
    _goodbyeTimer?.cancel();
    _goodbyeTimer = null;
    _announcedOnline = true;
    unawaited(
      ref.read(messagingServiceProvider).announcePresence(online: true),
    );
  }

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
    // Only the two states that mean something — the same filter the presence
    // beacon below already uses, and for the same reason.
    //
    // This ran on every callback, including `inactive`, which Android emits for
    // anything that covers the app for a moment: the notification shade, a
    // permission dialog, the recents switcher. Each one restarted advertising,
    // and a field log caught the result — BALANCED, LOW_POWER, BALANCED,
    // LOW_POWER inside two seconds. Restarting the advertiser four times to
    // land back where it started costs more radio than the power step it was
    // choosing between saves.
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.paused) {
      _applyBackgroundRadioPolicy(resumed: state == AppLifecycleState.resumed);
    }
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
    // Message writes are coalesced behind a short debounce, so leaving is the
    // moment to make good on them: from `paused` onward the OS may kill the
    // process without another callback, and an unwritten conversation would go
    // with it.
    if (state != AppLifecycleState.resumed) {
      unawaited(ref.read(messagesControllerProvider.notifier).flushPending());
    }
    // The engine is pre-warmed in MainApplication, so main() (and this
    // widget) can build while the app is still headless — and Android 12+
    // forbids starting a foreground service from the background. Re-apply
    // background mode whenever we come to the foreground so the service
    // actually starts (or restarts) from an allowed state.
    if (state == AppLifecycleState.resumed) {
      // First, because everything else on this path is cheap and this is the
      // one that decides whether the app has an internet transport at all.
      // iOS tears the relay sockets down while suspended and nothing was
      // asking them to come back, so a returning iPhone had no relay for up to
      // the two minutes its backoff had grown to.
      ref.read(messagingServiceProvider).wakeRelays();
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

  /// Honour the "keep running in the background" preference, on both platforms.
  ///
  /// iOS has no equivalent of Android's foreground service. Info.plist declares
  /// the bluetooth-central/peripheral background modes, so the process is never
  /// suspended — scanning kept cycling the radio, the peripheral kept
  /// advertising, and the timers kept firing, forever, no matter what the
  /// toggle said. The toggle was inert on iOS (the `cubechat/background`
  /// channel only exists in MainApplication.kt), which is why an iPhone ran hot
  /// and flattened its battery where an Android didn't.
  ///
  /// Android was assumed to need none of this, on the reasoning that turning
  /// the preference off lets the OS suspend us and the radio stops by itself.
  /// That is true eventually and not soon: a paused Android process keeps its
  /// Dart timers running and its advertisement live until Doze takes over,
  /// which needs the device to be still, and which the foreground service opts
  /// out of entirely. So the phone that was promised the cheapest behaviour —
  /// preference off, screen off, in a pocket — was the one still advertising
  /// four times a second. Both platforms now take the radio down when the
  /// preference is off.
  ///
  /// With the preference ON the app must stay reachable, so nothing is torn
  /// down. What happens instead is [_applyAdvertisePower]: the same
  /// availability at a quarter of the radio events.
  void _applyBackgroundRadioPolicy({required bool resumed}) {
    _applyAdvertisePower(resumed: resumed);
    if (ref.read(backgroundModeProvider)) return; // user wants to stay live
    if (!PlatformInfo.isIOS && !PlatformInfo.isAndroid) return;
    final discovery = ref.read(peerDiscoveryControllerProvider.notifier);
    // start() is idempotent and restores scanning and advertising together.
    unawaited(resumed ? discovery.start() : discovery.suspend());
  }

  /// Cheap advertising while the app is out of sight, normal while it is not.
  ///
  /// Only meaningful when the radio stays up at all — which is the
  /// stay-reachable case, where suspending is exactly what the user asked us
  /// not to do. Scanning already backs off on its own; this is the other half,
  /// and the one that runs continuously rather than in windows.
  void _applyAdvertisePower({required bool resumed}) {
    if (!PlatformInfo.isAndroid) return;
    unawaited(
      ref.read(blePeripheralProvider).setAdvertisePower(low: !resumed),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locale = ref.watch(localeControllerProvider);
    // Touch the background-mode controller so it builds at startup and applies
    // the persisted preference. (Foreground-service start is (re)triggered on
    // resume above, since a headless start would be blocked.)
    ref.watch(backgroundModeProvider);
    ref.watch(mapPresenceControllerProvider);
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
        onPointerDown: (_) {
          UiActivity.instance.poke();
          _noticeTouch();
        },
        onPointerMove: (_) => UiActivity.instance.poke(),
        onPointerSignal: (_) => UiActivity.instance.poke(),
        child: _TapToDismissKeyboard(
        child: VoiceMiniPlayer(
          // The router lives below this builder, so the bar is handed the
          // one push it needs rather than looking one up it cannot see.
          onOpenChat: (chatId, _) => _openChat(chatId),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
      ),
      ),
      ),
    );
  }
}

/// A tap on nothing in particular puts the keyboard away.
///
/// The app-wide guarantee that the keyboard can always be closed. Individual
/// screens dismiss it at the moments where it is clearly finished — leaving a
/// tab, dragging a list, closing a search — but every one of those is a place
/// somebody thought to add it, and the bug this exists for was the case nobody
/// thought of: a keyboard left over from a field that is no longer on screen,
/// on a platform with no system-level way to dismiss one.
///
/// Deliberately at the root and deliberately last in the arena. A tap that
/// lands on a real target — a text field, a button, a chat tile — is claimed by
/// that target's own recognizer, which sits deeper in the hit-test path and so
/// wins outright; this only ever sees the taps nothing else wanted.
class _TapToDismissKeyboard extends StatelessWidget {
  const _TapToDismissKeyboard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Translucent so the tap is still offered to whatever is underneath:
      // this widget covers the whole app and must not become a lid on it.
      behavior: HitTestBehavior.translucent,
      onTap: () {
        final focus = FocusManager.instance.primaryFocus;
        // Only when something is actually holding the keyboard open. Unfocusing
        // unconditionally would also throw away focus that no keyboard is
        // attached to — a hardware-keyboard user tabbing through the UI, say.
        if (focus == null || !focus.hasFocus) return;
        focus.unfocus();
      },
      child: child,
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

