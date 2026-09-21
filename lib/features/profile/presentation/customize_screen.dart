import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/routing/app_shell.dart' show tabSpecFor;
import '../../../core/theme/colors.dart';
import '../../../core/theme/glass_tier.dart';
import '../../../core/theme/theme_controller.dart';
import '../../../core/theme/typography.dart';
import '../../../core/util/image_encode.dart' show MediaQuality;
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../core/widgets/hue_strip.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/data/reaction_emoji_controller.dart';
import '../../chat/presentation/widgets/emoji_picker_sheet.dart';
import '../../chats/data/archive_visibility_controller.dart';
import '../../chats/data/swipe_action_controller.dart';
import '../../chats/presentation/widgets/swipe_action_row.dart';
import '../data/audio_focus_controller.dart';
import '../data/media_quality_controller.dart';
import '../data/nav_bar_controller.dart';
import '../data/ui_scale_controller.dart';

/// The bits of the app that are the user's to arrange.
///
/// Pulled out of the App group in Settings, where the interface size sat
/// between the theme picker and the language list as one more row. Those are
/// *preferences* — pick one of a fixed set. This is a different kind of thing:
/// the shape of the app, decided by dragging. Given its own screen so the
/// dragging has room, and so the bar can be edited while you can still see what
/// you are doing to it.
class CustomizeScreen extends ConsumerWidget {
  const CustomizeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final layout = ref.watch(navBarControllerProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: BackButton(color: AppColors.textOnGlass),
        title: Text(
          t.customizeTitle,
          style: AppTypography.heading(size: 18, color: AppColors.textOnGlass),
        ),
        actions: [
          if (!layout.isDefault)
            TextButton(
              onPressed: () =>
                  ref.read(navBarControllerProvider.notifier).reset(),
              child: Text(
                t.customizeReset,
                style: TextStyle(color: AppColors.brandPrimary, fontSize: 13),
              ),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 140),
          children: [
            // Colour first. It is the change you see from across the room, and
            // the one people come here for.
            const _ThemeCard(),
            const SizedBox(height: 12),
            const _ScaleCard(),
            const SizedBox(height: 12),
            // Beside the scale, because both are "how this looks on *my*
            // phone" rather than a preference about the app.
            const _GlassCard(),
            const SizedBox(height: 12),
            const _SwipeCard(),
            const SizedBox(height: 12),
            // Next to the swipe, because archiving is what the swipe does by
            // default and this decides whether the result is visible.
            const _ArchiveRowCard(),
            const SizedBox(height: 12),
            const _QuickReactionCard(),
            const SizedBox(height: 12),
            const _CircleAudioCard(),
            const SizedBox(height: 12),
            // Beside the circle's sound: both are about what a message you
            // send costs, not about how the app looks.
            const _MediaQualityCard(),
            const SizedBox(height: 12),
            _NavBarCard(layout: layout),
          ],
        ),
      ),
    );
  }
}

/// Palette swatches. A row of the actual colours rather than a list of names:
/// the thing being chosen is how the app looks, so it should be shown, not
/// described.
class _ThemeCard extends ConsumerWidget {
  const _ThemeCard();

  static String _label(AppLocalizations t, String id) => switch (id) {
        'indigo' => t.profileThemeIndigo,
        'amber' => t.profileThemeAmber,
        'rose' => t.profileThemeRose,
        'fuchsia' => t.profileThemeFuchsia,
        'violet' => t.profileThemeViolet,
        'ocean' => t.profileThemeOcean,
        'slate' => t.profileThemeSlate,
        _ => t.profileThemeEmerald,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final current = ref.watch(themeControllerProvider);
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.profileTheme,
            style: TextStyle(
              color: AppColors.textOnGlass,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 62,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: AppPalette.all.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (_, i) {
                final palette = AppPalette.all[i];
                final selected = palette.id == current.id;
                return GestureDetector(
                  onTap: () => ref
                      .read(themeControllerProvider.notifier)
                      .select(palette),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // The swatch is the palette in miniature, not just its
                      // accent: the disc is the background the app will
                      // actually wear, the crescent inside it the brand over
                      // that background. A palette recolours the whole
                      // interface, so a swatch showing only the accent would
                      // be advertising the smaller half of the change.
                      Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [palette.bgTop, palette.bgDeep],
                          ),
                          border: Border.all(
                            color:
                                selected ? Colors.white : AppColors.glass(0.22),
                            width: selected ? 2.5 : 1,
                          ),
                        ),
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                palette.brandPrimary,
                                palette.brandSecondary,
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        _label(t, palette.id),
                        // Never scaled: the labels sit under 36-point discs in
                        // a horizontal strip, and at the largest interface size
                        // they would collide with their neighbours.
                        textScaler: TextScaler.noScaling,
                        style: TextStyle(
                          color: selected
                              ? AppColors.textOnGlass
                              : AppColors.textOnGlassDim,
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 14),
          // A hue of one's own, for a colour that is not among the eight.
          //
          // The wheel picks the *hue* and nothing else: saturation and
          // lightness stay at the values the hand-made palettes converged on,
          // because those five colours are tuned against each other and a
          // free-floating pick lands as unreadable text about as often as not
          // — see the note at the top of `theme_controller.dart`, which is
          // where this restraint is explained and where the ratios live.
          HueStrip(
            selected: current.isCustom,
            hue: current.hue ?? 210,
            onPick: (h) => unawaited(
              ref.read(themeControllerProvider.notifier).select(
                    AppPalette.hue(h),
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// How big the app draws itself. Moved here whole from the App group.
///
/// The same build lands visibly larger on one phone than on another — Android's
/// Display size and iOS's Larger Text both feed the text scaler, and neither is
/// visible from inside the app. Following the phone stays the default, because
/// someone who made everything bigger meant this too; the other three are for
/// the phone that was tuned for something else.
///
/// Whether panes blur what is behind them.
///
/// Offered rather than decided silently. Automatic measures the phone once and
/// remembers the answer, which is right for almost everybody — but a person who
/// wants the full glass on a slow phone is allowed to have it, and a person who
/// would rather have the frames than the effect on a fast one is too. Taking an
/// interface away from somebody without a way back is the thing this row
/// exists to avoid.
class _GlassCard extends ConsumerWidget {
  const _GlassCard();

  /// One segment's label: centred, one line, and shrunk if it has to be.
  static Widget _tierLabel(String text) => FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          text,
          maxLines: 1,
          softWrap: false,
          textAlign: TextAlign.center,
        ),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final current = ref.watch(glassTierControllerProvider);
    final notifier = ref.read(glassTierControllerProvider.notifier);
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.profileGlass,
            style: TextStyle(
              color: AppColors.textOnGlass,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          SegmentedButton<GlassTier>(
            // One line each, and shrunk to fit rather than wrapped.
            //
            // "Автоматично" and "Полегшене" are eleven and nine characters
            // against a third of a phone's width, so both wrapped onto a
            // second line — which made the control two rows tall and left
            // "Повне", the one word short enough to fit, floating in the
            // middle of a box sized by its neighbours. Three segments of
            // different heights and one label sitting at a different level to
            // the others is what was reported as not lined up.
            //
            // `scaleDown` only ever shrinks: a label that fits is drawn at its
            // proper size, and the two that do not lose a point or two rather
            // than a whole row. Tighter horizontal padding first, so most
            // phones never reach the shrinking at all.
            //
            // The full width of the card, in equal thirds. Sized by its labels
            // the control was a different width at every interface size: at
            // 85% it stopped well short of the card's right edge, so the
            // three words sat bunched to the left, and at 130% "Полегшене"
            // ran past the edge. Captured at 0.85/1.0/1.3 with the real font
            // before the change - "when the scale changes the text floats
            // left" was the report. With a fixed width `scaleDown` has a bound
            // to shrink into.
            expandedInsets: EdgeInsets.zero,
            style: SegmentedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
            ),
            segments: [
              ButtonSegment(
                value: GlassTier.auto,
                label: _tierLabel(t.profileGlassAuto),
              ),
              ButtonSegment(
                value: GlassTier.full,
                label: _tierLabel(t.profileGlassFull),
              ),
              ButtonSegment(
                value: GlassTier.light,
                label: _tierLabel(t.profileGlassLight),
              ),
            ],
            selected: {current},
            showSelectedIcon: false,
            onSelectionChanged: (picked) =>
                unawaited(notifier.set(picked.first)),
          ),
          const SizedBox(height: 8),
          Text(
            t.profileGlassHint,
            style: TextStyle(
              color: AppColors.textOnGlassDim,
              fontSize: 12,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

/// A preview of the actual size sits under the row, so the choice can be made
/// by looking rather than by guessing what "Larger" means here.
class _ScaleCard extends ConsumerWidget {
  const _ScaleCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final current = ref.watch(uiScaleControllerProvider);
    final notifier = ref.read(uiScaleControllerProvider.notifier);
    // Where the thumb sits while following the phone. Not a value being used —
    // the slider is switched off then — but a slider whose thumb is parked at
    // one end looks broken, and this is where dragging it will start.
    final shown = current.factor ?? 1.0;
    final divisions =
        ((UiScale.maxFactor - UiScale.minFactor) / UiScale.step).round();
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  t.profileScale,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                // A percentage, which needs no translating and says exactly
                // what the number means.
                current.followsSystem
                    ? t.profileScaleSystem
                    : '${(shown * 100).round()}%',
                style: TextStyle(
                  color: AppColors.textOnGlassDim,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: AppColors.brandPrimary,
              inactiveTrackColor: AppColors.glass(0.18),
              thumbColor: current.followsSystem
                  ? AppColors.textOnGlassFaint
                  : AppColors.brandPrimary,
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            ),
            child: Slider(
              value: shown.clamp(UiScale.minFactor, UiScale.maxFactor),
              min: UiScale.minFactor,
              max: UiScale.maxFactor,
              divisions: divisions,
              // Dragging is itself the decision to stop following the phone —
              // asking somebody to turn the override on first, and only then
              // to choose a size, is a step that exists for the code's benefit.
              onChanged: (v) => unawaited(notifier.select(UiScale.of(v))),
            ),
          ),
          _Pill(
            label: t.profileScaleSystem,
            active: current.followsSystem,
            onTap: () => unawaited(notifier.select(UiScale.system)),
          ),
          const SizedBox(height: 12),
          Text(
            t.profileScaleSample,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

// The refresh rate was briefly a switch here, and that was the wrong shape for
// it: somebody holding a warm phone should not have to be told which of two
// numbers their GPU prefers. The app states 60 and the reasoning lives in
// `main.dart`, next to the call that says it.

/// Which emoji a double-tap on a message leaves.
///
/// The app already learns this — the strip is the six you reached for most
/// recently and the quick reaction is whichever is at the front — so a heart
/// only stays the default until you use something else. That is the right
/// behaviour and it is also invisible: nothing said the heart could be changed,
/// or what it currently was. This says both, and setting one is the same act
/// the learning already performs, so there is no second source of truth.
class _QuickReactionCard extends ConsumerWidget {
  const _QuickReactionCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final recent = ref.watch(reactionEmojiControllerProvider);
    final controller = ref.read(reactionEmojiControllerProvider.notifier);
    final current = controller.quickReaction;

    // The recent six, plus any stock emoji not among them — so the choice is
    // never narrower than the list it started as.
    final offered = <String>[
      ...recent,
      ...ReactionEmojiController.defaults.where((e) => !recent.contains(e)),
    ];

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.customizeQuickReaction,
            style: TextStyle(
              color: AppColors.textOnGlass,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            t.customizeQuickReactionHint,
            style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final emoji in offered)
                _EmojiChoice(
                  emoji: emoji,
                  active: emoji == current,
                  // Choosing one is exactly what using one does: move it to the
                  // front of the recents. One mechanism, so the setting and the
                  // habit can never disagree.
                  onTap: () => controller.remember(emoji),
                ),
              // The whole keyboard, for anybody whose emoji is not among these.
              _EmojiChoice(
                emoji: null,
                active: false,
                onTap: () async {
                  final picked = await showEmojiPicker(context);
                  if (picked != null) await controller.remember(picked);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmojiChoice extends StatelessWidget {
  const _EmojiChoice({
    required this.emoji,
    required this.active,
    required this.onTap,
  });

  /// Null draws the "open the picker" tile.
  final String? emoji;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 46,
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active
              ? AppColors.brandPrimary.withValues(alpha: 0.22)
              : AppColors.glass(0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active
                ? AppColors.brandPrimary.withValues(alpha: 0.7)
                : AppColors.glass(0.15),
            width: active ? 2 : 1,
          ),
        ),
        child: emoji == null
            ? Icon(
                Icons.add_reaction_outlined,
                size: 20,
                color: AppColors.textOnGlassDim,
              )
            : Text(
                emoji!,
                textScaler: TextScaler.noScaling,
                style: const TextStyle(fontSize: 22),
              ),
      ),
    );
  }
}

/// What a swipe on a chat row does.
///
/// One choice rather than a configurable tray, and rightward only — see
/// [SwipeActionRow] for why the direction is the whole reason this can exist
/// alongside the sideways drag between tabs. The hint under the title says so,
/// because somebody who has just given the right swipe a job will reasonably
/// wonder what happened to the gesture they had.
class _SwipeCard extends ConsumerStatefulWidget {
  const _SwipeCard();

  static String label(AppLocalizations t, ChatSwipeAction a) => switch (a) {
        ChatSwipeAction.archive => t.customizeSwipeArchive,
        ChatSwipeAction.mute => t.customizeSwipeMute,
        ChatSwipeAction.pin => t.customizeSwipePin,
        ChatSwipeAction.markRead => t.customizeSwipeRead,
        ChatSwipeAction.delete => t.customizeSwipeDelete,
        ChatSwipeAction.none => t.customizeSwipeNone,
      };

  @override
  ConsumerState<_SwipeCard> createState() => _SwipeCardState();
}

/// Telegram's own control for the same setting, asked for by name with a
/// recording of it: a chat row on the left that slides to show what the swipe
/// will do, and a wheel on the right that loops, the chosen word held between
/// two coloured rules.
///
/// Chips did the same job and said less. A row of six words is a list to read;
/// a row that moves when the wheel moves shows the gesture itself, which is the
/// thing somebody choosing this is actually trying to picture.
class _SwipeCardState extends ConsumerState<_SwipeCard>
    with SingleTickerProviderStateMixin {
  static const double _itemExtent = 40;
  static const double _height = 132;

  late final FixedExtentScrollController _wheel;

  /// Replays the swipe in the preview each time the choice changes: the row
  /// slides back, then out again to show the new panel. One shot per change,
  /// never a loop - see the glass-ui rule about tickers that never stop.
  late final AnimationController _swipe;

  static int _indexOf(ChatSwipeAction action) =>
      ChatSwipeAction.values.indexOf(action);

  @override
  void initState() {
    super.initState();
    _wheel = FixedExtentScrollController(
      initialItem: _indexOf(ref.read(chatSwipeActionProvider)),
    );
    _swipe = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
      value: 1,
    );
  }

  @override
  void dispose() {
    _wheel.dispose();
    _swipe.dispose();
    super.dispose();
  }

  /// The wheel loops, so its item index grows without bound; the action is the
  /// index modulo the list.
  ChatSwipeAction _actionAt(int item) {
    final values = ChatSwipeAction.values;
    return values[item % values.length];
  }

  void _picked(int item) {
    final action = _actionAt(item);
    if (action == ref.read(chatSwipeActionProvider)) return;
    HapticFeedback.selectionClick();
    ref.read(chatSwipeActionProvider.notifier).select(action);
    _swipe.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final current = ref.watch(chatSwipeActionProvider);

    // The saved choice arrives from storage after the first frame. Move the
    // wheel to it rather than leaving the default under the rules.
    ref.listen<ChatSwipeAction>(chatSwipeActionProvider, (previous, next) {
      if (!_wheel.hasClients) return;
      if (_actionAt(_wheel.selectedItem) == next) return;
      _wheel.jumpToItem(_indexOf(next));
    });

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.customizeSwipeTitle,
            style: TextStyle(
              color: AppColors.brandPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: _height,
            child: Row(
              children: [
                Expanded(
                  flex: 11,
                  child: Center(
                    child: _SwipePreview(action: current, swipe: _swipe),
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(flex: 10, child: _wheelPicker(t)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            t.customizeSwipeHint,
            style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  Widget _wheelPicker(AppLocalizations t) {
    final rule = Container(
      height: 2,
      decoration: BoxDecoration(
        color: AppColors.brandPrimary.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(1),
      ),
    );
    return Stack(
      alignment: Alignment.center,
      children: [
        ListWheelScrollView.useDelegate(
          controller: _wheel,
          itemExtent: _itemExtent,
          physics: const FixedExtentScrollPhysics(),
          // Nearly flat, like the Android number picker Telegram uses: the
          // neighbours fade rather than tilting away on a drum.
          diameterRatio: 3.2,
          perspective: 0.001,
          overAndUnderCenterOpacity: 0.42,
          onSelectedItemChanged: _picked,
          childDelegate: ListWheelChildLoopingListDelegate(
            children: [
              for (final action in ChatSwipeAction.values)
                Center(
                  child: Text(
                    _SwipeCard.label(t, action),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(
                      color: AppColors.textOnGlass,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
            ],
          ),
        ),
        // The two rules the chosen item sits between. Inert, so a drag that
        // starts on one still turns the wheel.
        IgnorePointer(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              rule,
              const SizedBox(height: _itemExtent - 2),
              rule,
            ],
          ),
        ),
      ],
    );
  }
}

/// A chat row mid-swipe, showing the panel the chosen action reveals.
///
/// Drawn from shapes rather than from a real chat: it is a picture of the
/// gesture, and somebody's actual conversation in a settings screen is both
/// noise and a thing they did not ask to see here.
class _SwipePreview extends StatelessWidget {
  const _SwipePreview({required this.action, required this.swipe});

  final ChatSwipeAction action;
  final Animation<double> swipe;

  @override
  Widget build(BuildContext context) {
    final off = action == ChatSwipeAction.none;
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth;
        const height = 64.0;
        // How far the row stands open: about the width of the panel's icon
        // cell, the same travel the real row needs before it fires.
        final open = (width * 0.30).clamp(56.0, 84.0);
        return SizedBox(
          width: width,
          height: height,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              children: [
                // The panel. Rightward, like the list itself: it opens on the
                // left, under where the row was.
                Positioned.fill(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    color: off
                        ? AppColors.glass(0.10)
                        : action.color.withValues(alpha: 0.88),
                    alignment: Alignment.centerLeft,
                    padding: EdgeInsets.only(left: (open - 26) / 2),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      transitionBuilder: (child, animation) => ScaleTransition(
                        scale: animation,
                        child: FadeTransition(opacity: animation, child: child),
                      ),
                      child: Icon(
                        action.icon,
                        key: ValueKey(action),
                        size: 26,
                        color: off ? AppColors.textOnGlassDim : Colors.white,
                      ),
                    ),
                  ),
                ),
                AnimatedBuilder(
                  animation: swipe,
                  builder: (context, child) {
                    // Back to closed for the first third, then out again, so
                    // every change of the wheel reads as one fresh swipe.
                    final t = swipe.value;
                    final shown = t < 0.3
                        ? 1 - Curves.easeIn.transform(t / 0.3)
                        : Curves.easeOutBack.transform((t - 0.3) / 0.7);
                    return Transform.translate(
                      offset: Offset(open * shown, 0),
                      child: child,
                    );
                  },
                  child: Container(
                    width: width,
                    height: height,
                    decoration: BoxDecoration(
                      color: AppColors.bgDeep,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.glass(0.14)),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.glass(0.18),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _bar(0.45, 0.30),
                              const SizedBox(height: 8),
                              _bar(0.85, 0.18),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static Widget _bar(double widthFactor, double alpha) => FractionallySizedBox(
        widthFactor: widthFactor,
        child: Container(
          height: 6,
          decoration: BoxDecoration(
            color: AppColors.glass(alpha),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      );
}

/// Whether a round message stops the phone's music.
///
/// One switch for recording and for watching, because they are the same
/// question asked twice — if music should stop while you watch a circle, it
/// should stop while you record one. Off by default, which is what every build
/// so far has done: the music keeps playing, ducked on Android. See
/// [AudioSession.takesFocus] for what each answer does to the session.
class _CircleAudioCard extends ConsumerWidget {
  const _CircleAudioCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final exclusive = ref.watch(audioFocusProvider);

    return GlassCard(
      child: Row(
        children: [
          Icon(
            exclusive ? Icons.music_off_rounded : Icons.music_note_rounded,
            size: 20,
            color: AppColors.textOnGlass,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.customizeCircleAudioTitle,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  exclusive
                      ? t.customizeCircleAudioOn
                      : t.customizeCircleAudioOff,
                  style: TextStyle(
                    color: AppColors.textOnGlassDim,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: exclusive,
            activeColor: AppColors.brandPrimary,
            onChanged: (next) =>
                unawaited(ref.read(audioFocusProvider.notifier).set(next)),
          ),
        ],
      ),
    );
  }
}

/// How hard a photo is squeezed before it leaves — see
/// [MediaQualityController].
///
/// Built like the glass card: three segments across the card's full width,
/// each label shrunk rather than wrapped, and the hint under the control
/// changing with the choice so it always says what *this* setting costs.
class _MediaQualityCard extends ConsumerWidget {
  const _MediaQualityCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final current = ref.watch(mediaQualityProvider);
    final notifier = ref.read(mediaQualityProvider.notifier);
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.customizeMediaQualityTitle,
            style: TextStyle(
              color: AppColors.textOnGlass,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          SegmentedButton<MediaQuality>(
            expandedInsets: EdgeInsets.zero,
            style: SegmentedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
            ),
            segments: [
              ButtonSegment(
                value: MediaQuality.economy,
                label: _GlassCard._tierLabel(t.customizeMediaQualityEconomy),
              ),
              ButtonSegment(
                value: MediaQuality.standard,
                label: _GlassCard._tierLabel(t.customizeMediaQualityStandard),
              ),
              ButtonSegment(
                value: MediaQuality.high,
                label: _GlassCard._tierLabel(t.customizeMediaQualityHigh),
              ),
            ],
            selected: {current},
            showSelectedIcon: false,
            onSelectionChanged: (picked) =>
                unawaited(notifier.set(picked.first)),
          ),
          const SizedBox(height: 8),
          Text(
            switch (current) {
              MediaQuality.economy => t.customizeMediaQualityEconomyHint,
              MediaQuality.standard => t.customizeMediaQualityStandardHint,
              MediaQuality.high => t.customizeMediaQualityHighHint,
            },
            style: TextStyle(
              color: AppColors.textOnGlassDim,
              fontSize: 12,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

/// Bring the archive row back, or put it away from here.
///
/// The row can also be hidden by holding it, which is the gesture anybody
/// annoyed by it will reach for. This is the other half of that: a control
/// that only disappears has no way back, and "hold the row" is no use once
/// there is no row to hold.
class _ArchiveRowCard extends ConsumerWidget {
  const _ArchiveRowCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(archiveVisibleProvider);
    final uk = Localizations.localeOf(context).languageCode == 'uk';

    return GlassCard(
      child: Row(
        children: [
          Icon(
            visible ? Icons.inventory_2_rounded : Icons.visibility_off_rounded,
            size: 20,
            color: AppColors.textOnGlass,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  uk ? 'Рядок архіву' : 'Archive row',
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  uk
                      ? 'Показувати згори списку чатів. Приховані чати далі '
                          'отримують повідомлення.'
                      : 'Show it above the chat list. Archived conversations '
                          'keep receiving either way.',
                  style: TextStyle(
                    color: AppColors.textOnGlassDim,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: visible,
            activeColor: AppColors.brandPrimary,
            onChanged: (next) =>
                ref.read(archiveVisibleProvider.notifier).set(next),
          ),
        ],
      ),
    );
  }
}

/// The bar itself: what is on it, in what order, and what has been put away.
class _NavBarCard extends ConsumerWidget {
  const _NavBarCard({required this.layout});

  final NavBarLayout layout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final controller = ref.read(navBarControllerProvider.notifier);
    final hidden = layout.hidden;

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.customizeBarTitle,
            style: TextStyle(
              color: AppColors.textOnGlass,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            t.customizeBarHint,
            style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
          ),
          const SizedBox(height: 12),
          _SectionLabel(text: t.customizeBarShown),
          // shrinkWrap because this list is a section of a card inside a page
          // that already scrolls; the drag still works, it simply has no
          // scrolling of its own to do.
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: layout.shown.length,
            onReorder: (from, to) {
              // ReorderableListView reports the target as an insertion index in
              // the *pre-removal* list, so moving an item downward is one place
              // further than where it should end up.
              controller.reorder(from, to > from ? to - 1 : to);
              HapticFeedback.selectionClick();
            },
            proxyDecorator: (child, _, __) => Material(
              color: Colors.transparent,
              child: child,
            ),
            itemBuilder: (context, i) {
              final destination = layout.shown[i];
              final spec = tabSpecFor(destination, t);
              final pinned = destination == NavDestination.chats;
              final last = layout.shown.length <= NavBarController.minimumTabs;
              return _TabRow(
                key: ValueKey(destination),
                index: i,
                icon: spec.activeIcon,
                label: spec.label,
                // Chats cannot leave, and neither can anything else once the
                // bar is down to two — both refusals are explained rather than
                // shown as a dead button.
                trailing: pinned
                    ? Icon(Icons.lock_rounded,
                        size: 16, color: AppColors.textOnGlassFaint)
                    : _RowButton(
                        icon: Icons.remove_circle_outline_rounded,
                        color: last
                            ? AppColors.textOnGlassFaint
                            : AppColors.danger,
                        onTap: () async {
                          final removed = await controller.hide(destination);
                          if (!removed && context.mounted) {
                            showGlassToast(context, t.customizeBarMinimum);
                          }
                        },
                      ),
              );
            },
          ),
          const SizedBox(height: 8),
          _SectionLabel(text: t.customizeBarHidden),
          if (hidden.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 0, 10),
              child: Text(
                t.customizeBarHiddenEmpty,
                style: TextStyle(
                  color: AppColors.textOnGlassFaint,
                  fontSize: 12.5,
                ),
              ),
            )
          else
            for (final destination in hidden)
              _TabRow(
                key: ValueKey('hidden-${destination.name}'),
                icon: tabSpecFor(destination, t).icon,
                label: tabSpecFor(destination, t).label,
                dimmed: true,
                trailing: _RowButton(
                  icon: Icons.add_circle_outline_rounded,
                  color: AppColors.brandPrimary,
                  onTap: () => controller.show(destination),
                ),
              ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 2),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            color: AppColors.textOnGlassFaint,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
      );
}

/// One destination, on the bar or off it.
class _TabRow extends StatelessWidget {
  const _TabRow({
    super.key,
    required this.icon,
    required this.label,
    required this.trailing,
    this.index,
    this.dimmed = false,
  });

  final IconData icon;
  final String label;
  final Widget trailing;

  /// Position in the reorderable list, when this row is one that can be
  /// dragged. Null for a hidden tab, which has no order to have.
  final int? index;

  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final ink = dimmed ? AppColors.textOnGlassFaint : AppColors.textOnGlass;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: dimmed
                  ? AppColors.glass(0.06)
                  : AppColors.brandPrimary.withValues(alpha: 0.16),
              border: Border.all(
                color: dimmed
                    ? AppColors.glass(0.14)
                    : AppColors.brandPrimary.withValues(alpha: 0.36),
              ),
            ),
            child: Icon(
              icon,
              size: 17,
              color:
                  dimmed ? AppColors.textOnGlassFaint : AppColors.brandPrimary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: ink, fontSize: 14.5),
            ),
          ),
          trailing,
          if (index != null) ...[
            const SizedBox(width: 4),
            // The grip is the only thing that starts a drag, the same rule the
            // pinned chats follow: a row you can drag by anywhere is a row you
            // cannot scroll past.
            ReorderableDragStartListener(
              index: index!,
              child: SizedBox(
                width: 34,
                height: 40,
                child: Icon(
                  Icons.drag_handle_rounded,
                  size: 20,
                  color: AppColors.textOnGlassFaint,
                ),
              ),
            ),
          ],
        ],
      ),
    );
    return Padding(padding: EdgeInsets.zero, child: row);
  }
}

class _RowButton extends StatelessWidget {
  const _RowButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton(
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
        icon: Icon(icon, size: 20, color: color),
      );
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: active ? AppColors.brandGradient : null,
          color: active ? null : AppColors.glass(0.08),
          border: Border.all(
            color: active ? AppColors.glass(0.3) : AppColors.glass(0.15),
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          // Fixed, and deliberately not scaled: these four pills are how you
          // *change* the scale, so they have to stay reachable at every
          // setting — including the one that broke the layout.
          textScaler: TextScaler.noScaling,
          style: TextStyle(
            color: AppColors.textOnGlass,
            fontSize: 12.5,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
