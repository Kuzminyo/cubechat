import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/theme/glass.dart';

/// One row of the action list under a spotlit message.
@immutable
class SpotlightAction {
  const SpotlightAction({
    required this.id,
    required this.icon,
    required this.label,
    this.tone,
  });

  final String id;
  final IconData icon;
  final String label;

  /// Null for the ordinary ink; a colour for the one or two that destroy
  /// something.
  final Color? tone;
}

/// Hold a message and everything else steps back.
///
/// A popup menu anchored at the finger answers "what can I do to this?", and
/// answers it while the conversation carries on behind it at full contrast —
/// so the thing the menu is *about* is one of thirty similar objects on screen,
/// and the reaction strip at the top of it is a row of emoji floating over
/// somebody else's sentence. Every messenger worth copying solves this the same
/// way: blur the room, leave the message lit, and put the choices around it.
///
/// What this does **not** do is lift a snapshot of the bubble out of the list.
/// Capturing one is asynchronous — a frame of nothing between the press and the
/// menu — and a second frame's worth of pixels held in memory for every
/// long-press. The bubble is simply built again, inert, at the place the real
/// one occupies. It is the same widget from the same message, so it cannot
/// drift from what it is standing in for.
///
/// Returns the chosen action's id, `'r:<emoji>'` for a reaction from the strip,
/// `'r+'` for the picker, or null when dismissed — the same vocabulary the
/// popup menu it replaces already spoke, so the caller's switch is unchanged.
Future<String?> showMessageSpotlight({
  required BuildContext context,
  required Rect anchor,
  required Widget bubble,
  required List<String> reactions,
  required List<SpotlightAction> actions,
  Widget? details,
  bool mine = false,
}) {
  return Navigator.of(context, rootNavigator: true).push<String>(
    PageRouteBuilder<String>(
      opaque: false,
      barrierColor: null,
      barrierDismissible: false,
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (context, animation, _) => _Spotlight(
        animation: animation,
        anchor: anchor,
        bubble: bubble,
        reactions: reactions,
        actions: actions,
        details: details,
        mine: mine,
      ),
    ),
  );
}

class _Spotlight extends StatelessWidget {
  const _Spotlight({
    required this.animation,
    required this.anchor,
    required this.bubble,
    required this.reactions,
    required this.actions,
    required this.details,
    required this.mine,
  });

  final Animation<double> animation;
  final Rect anchor;
  final Widget bubble;
  final List<String> reactions;
  final List<SpotlightAction> actions;

  /// When it was sent, and who has read it — the one part of this menu that is
  /// information rather than a choice, so it sits above the choices and takes
  /// no tap.
  final Widget? details;

  final bool mine;

  /// Height of the reaction strip, and of the gap either side of the message.
  static const double _stripHeight = 52;
  static const double _gap = 10;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    final safeTop = media.padding.top + 8;
    final safeBottom = screen.height - media.padding.bottom - 8;

    final menuHeight = actions.length * 46.0 + 12 + (details == null ? 0 : 46);
    final wanted = _stripHeight + _gap + anchor.height + _gap + menuHeight;

    // Where the message sits once everything around it has been given room.
    //
    // Its own place, if the strip fits above and the menu below. Otherwise the
    // whole group is slid just far enough to fit, so a message near either edge
    // of the screen still gets both — and a conversation taller than the screen
    // gets the message pinned where it can be seen rather than pushed off it.
    var bubbleTop = anchor.top;
    final topLimit = safeTop + _stripHeight + _gap;
    final bottomLimit = safeBottom - menuHeight - _gap - anchor.height;
    if (wanted <= safeBottom - safeTop) {
      bubbleTop = bubbleTop.clamp(topLimit, bottomLimit);
    } else {
      bubbleTop = topLimit;
    }

    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    void close([String? result]) => Navigator.of(context).pop(result);

    return AnimatedBuilder(
      animation: curved,
      builder: (context, _) {
        final t = curved.value;
        return Stack(
          children: [
            // The room, stepping back. Tapping it anywhere is the way out —
            // which is the same gesture as dismissing the menu it replaces, and
            // the reason there is no explicit close button.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: close,
                // Clipped, and that is not decoration.
                //
                // A BackdropFilter with no clip around it has unbounded effect
                // bounds, and several backends answer that by rendering
                // nothing at all — which is what "there is no blur" was. Every
                // other blurred surface in this app sits inside a clip already
                // (FloatingGlass, BarGlass, the toast); this one was the
                // exception because it covers the whole screen and looked like
                // it needed no shape. It needs the shape to be drawn, not to be
                // rounded.
                child: ClipRect(
                  child: BackdropFilter(
                    // Never exactly zero while the route is present: a sigma of
                    // 0 is a filter that some backends optimise away entirely,
                    // and the first frame is the one that decides whether the
                    // layer gets built at all.
                    filter: ImageFilter.blur(
                      sigmaX: 0.001 + 14 * t,
                      sigmaY: 0.001 + 14 * t,
                    ),
                    child: ColoredBox(
                      color: AppColors.pane(0.45 * t),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            ),

            // The message, at full contrast and inert. Absorbing rather than
            // ignoring pointers: a tap on the message itself should close the
            // spotlight, not fall through to the blur and do it twice, and
            // certainly not open the photo underneath.
            Positioned(
              left: anchor.left,
              top: bubbleTop,
              width: anchor.width,
              child: Opacity(
                opacity: t,
                child: Transform.scale(
                  scale: 0.97 + 0.03 * t,
                  alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: GestureDetector(
                    onTap: close,
                    child: AbsorbPointer(child: bubble),
                  ),
                ),
              ),
            ),

            // The strip, above the message.
            if (reactions.isNotEmpty)
              Positioned(
                left: 12,
                right: 12,
                top: bubbleTop - _gap - _stripHeight,
                child: _Rise(
                  t: t,
                  from: 12,
                  child: _ReactionStrip(
                    reactions: reactions,
                    mine: mine,
                    onPick: (emoji) => close('r:$emoji'),
                    onMore: () => close('r+'),
                  ),
                ),
              ),

            // The actions, below it.
            Positioned(
              left: mine ? null : 12,
              right: mine ? 12 : null,
              top: bubbleTop + anchor.height + _gap,
              width: 232,
              child: _Rise(
                t: t,
                from: -12,
                child: _ActionSheet(
                  actions: actions,
                  details: details,
                  onPick: (id) => close(id),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Fades in while sliding [from] logical pixels into place.
class _Rise extends StatelessWidget {
  const _Rise({required this.t, required this.from, required this.child});

  final double t;
  final double from;
  final Widget child;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, from * (1 - t)),
          child: child,
        ),
      );
}

class _ReactionStrip extends StatelessWidget {
  const _ReactionStrip({
    required this.reactions,
    required this.mine,
    required this.onPick,
    required this.onMore,
  });

  final List<String> reactions;
  final bool mine;
  final ValueChanged<String> onPick;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: BackdropFilter(
          filter: AppBlur.pane,
          child: Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: AppColors.pane(0.72),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: AppColors.glass(0.16)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final emoji in reactions)
                  _StripButton(
                    onTap: () => onPick(emoji),
                    child: Text(
                      emoji,
                      textScaler: TextScaler.noScaling,
                      style: const TextStyle(fontSize: 24),
                    ),
                  ),
                // The way out of the shortlist. Whatever is chosen there joins
                // it, so the strip drifts toward the emoji actually used.
                _StripButton(
                  onTap: onMore,
                  child: Icon(
                    Icons.add_reaction_rounded,
                    size: 22,
                    color: AppColors.textOnGlassDim,
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

class _StripButton extends StatelessWidget {
  const _StripButton({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Padding(padding: const EdgeInsets.all(7), child: child),
        ),
      );
}

class _ActionSheet extends StatelessWidget {
  const _ActionSheet({
    required this.actions,
    required this.details,
    required this.onPick,
  });

  final List<SpotlightAction> actions;
  final Widget? details;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: AppBlur.pane,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.pane(0.72),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.glass(0.16)),
          ),
          child: Material(
            color: Colors.transparent,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (details != null) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: details,
                    ),
                  ),
                  Divider(height: 1, color: AppColors.glass(0.12)),
                ],
                for (final action in actions)
                  InkWell(
                    onTap: () => onPick(action.id),
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      child: Row(
                        children: [
                          Icon(
                            action.icon,
                            size: 19,
                            color: action.tone ?? AppColors.textOnGlass,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              action.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: action.tone ?? AppColors.textOnGlass,
                                fontSize: 14.5,
                              ),
                            ),
                          ),
                        ],
                      ),
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
