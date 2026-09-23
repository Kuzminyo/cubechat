import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../core/transport/announcement.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../core/widgets/pill_button.dart';
import '../../../l10n/app_localizations.dart';
import '../data/bump_controller.dart';
import 'airdrop_navigation.dart';

/// The nickname inside a bump's card, or null while it is being read or when
/// it cannot be.
///
/// For a stranger the controller's `peerName` is only the "CubeChat"
/// fallback — the real name is in the card. The controller already proved the
/// card is the sender's before it made the event, so this is only a decode;
/// it goes through [PeerAnnouncement.verifyAndDecode] because that is the one
/// decoder the card has, and one Ed25519 check per bump is nothing.
///
/// Keyed by the card's bytes object, which the event holds for its whole life,
/// so a rebuild does not decode it again.
final bumpCardNameProvider =
    FutureProvider.autoDispose.family<String?, Uint8List>((ref, card) async {
  try {
    final name = (await PeerAnnouncement.verifyAndDecode(card)).nickname.trim();
    return name.isEmpty ? null : name;
  } catch (_) {
    return null;
  }
});

/// The NameDrop moment on the AirDrop page: a glow along the top of the screen
/// while someone's phone comes close, then — when the bump fires — a buzz, a
/// wave of light rolling down the screen, and the other person's avatar
/// dropping from the top edge into a card.
///
/// **Nothing runs at rest.** With no warmth and no event the overlay is not
/// shown at all: no painter, no layer, no ticker (test/bump_glow_test.dart
/// counts all three). The warmth glow is a [TweenAnimationBuilder], so it
/// schedules frames only for the 180 ms after warmth changes; the wave and
/// the bubble are two controllers run once per event, never repeated.
///
/// **Drawn from the top of the screen, not the top of the page.** The page
/// starts under the Nearby tab's title and switch, about a third of the way
/// down; a glow starting there reads as a highlighted list, not as the edge of
/// the phone the other phone is touching — which is the whole idea NameDrop
/// gets across. So the layer goes into the nearest [Overlay] (the tab's own
/// navigator, which fills the screen under the nav bar) through an
/// [OverlayPortal], while this widget stays mounted in the page and lives and
/// dies with it. The glow is under [IgnorePointer], so the title and the
/// switch it passes over keep their taps; only the card takes touches.
class BumpGlow extends ConsumerStatefulWidget {
  const BumpGlow({super.key});

  @override
  ConsumerState<BumpGlow> createState() => _BumpGlowState();
}

class _BumpGlowState extends ConsumerState<BumpGlow>
    with TickerProviderStateMixin {
  /// The spec's "~600 ms" for the wave.
  static const Duration _waveFor = Duration(milliseconds: 600);
  static const Duration _bubbleFor = Duration(milliseconds: 420);
  static const Duration _bubbleOutFor = Duration(milliseconds: 240);
  static const Duration _warmthFor = Duration(milliseconds: 180);

  /// How long "Sending to …" stays up. By then the offer's progress card is
  /// on the page and says the same thing with a bar.
  static const Duration _filesFor = Duration(milliseconds: 2500);

  /// The bubble starts when the wave is this far down, not after it: waiting
  /// out the whole 600 ms before anything arrives read as lag.
  static const double _bubbleAtWave = 0.5;

  late final AnimationController _wave =
      AnimationController(vsync: this, duration: _waveFor);
  late final AnimationController _bubble = AnimationController(
    vsync: this,
    duration: _bubbleFor,
    reverseDuration: _bubbleOutFor,
  );
  late final Animation<double> _waveAt =
      CurvedAnimation(parent: _wave, curve: Curves.easeOutCubic);
  final OverlayPortalController _portal = OverlayPortalController();

  /// The event the card is drawing — kept while it animates away, so it is
  /// not always the controller's current one.
  BumpEvent? _shown;
  bool _bubbleStarted = false;
  bool _retiring = false;

  /// Whether the drawn glow is above zero, which it still is for 180 ms after
  /// warmth has dropped to zero.
  bool _glowLit = false;
  bool _adding = false;
  bool _reduced = false;
  Timer? _autoDismiss;

  @override
  void initState() {
    super.initState();
    _wave
      ..addListener(_onWave)
      ..addStatusListener(_onWaveStatus);
    _bubble.addStatusListener(_onBubbleStatus);
    final now = ref.read(bumpControllerProvider);
    if (now.warmth > 0) {
      _glowLit = true;
      _portal.show();
    }
    // An event that is already there when the page is built was announced
    // before — shown as it stands, without a second buzz or wave.
    final e = now.event;
    if (e != null) {
      _shown = e;
      _bubble.value = 1;
      _portal.show();
      _armAutoDismiss(e);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void dispose() {
    _autoDismiss?.cancel();
    _wave.dispose();
    _bubble.dispose();
    super.dispose();
  }

  void _onBump(BumpState? before, BumpState next) {
    final e = next.event;
    if (!identical(e, _shown) && !(e == null && _retiring)) {
      if (e != null) {
        _present(e);
      } else {
        _retire();
      }
    }
    if (next.warmth > 0 && !_glowLit) {
      _glowLit = true;
      _showPortal();
    }
  }

  void _present(BumpEvent e) {
    _autoDismiss?.cancel();
    _retiring = false;
    setState(() => _shown = e);
    _showPortal();
    // Once per event: warmth moving under the same event re-emits the state
    // with the identical event object, which never gets here.
    unawaited(HapticFeedback.heavyImpact());
    if (_reduced) {
      _wave.value = 0;
      _bubble.value = 1;
    } else {
      _bubbleStarted = false;
      _bubble.value = 0;
      unawaited(_wave.forward(from: 0));
    }
    _armAutoDismiss(e);
  }

  /// File events are a status line only; the progress card on the page takes
  /// over, so this one leaves on its own.
  void _armAutoDismiss(BumpEvent e) {
    if (e is BumpContact) return;
    _autoDismiss = Timer(_filesFor, () {
      if (!mounted) return;
      if (identical(ref.read(bumpControllerProvider).event, e)) {
        ref.read(bumpControllerProvider.notifier).dismiss();
      }
    });
  }

  void _retire() {
    _autoDismiss?.cancel();
    if (_reduced || (_bubble.value == 0 && !_bubble.isAnimating)) {
      _clear();
      return;
    }
    _retiring = true;
    unawaited(_bubble.reverse());
  }

  void _clear() {
    _retiring = false;
    if (!mounted) return;
    if (_shown != null) setState(() => _shown = null);
    _maybeHide();
  }

  /// The page went off screen (another page, another tab, a route over it,
  /// the app in the background). The card is dropped with the visit: an
  /// event is only meant for the moment the phones touched, and one left in
  /// the controller would otherwise drop in again, stale, on the next visit.
  /// Dismissing here rather than ignoring old events on the way back needs no
  /// clock and leaves nothing in the controller to go stale in the first
  /// place. Nothing animates out — the page is not visible to animate on, and
  /// its tickers are off.
  void _leave() {
    // First, so the state change it causes cannot re-light what is cleared
    // below — the controller may not have zeroed its warmth for the page
    // going off yet, depending on which listener ran first.
    ref.read(bumpControllerProvider.notifier).dismiss();
    _autoDismiss?.cancel();
    _wave
      ..stop()
      ..value = 0;
    _bubble
      ..stop()
      ..value = 0;
    _retiring = false;
    _glowLit = false;
    if (_shown != null) setState(() => _shown = null);
    if (_portal.isShowing) _portal.hide();
  }

  void _onWave() {
    if (_bubbleStarted || _shown == null || _retiring) return;
    if (_wave.value < _bubbleAtWave) return;
    _bubbleStarted = true;
    unawaited(_bubble.forward(from: 0));
  }

  void _onWaveStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _maybeHide();
  }

  void _onBubbleStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && _retiring) _clear();
  }

  /// Warmth reached its target. At zero the glow is out, and the layer can go
  /// — after the frame, since this can be called while that frame is built.
  void _onGlowSettled() {
    if (ref.read(bumpControllerProvider).warmth > 0) return;
    _glowLit = false;
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeHide());
  }

  void _showPortal() {
    if (!_portal.isShowing) _portal.show();
  }

  void _maybeHide() {
    if (!mounted || !_portal.isShowing) return;
    if (_shown != null || _glowLit) return;
    if (_wave.isAnimating || _bubble.isAnimating) return;
    if (ref.read(bumpControllerProvider).warmth > 0) return;
    _portal.hide();
  }

  Future<void> _add(String name) async {
    if (_adding) return;
    _adding = true;
    final t = AppLocalizations.of(context);
    try {
      final hex = await ref.read(bumpControllerProvider.notifier).addContact();
      if (!mounted) return;
      if (hex == null) {
        showGlassToast(context, t.contactInvalid, tone: ToastTone.danger);
      } else {
        showGlassToast(context, t.contactAdded(name), tone: ToastTone.success);
      }
    } finally {
      _adding = false;
    }
  }

  /// The chat route the contact card and the QR scanner open for a known
  /// person — `/chat/<pubkey hex>`, the same `/chat/…?name=` call the people
  /// list's "Написати" makes, only with the pubkey (which is what a bump
  /// knows) instead of a Bluetooth device id.
  void _write(BumpContact e, String name) {
    unawaited(
      context.push(
        '/chat/${Uri.encodeComponent(e.peerHex)}'
        '?name=${Uri.encodeQueryComponent(name)}',
      ),
    );
    ref.read(bumpControllerProvider.notifier).dismiss();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<BumpState>(bumpControllerProvider, _onBump);
    ref.listen<bool>(airdropPageOnScreenProvider, (_, on) {
      if (!on) _leave();
    });
    final warmth =
        ref.watch(bumpControllerProvider.select((s) => s.warmth));
    // Watched here, in this widget's own build, and handed down: a watch made
    // from the overlay's builders would be dropped at this widget's next
    // build, since they run after it.
    final shown = _shown;
    final cardName = shown is BumpContact
        ? ref.watch(bumpCardNameProvider(shown.card)).valueOrNull
        : null;
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (context) => _overlay(context, warmth, cardName),
      child: const SizedBox.expand(),
    );
  }

  Widget _overlay(BuildContext context, double warmth, String? cardName) {
    final view = View.of(context);
    // The page sits in a SafeArea, which strips the top inset from the
    // MediaQuery this inherits; the overlay starts at the very top of the
    // screen, so the card is placed under the status bar by the view's own.
    final safeTop = view.padding.top / view.devicePixelRatio;
    final shown = _shown;
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          // Its own layer, so the wave repainting sixty times a second does
          // not repaint the page under it. It exists only while the overlay
          // is shown, which is only during an event.
          child: RepaintBoundary(
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: warmth),
              duration: _reduced ? Duration.zero : _warmthFor,
              onEnd: _onGlowSettled,
              builder: (context, w, _) => AnimatedBuilder(
                animation: _waveAt,
                builder: (context, _) => CustomPaint(
                  key: const Key('bump-glow'),
                  size: Size.infinite,
                  painter: _GlowPainter(
                    warmth: w.clamp(0.0, 1.0),
                    wave: _waveAt.value,
                    color: AppColors.brandPrimary,
                  ),
                ),
              ),
            ),
          ),
        ),
        if (shown != null)
          Positioned(
            top: safeTop + 12,
            left: 16,
            right: 16,
            child: Align(
              alignment: Alignment.topCenter,
              child: AnimatedBuilder(
                animation: _bubble,
                builder: (context, _) =>
                    _card(context, shown, cardName ?? shown.peerName, safeTop),
              ),
            ),
          ),
      ],
    );
  }

  Widget _card(
    BuildContext context,
    BumpEvent e,
    String name,
    double safeTop,
  ) {
    final t = AppLocalizations.of(context);
    final v = _bubble.value;
    // Two phases of one controller: the avatar drops in a glowing bubble
    // (easeOutBack, so it lands with a little give), and the pane opens round
    // it a beat later.
    final fall = _reduced
        ? 1.0
        : const Interval(0, 0.7, curve: Curves.easeOutBack).transform(v);
    final open = _reduced
        ? 1.0
        : const Interval(0.45, 1, curve: Curves.easeOutCubic).transform(v);

    // From the top edge of the screen to its slot in the card.
    const cardTop = 12.0;
    const avatarTop = 18.0;
    final drop = safeTop + cardTop + avatarTop + 36;
    final avatar = Transform.translate(
      offset: Offset(0, -drop * (1 - fall.clamp(0.0, 1.0))),
      child: Transform.scale(
        scale: lerpDouble(0.4, 1, fall),
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: open < 1
                ? [
                    BoxShadow(
                      color: AppColors.brandPrimary
                          .withValues(alpha: 0.6 * (1 - open)),
                      blurRadius: 28,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: IdentityAvatar(seed: e.peerHex, label: name, size: 72),
        ),
      ),
    );

    final Widget body = switch (e) {
      BumpContact() => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              name,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.textOnGlass,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            if (e.alreadyContact) ...[
              Text(
                t.airdropBumpAlreadyContact,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
              ),
              const SizedBox(height: 10),
              PillButton(
                label: t.airdropWrite,
                icon: Icons.chat_bubble_rounded,
                active: true,
                onTap: () => _write(e, name),
              ),
            ] else
              PillButton(
                label: t.airdropBumpAdd,
                icon: Icons.person_add_alt_1_rounded,
                active: true,
                onTap: () => unawaited(_add(name)),
              ),
          ],
        ),
      BumpSentFiles() => _statusLine(t.airdropBumpSending(name)),
      BumpReceivingFiles() => _statusLine(t.airdropBumpReceiving(name)),
    };

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: Stack(
        children: [
          // The pane is the bubble stretching into a card: it grows out of
          // the avatar's place rather than fading in over it.
          if (open > 0)
            Positioned.fill(
              child: Transform.scale(
                scaleX: lerpDouble(0.3, 1, open),
                scaleY: lerpDouble(0.45, 1, open),
                alignment: Alignment.topCenter,
                child: const FloatingGlass(
                  borderRadius: 22,
                  child: SizedBox.expand(),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, avatarTop, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(child: avatar),
                const SizedBox(height: 12),
                IgnorePointer(
                  ignoring: open < 1,
                  child: Opacity(opacity: open.clamp(0.0, 1.0), child: body),
                ),
              ],
            ),
          ),
          if (e is BumpContact)
            Positioned(
              top: 4,
              right: 4,
              child: IgnorePointer(
                ignoring: open < 1,
                child: Opacity(
                  opacity: open.clamp(0.0, 1.0),
                  child: IconButton(
                    tooltip: t.cancel,
                    onPressed: () =>
                        ref.read(bumpControllerProvider.notifier).dismiss(),
                    icon: const Icon(Icons.close_rounded, size: 20),
                    color: AppColors.textOnGlassDim,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _statusLine(String text) => Text(
        text,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: AppColors.textOnGlass,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      );
}

/// The glow along the top edge, and the wave rolling down under it.
///
/// Draws nothing at warmth 0 with no wave — though at rest it is not even
/// in the tree (see [BumpGlow]).
class _GlowPainter extends CustomPainter {
  const _GlowPainter({
    required this.warmth,
    required this.wave,
    required this.color,
  });

  /// 0..1, how close the nearest phone is.
  final double warmth;

  /// 0..1, how far down the screen the wave has rolled; 0 and 1 draw nothing.
  final double wave;
  final Color color;

  static const double _bandHeight = 90;

  @override
  void paint(Canvas canvas, Size size) {
    if (warmth > 0) {
      final rect = Rect.fromLTWH(
        0,
        0,
        size.width,
        lerpDouble(24, 180, warmth)!,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            // The same colour at zero alpha, not Colors.transparent: a
            // gradient toward transparent *black* greys the fade on the way.
            colors: [
              color.withValues(alpha: 0.55 * warmth),
              color.withValues(alpha: 0),
            ],
          ).createShader(rect),
      );
    }
    if (wave > 0 && wave < 1) {
      final rect = Rect.fromLTWH(
        0,
        wave * size.height - _bandHeight / 2,
        size.width,
        _bandHeight,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              color.withValues(alpha: 0),
              color.withValues(alpha: 0.45 * (1 - wave)),
              color.withValues(alpha: 0),
            ],
          ).createShader(rect),
      );
    }
  }

  @override
  bool shouldRepaint(_GlowPainter old) =>
      old.warmth != warmth || old.wave != wave || old.color != color;
}
