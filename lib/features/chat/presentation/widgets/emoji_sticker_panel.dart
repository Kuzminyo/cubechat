import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../stickers/presentation/sticker_grid.dart';
import 'emoji_picker_sheet.dart';

/// How tall the keyboard on this phone is, as last measured while it was at
/// rest.
///
/// **Measured from the [View], not from [MediaQuery].** That is the whole
/// reason the panel and the keyboard used to fight over the bottom of the
/// screen: a [Scaffold] with `resizeToAvoidBottomInset` on (the default, and
/// what the chat uses) hands its body a MediaQuery with the bottom inset
/// *removed*, because the Scaffold has already shrunk the body by it. So every
/// reading taken inside the conversation was zero — the remembered height never
/// left its fallback, and the panel could never tell whether the keyboard was
/// up, halfway, or gone. The view's insets are the raw window's and are not
/// stripped by anything.
abstract final class KeyboardHeight {
  /// Used until a keyboard has been seen. Close to a mid-size Android keyboard;
  /// wrong by a few tens of points at worst, and only for the first open of a
  /// fresh launch.
  static const double fallback = 300;

  /// Anything below this is not a keyboard — it is an accessory bar, or a frame
  /// of one arriving or leaving.
  static const double _floor = 120;

  /// How long the inset has to hold still before it counts as the keyboard's
  /// real height. Without this the value would be sampled mid-animation and the
  /// panel would size itself against a keyboard that was still on its way up.
  static const Duration _settleDelay = Duration(milliseconds: 220);

  static double _seen = 0;

  /// The tallest the keyboard has been since it last went away. Resets when it
  /// does, so a keyboard that changes size between openings is re-measured.
  static double _peak = 0;
  static Timer? _settle;

  /// The keyboard's height in logical pixels right now: full while it is up,
  /// zero while it is away, and everything in between during the animation.
  static double insetOf(BuildContext context) {
    final view = View.maybeOf(context);
    if (view == null) return 0;
    final ratio = view.devicePixelRatio;
    if (ratio <= 0) return 0;
    return view.viewInsets.bottom / ratio;
  }

  /// Feed a reading in. Only a value that stops changing is kept — and only
  /// from a keyboard that is arriving or already there.
  ///
  /// A keyboard on its way *out* passes through every height between its own
  /// and nothing, and those are not measurements of anything. Taking them
  /// recorded whatever the last frame above the floor happened to be, so one
  /// trip down left the app believing keyboards on this phone were a hundred
  /// and fifty points tall; the panel then drew itself that size and, worse,
  /// read the departing keyboard as one arriving and took itself back out —
  /// which is the switch from the keyboard to the smileys not happening at all.
  ///
  /// Compared against the episode's high-water mark rather than against the
  /// previous sample, because the platform repeats a value across frames: "not
  /// smaller than last time" is true of a keyboard that has stopped halfway out
  /// as well as of one at rest, and that repeat was enough to record it.
  static void observeInset(double inset) {
    if (inset <= _floor) {
      // Gone. The next rise is a new measurement.
      _peak = 0;
      return;
    }
    if (inset < _peak) return;
    _peak = inset;
    _settle?.cancel();
    _settle = Timer(_settleDelay, () {
      _seen = inset;
    });
  }

  static void observe(BuildContext context) => observeInset(insetOf(context));

  static double get value => _seen > 0 ? _seen : fallback;

  /// Forget the measurement and drop the pending one.
  ///
  /// For tests: the settle timer is static and outlives any one widget tree, so
  /// a test that simulates a keyboard would otherwise leave a timer pending and
  /// carry its height into the next test.
  @visibleForTesting
  static void debugReset() {
    _settle?.cancel();
    _settle = null;
    _seen = 0;
    _peak = 0;
  }
}

/// Emoji on one tab, stickers on the other, drawn as an island the size of the
/// keyboard. Purely presentational — [KeyboardSlotPanel] decides how much of it
/// is showing.
class EmojiStickerPanel extends StatefulWidget {
  const EmojiStickerPanel({
    super.key,
    required this.height,
    required this.onEmoji,
    this.onSticker,
    this.onCreateSticker,
    this.startOnStickers = false,
  });

  final double height;
  final ValueChanged<String> onEmoji;

  /// Null where a picture cannot be sent — the panel is then emoji only, and
  /// the sticker tab is not offered rather than being offered and refusing.
  final void Function(String path, String? emoji)? onSticker;
  final VoidCallback? onCreateSticker;
  final bool startOnStickers;

  @override
  State<EmojiStickerPanel> createState() => _EmojiStickerPanelState();
}

class _EmojiStickerPanelState extends State<EmojiStickerPanel> {
  late bool _stickers = widget.startOnStickers && widget.onSticker != null;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final stickers = widget.onSticker != null;
    return SizedBox(
      height: widget.height,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppColors.pane(0.94),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(
            top: BorderSide(color: AppColors.glass(0.16)),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.26),
              blurRadius: 18,
              offset: const Offset(0, -6),
              spreadRadius: -14,
            ),
          ],
        ),
        child: Column(
          children: [
            if (stickers)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
                child: Row(
                  children: [
                    _Tab(
                      label: t.emojiTab,
                      icon: Icons.emoji_emotions_rounded,
                      active: !_stickers,
                      onTap: () => setState(() => _stickers = false),
                    ),
                    const SizedBox(width: 8),
                    _Tab(
                      label: t.attachStickers,
                      icon: Icons.auto_awesome_rounded,
                      active: _stickers,
                      onTap: () => setState(() => _stickers = true),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _stickers
                  ? StickerGrid(
                      onPick: widget.onSticker!,
                      onCreate: widget.onCreateSticker,
                    )
                  : EmojiPane(onPick: widget.onEmoji),
            ),
          ],
        ),
      ),
    );
  }
}

/// The panel, occupying the bottom slot the keyboard also uses.
///
/// There is one slot, and exactly one thing in it. Everything awkward about
/// this feature came from the two of them measuring that slot separately:
///
/// * **The height it shows is the slot minus whatever the keyboard is holding.**
///   While the keyboard rises the panel gives back the same number of points it
///   takes, frame by frame, so the composer above does not move by a pixel and
///   one surface appears to become the other. While the keyboard leaves, the
///   same sum runs backwards and the panel grows into the space behind it.
/// * **Opening on top of a departing keyboard skips the entrance curve.** The
///   slot is already the right size; animating into it as well would run two
///   curves at once, which is the "flashes and does not open" that opening the
///   panel from a raised keyboard used to be.
/// * **When the sum reaches zero the keyboard has taken over**, and the panel
///   says so through [onKeyboardTookOver] rather than guessing at a threshold.
///   A guess is what left a half-height panel to vanish in one frame — the jerk
///   at the end of the swap.
class KeyboardSlotPanel extends StatefulWidget {
  const KeyboardSlotPanel({
    super.key,
    required this.open,
    required this.onEmoji,
    this.onSticker,
    this.onCreateSticker,
    this.startOnStickers = false,
    this.onKeyboardTookOver,
  });

  /// False starts the fold; the parent takes this out of the tree [motion]
  /// later, which is how the fold is seen rather than cut off.
  final bool open;

  final ValueChanged<String> onEmoji;
  final void Function(String path, String? emoji)? onSticker;
  final VoidCallback? onCreateSticker;
  final bool startOnStickers;

  /// The keyboard now fills the slot, so there is nothing of this left to draw.
  /// Fired once per takeover.
  final VoidCallback? onKeyboardTookOver;

  /// Also how long a caller should wait before unmounting after setting [open]
  /// to false.
  static const Duration motion = Duration(milliseconds: 240);

  @override
  State<KeyboardSlotPanel> createState() => _KeyboardSlotPanelState();
}

class _KeyboardSlotPanelState extends State<KeyboardSlotPanel>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _open = AnimationController(
    vsync: this,
    duration: KeyboardSlotPanel.motion,
  );

  double _inset = 0;
  bool _started = false;
  bool _toldParent = false;

  /// A keyboard on its way out is still "there" for this purpose: the slot is
  /// already open, so the panel complements it instead of animating in.
  static const double _presence = 8;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _inset = KeyboardHeight.insetOf(context);
    if (_started) return;
    _started = true;
    if (widget.open) {
      if (_inset > _presence) {
        _open.value = 1;
      } else {
        _open.forward(from: 0);
      }
    }
  }

  @override
  void didUpdateWidget(covariant KeyboardSlotPanel old) {
    super.didUpdateWidget(old);
    if (widget.open == old.open) return;
    if (widget.open) {
      _toldParent = false;
      if (_inset > _presence) {
        _open.value = 1;
      } else {
        _open.forward();
      }
    } else {
      _open.reverse();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _open.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final next = KeyboardHeight.insetOf(context);
    KeyboardHeight.observeInset(next);
    if ((next - _inset).abs() < 0.5) return;
    final rising = next > _inset;
    setState(() => _inset = next);
    // Nothing left to show *and the keyboard is the one arriving*: the swap is
    // complete. The direction is the whole test. Without it a keyboard on its
    // way out — which also passes through "the panel has nothing to draw yet" —
    // was read as a takeover, and the panel the user had just asked for was
    // taken back out of the tree before it could grow into the space.
    if (widget.open && !_toldParent && rising && _slack <= 0.5) {
      _toldParent = true;
      widget.onKeyboardTookOver?.call();
    }
  }

  double get _slack => math.max(0, KeyboardHeight.value - _inset);

  @override
  Widget build(BuildContext context) {
    final full = KeyboardHeight.value;
    return AnimatedBuilder(
      animation: _open,
      // Built once and handed in, rather than rebuilt on every tick: the grid
      // behind this is fifty-odd cells, and the animation is a clip.
      child: EmojiStickerPanel(
        height: full,
        startOnStickers: widget.startOnStickers,
        onEmoji: widget.onEmoji,
        onSticker: widget.onSticker,
        onCreateSticker: widget.onCreateSticker,
      ),
      builder: (context, child) {
        final shown = _open.value * _slack;
        if (shown <= 0.5) return const SizedBox.shrink();
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: (shown / full).clamp(0.0, 1.0),
            child: child,
          ),
        );
      },
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colour = active ? AppColors.brandPrimary : AppColors.textOnGlassDim;
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: active
                  ? AppColors.brandPrimary.withValues(alpha: 0.14)
                  : Colors.transparent,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 17, color: colour),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: colour,
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
