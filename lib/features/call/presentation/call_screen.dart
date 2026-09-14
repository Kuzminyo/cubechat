import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/colors.dart';
import '../../../core/widgets/bar_glass.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/util/platform_info.dart';
import '../../peers/presentation/widgets/peer_avatar.dart';
import '../data/call_controller.dart';
import '../data/call_media.dart';
import '../data/call_screen_access.dart';
import '../domain/call_state_machine.dart';

/// The call, drawn over whatever the router is showing.
///
/// Kept inside the app lock: incoming calls never bypass the lock screen.
///
/// **This lives above the router, and that constrains everything under it.**
/// It is mounted in `MaterialApp.router`'s `builder` so a call survives
/// navigation, which means there is no Router, no Navigator and no Overlay
/// above anything it draws. A widget that looks one of those up throws while
/// building, and a release build paints that as an empty rectangle — here the
/// size of the screen. That shipped once: `BackButtonListener` asks for the
/// Router, and tapping Call on a real phone turned the screen white and left it
/// there. So back is taken from the router's own dispatcher, handed in from
/// app.dart, and the controls carry no tooltips (a tooltip needs an Overlay).
/// `test/call_screen_mount_test.dart` mounts this exactly as the app does; it
/// is the check that anything added here can actually be built.
///
/// **A call can be put away, the way Telegram puts one away.** The screen
/// folds into [CallIsland] — a capsule under the status bar with the name, the
/// time, mute and end — and the app underneath is usable again: chats open,
/// messages send, and a tap on the island brings the call back. The rest of the
/// app is told the island is there by a taller top inset, so every header moves
/// down under it instead of hiding behind it.
class CallHost extends ConsumerStatefulWidget {
  const CallHost({
    super.key,
    required this.child,
    required this.backButtonDispatcher,
  });
  final Widget child;

  /// The router's root dispatcher. While a call is on screen a child of it
  /// takes priority, so the back key answers the call screen instead of
  /// popping the page hidden underneath it.
  final BackButtonDispatcher backButtonDispatcher;

  @override
  ConsumerState<CallHost> createState() => _CallHostState();
}

class _CallHostState extends ConsumerState<CallHost>
    with WidgetsBindingObserver {
  ChildBackButtonDispatcher? _back;

  /// Put away into the island. Reset for every new call, so a call that was
  /// minimised does not make the next one start out of sight.
  bool _minimized = false;
  String? _shownPeer;
  CallPhase? _shownPhase;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  // Here rather than in the controller, which is plain Dart with no binding in
  // its tests. This widget lives as long as the app does, above the router.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ref.read(callControllerProvider).noteLifecycle(state);
    // Back from the system settings the call screen sent somebody to.
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(callScreenAccessProvider.notifier).refresh());
    }
  }

  Future<bool> _onBack() async {
    final call = ref.read(callControllerProvider);
    if (!call.active) {
      call.dismiss();
    } else if (CallIsland.canMinimize(call)) {
      // Back puts a live call away, as it does in Telegram. Hanging up stays a
      // button: back is a gesture people make without looking.
      setState(() => _minimized = true);
    }
    return true;
  }

  void _holdBack(bool showing) {
    if (showing && _back == null) {
      _back = widget.backButtonDispatcher.createChildBackButtonDispatcher()
        ..addCallback(_onBack)
        ..takePriority();
    } else if (!showing && _back != null) {
      // Removing its last callback makes a child dispatcher step back from
      // its parent on its own, so the router has back again.
      _back!.removeCallback(_onBack);
      _back = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _holdBack(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callControllerProvider);
    if (_shownPeer != call.peerId) {
      _shownPeer = call.peerId;
      _minimized = false;
    }
    // A call that starts ringing here always comes up full screen: the answer
    // button is not something to find inside a capsule.
    if (_shownPhase != call.phase) {
      if (call.phase == CallPhase.incoming) _minimized = false;
      _shownPhase = call.phase;
    }
    // A call that ends while put away has nothing left to show. Its outcome is
    // already in the chat, so it is dismissed rather than unfolding a "call
    // ended" screen over whatever the person was reading.
    if (_minimized && !call.active && call.peerId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final latest = ref.read(callControllerProvider);
        if (!latest.active) latest.dismiss();
      });
    }

    final showing = call.peerId != null;
    final island = showing && _minimized && call.active;
    final expanded = showing && !island && !(_minimized && !call.active);
    _holdBack(expanded);

    final media = MediaQuery.of(context);
    return Stack(children: [
      // Every screen under the island reads its top inset from here, so the
      // headers step down by the island's height instead of sitting under it.
      MediaQuery(
        data: island
            ? media.copyWith(
                padding: media.padding.copyWith(
                  top: media.padding.top + CallIsland.reservedHeight,
                ),
                viewPadding: media.viewPadding.copyWith(
                  top: media.viewPadding.top + CallIsland.reservedHeight,
                ),
              )
            : media,
        child: ExcludeFocus(excluding: expanded, child: widget.child),
      ),
      if (island)
        Positioned(
          top: media.padding.top + 4,
          left: 10,
          right: 10,
          child: CallIsland(
            call: call,
            onExpand: () => setState(() => _minimized = false),
          ),
        ),
      if (expanded)
        Positioned.fill(
          child: CallScreen(
            call: call,
            onMinimize: CallIsland.canMinimize(call)
                ? () => setState(() => _minimized = true)
                : null,
          ),
        ),
    ]);
  }
}

/// The call, folded into a capsule at the top of the app.
///
/// Telegram's shape for the same thing: who, how long, and the two controls a
/// call is most often reached for without going back into it — the microphone
/// and the red button. Everything else is a tap away on the full screen.
class CallIsland extends StatelessWidget {
  const CallIsland({super.key, required this.call, required this.onExpand});

  final CallController call;
  final VoidCallback onExpand;

  static const double height = 52;

  /// What the island takes from the top of the app, its margins included.
  static const double reservedHeight = height + 8;

  /// Any live call can be put away except one still ringing here, whose answer
  /// button has to stay in reach.
  static bool canMinimize(CallController call) =>
      call.active && call.phase != CallPhase.incoming;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final talking = call.phase == CallPhase.talking;
    final status = talking
        ? callClock(call.elapsed)
        : call.preparing
            ? t.callPreparing
            : switch (call.phase) {
                CallPhase.dialing => t.callDialing,
                CallPhase.ringing => t.callRinging,
                CallPhase.connecting => t.callConnecting,
                _ => '',
              };
    // The nav bar's own pane of glass. It was a green gradient with a wide
    // soft shadow of its own, which painted a dark band round the capsule -
    // reported as "there is a background, a shadow or a border behind it, and
    // there should not be; make it like the bar's island". [BarGlass] is that
    // island, with its tight shadows and hairline, so the two cannot drift.
    return Semantics(
      container: true,
      button: true,
      label: '${call.name}, $status',
      child: BarGlass(
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onExpand,
            customBorder: const StadiumBorder(),
            child: SizedBox(
              height: height,
              child: Row(
                children: [
                  const SizedBox(width: 6),
                  PeerAvatar(
                    peerId: call.peerId ?? '',
                    label: call.name,
                    size: 40,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          call.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.textOnGlass,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          status,
                          maxLines: 1,
                          style: TextStyle(
                            color: AppColors.brandPrimary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (talking)
                    _IslandButton(
                      icon: call.micMuted
                          ? Icons.mic_off_rounded
                          : Icons.mic_rounded,
                      label: t.callMicrophone,
                      background: call.micMuted
                          ? AppColors.textOnGlass
                          : AppColors.glass(0.14),
                      foreground: call.micMuted
                          ? AppColors.bgDeep
                          : AppColors.textOnGlass,
                      onTap: () => unawaited(call.toggleMute()),
                    ),
                  const SizedBox(width: 6),
                  _IslandButton(
                    icon: Icons.call_end_rounded,
                    label: t.callEnd,
                    background: AppColors.danger,
                    foreground: Colors.white,
                    onTap: () => call.hangUp(),
                  ),
                  const SizedBox(width: 6),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IslandButton extends StatelessWidget {
  const _IslandButton({
    required this.icon,
    required this.label,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: Material(
          color: background,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 40,
              height: 40,
              child: Icon(icon, size: 22, color: foreground),
            ),
          ),
        ),
      );
}

/// `3:07`, `12:45`, `1:02:09` — the way a call's length is read aloud.
String callClock(Duration elapsed) {
  final hours = elapsed.inHours;
  final minutes = elapsed.inMinutes.remainder(60);
  final seconds = elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$seconds';
  }
  return '$minutes:$seconds';
}

class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({super.key, required this.call, this.onMinimize});

  /// Folds the screen into [CallIsland]. Null while that is not allowed — a
  /// call still ringing here, or one already over.
  final VoidCallback? onMinimize;
  final CallController call;

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
  /// The list of places the sound can go, open over the controls.
  bool _routesOpen = false;

  CallController get call => widget.call;

  Future<void> _onSpeaker() async {
    await call.refreshAudioRoutes();
    if (!mounted) return;
    // Two places to choose between is a switch; three or more is a list.
    if (call.hasHeadsetRoute) {
      setState(() => _routesOpen = true);
    } else {
      await call.toggleSpeaker();
    }
  }

  /// The route the sound is on, as far as this screen can tell: chosen by
  /// name, or the speaker switch.
  CallAudioRouteKind get _route =>
      call.audioRoute ??
      (call.speakerOn
          ? CallAudioRouteKind.speaker
          : call.hasHeadsetRoute
              ? call.audioRoutes
                  .firstWhere(
                    (r) =>
                        r.kind == CallAudioRouteKind.bluetooth ||
                        r.kind == CallAudioRouteKind.wired,
                  )
                  .kind
              : CallAudioRouteKind.earpiece);

  static IconData routeIcon(CallAudioRouteKind kind) => switch (kind) {
        CallAudioRouteKind.earpiece => Icons.phone_in_talk_rounded,
        CallAudioRouteKind.speaker => Icons.volume_up_rounded,
        CallAudioRouteKind.bluetooth => Icons.bluetooth_audio_rounded,
        CallAudioRouteKind.wired => Icons.headphones_rounded,
      };

  static String routeLabel(AppLocalizations t, CallAudioRoute route) =>
      switch (route.kind) {
        CallAudioRouteKind.earpiece => t.callRoutePhone,
        CallAudioRouteKind.speaker => t.callSpeaker,
        // The device's own name when it has one: "AirPods Pro" says which
        // headset, where "Bluetooth" does not.
        CallAudioRouteKind.bluetooth =>
          route.label.isEmpty ? t.callRouteBluetooth : route.label,
        CallAudioRouteKind.wired => t.callRouteHeadphones,
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final talking = call.phase == CallPhase.talking;
    final connecting = call.phase == CallPhase.connecting;
    final incoming = call.phase == CallPhase.incoming && !call.preparing;
    final access = ref.watch(callScreenAccessProvider);
    // Not over an incoming call: the answer button is what that screen is for.
    final askForScreen = PlatformInfo.isAndroid &&
        !access.complete &&
        !incoming &&
        !ref.watch(callScreenAccessDismissedProvider);
    final status = call.preparing
        ? t.callPreparing
        : switch (call.phase) {
            CallPhase.incoming => t.previewCallIncoming,
            CallPhase.dialing => t.callDialing,
            CallPhase.ringing => t.callRinging,
            CallPhase.connecting => t.callConnecting,
            CallPhase.talking => callClock(call.elapsed),
            _ => switch (call.error) {
                'microphone' => t.callMicrophoneRequired,
                'turn' => t.callRelayUnavailable,
                'busy' => t.callBusy,
                'noAnswer' => t.callNoAnswer,
                'unavailable' || 'media' || 'failed' => t.callFailed,
                'declined' => t.callDeclined,
                _ => t.callEnded,
              },
          };
    if (_routesOpen && !(talking || connecting)) _routesOpen = false;

    final route = _route;
    final routeName = switch (route) {
      CallAudioRouteKind.earpiece => t.callRoutePhone,
      CallAudioRouteKind.speaker => t.callSpeaker,
      CallAudioRouteKind.bluetooth => t.callRouteBluetooth,
      CallAudioRouteKind.wired => t.callRouteHeadphones,
    };

    // One row, spread across the width. The controls used to be a centred
    // `Wrap` of fixed 90-point cells, so two buttons huddled in the middle and
    // four wrapped onto a second line on a narrow phone. Asked for as "align
    // the icons across the width": every button gets an equal share of it.
    final controls = <Widget>[
      if (talking || connecting) ...[
        _control(
          call.micMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
          t.callMicrophone,
          () => unawaited(call.toggleMute()),
          selected: call.micMuted,
        ),
        _control(
          routeIcon(route),
          call.hasHeadsetRoute ? routeName : t.callSpeaker,
          () => unawaited(_onSpeaker()),
          selected: route != CallAudioRouteKind.earpiece,
        ),
      ],
      if (call.active)
        _control(
          Icons.call_end_rounded,
          incoming ? t.callDecline : t.callEnd,
          incoming ? () => call.decline() : () => call.hangUp(),
          tone: AppColors.danger,
        )
      else
        _control(Icons.close_rounded, t.callClose, call.dismiss),
      if (incoming)
        _control(
          Icons.call_rounded,
          t.callAnswer,
          () => unawaited(call.answer()),
          tone: AppColors.brandPrimary,
        ),
    ];

    return Material(
      color: AppColors.bgDeep,
      child: Stack(
        children: [
          SafeArea(
            child: LayoutBuilder(
              builder: (context, bounds) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: bounds.maxHeight),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        SizedBox(
                          height: 48,
                          child: Row(
                            children: [
                              if (widget.onMinimize != null)
                                Semantics(
                                  button: true,
                                  label: t.callMinimize,
                                  excludeSemantics: true,
                                  child: IconButton(
                                    onPressed: widget.onMinimize,
                                    icon: Icon(
                                      Icons.keyboard_arrow_down_rounded,
                                      size: 30,
                                      color: AppColors.textPrimary,
                                    ),
                                  ),
                                )
                              else
                                const SizedBox(width: 48),
                              Expanded(
                                child: Text(
                                  t.callVoice,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 48),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 36,
                            horizontal: 12,
                          ),
                          child: Column(children: [
                            // Their picture when they have shared one, the same
                            // face the chat list shows; initials otherwise.
                            PeerAvatar(
                              peerId: call.peerId ?? '',
                              label: call.name,
                              size: 120,
                            ),
                            const SizedBox(height: 24),
                            Text(
                              call.name,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 28,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Semantics(
                              liveRegion: !talking,
                              child: Text(
                                status,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: AppColors.textPrimary,
                                  fontSize: 16,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                          ]),
                        ),
                        Column(
                          children: [
                            if (askForScreen) ...[
                              _ScreenAccessBanner(
                                access: access,
                                onAllow: () => unawaited(ref
                                    .read(callScreenAccessProvider.notifier)
                                    .openSettings()),
                                onLater: () => ref
                                    .read(callScreenAccessDismissedProvider
                                        .notifier)
                                    .state = true,
                              ),
                              const SizedBox(height: 24),
                            ],
                            Row(
                              children: [
                                for (final control in controls)
                                  Expanded(child: control),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_routesOpen)
            Positioned.fill(
              child: _RoutePicker(
                routes: call.audioRoutes,
                current: route,
                label: (r) => routeLabel(t, r),
                icon: routeIcon,
                title: t.callAudioOutput,
                onPick: (r) {
                  setState(() => _routesOpen = false);
                  unawaited(call.selectAudioRoute(r));
                },
                onClose: () => setState(() => _routesOpen = false),
              ),
            ),
        ],
      ),
    );
  }

  // No tooltip: a tooltip needs an Overlay, and there is none above this
  // screen (see [CallHost]). The label is drawn under the button, and the
  // Semantics wrapper gives a screen reader the same word the tooltip did.
  Widget _control(
    IconData icon,
    String label,
    VoidCallback action, {
    bool selected = false,
    Color? tone,
  }) {
    final background = tone ??
        (selected ? AppColors.brandPrimary : AppColors.glassFillStrong);
    final foreground = tone != null
        ? Colors.white
        : selected
            ? AppColors.bgDeep
            : AppColors.textPrimary;
    return Column(
      children: [
        Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          child: IconButton.filledTonal(
            onPressed: action,
            isSelected: selected,
            style: IconButton.styleFrom(
              minimumSize: const Size(64, 64),
              backgroundColor: background,
              foregroundColor: foreground,
            ),
            icon: Icon(icon, size: 28),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textPrimary),
        ),
      ],
    );
  }
}

/// Where the call's sound goes: the phone, the loudspeaker, a wired headset,
/// each Bluetooth one by its own name.
///
/// Drawn inside the call screen rather than as a bottom sheet, because there is
/// no Navigator above it to push one onto (see [CallHost]).
class _RoutePicker extends StatelessWidget {
  const _RoutePicker({
    required this.routes,
    required this.current,
    required this.label,
    required this.icon,
    required this.title,
    required this.onPick,
    required this.onClose,
  });

  final List<CallAudioRoute> routes;
  final CallAudioRouteKind current;
  final String Function(CallAudioRoute) label;
  final IconData Function(CallAudioRouteKind) icon;
  final String title;
  final ValueChanged<CallAudioRoute> onPick;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onClose,
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.45),
        child: SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: GestureDetector(
              onTap: () {},
              child: Container(
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
                decoration: BoxDecoration(
                  color: AppColors.bgDeep,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: AppColors.glass(0.14)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: Text(
                        title,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    for (final route in routes)
                      Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => onPick(route),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 14,
                            ),
                            child: Row(
                              children: [
                                Icon(icon(route.kind),
                                    color: AppColors.textPrimary),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Text(
                                    label(route),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: AppColors.textPrimary,
                                      fontSize: 15,
                                    ),
                                  ),
                                ),
                                if (route.kind == current)
                                  Icon(Icons.check_rounded,
                                      color: AppColors.brandPrimary),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Why the next call to this phone may arrive as a banner, and the button that
/// fixes it. Shown on the call screen because that is where somebody has just
/// learned what a call looks like here.
class _ScreenAccessBanner extends StatelessWidget {
  const _ScreenAccessBanner({
    required this.access,
    required this.onAllow,
    required this.onLater,
  });

  final CallScreenAccess access;
  final VoidCallback onAllow;
  final VoidCallback onLater;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      decoration: BoxDecoration(
        color: AppColors.glassFillStrong,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.fullscreen_rounded, color: AppColors.brandPrimary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  t.callFullScreenTitle,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            access.xiaomi
                ? '${t.callFullScreenBody} ${t.callFullScreenXiaomi}'
                : t.callFullScreenBody,
            style: TextStyle(color: AppColors.textPrimary, fontSize: 13),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: onLater, child: Text(t.callFullScreenLater)),
              TextButton(
                onPressed: onAllow,
                child: Text(
                  t.callFullScreenAllow,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
