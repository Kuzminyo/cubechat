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

  /// Feed a reading in. Only a value that stops changing is kept.
  static void observeInset(double inset) {
    if (inset <= _floor) return;
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
    // An island, like everything else that floats over the aurora here: margins
    // on three sides, rounded corners, the pane's own glass. A full-width plate
    // welded to the bottom edge was the one surface in the app that looked
    // borrowed from somewhere else.
    // The margin is *inside* the height, not added to it. The slot is shared
    // with the keyboard down to the point — see [KeyboardSlotPanel] — and an
    // island that answered "the keyboard's height plus ten" made the composer
    // drift by that ten every time the two swapped.
    return SizedBox(
      height: widget.height,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: AppColors.pane(0.86),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: AppColors.glass(0.14)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.32),
                blurRadius: 20,
                offset: const Offset(0, 8),
                spreadRadius: -12,
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
                        icon: Icons.emoji_emotions_outlined,
                        active: !_stickers,
                        onTap: () => setState(() => _stickers = false),
                      ),
                      const SizedBox(width: 8),
                      _Tab(
                        label: t.attachStickers,
                        icon: Icons.auto_awesome_outlined,
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
    setState(() => _inset = next);
    // Zero left to show and a keyboard in front of it: the swap is complete.
    if (widget.open && !_toldParent && next > _presence && _slack <= 0.5) {
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
