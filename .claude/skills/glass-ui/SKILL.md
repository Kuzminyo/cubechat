---
name: glass-ui
description: UI conventions for cubechat's glassmorphism interface. Load when editing any screen or widget under lib/features/**/presentation or lib/core/widgets, changing colours, blur, the theme, layout of the chat screen, or adding an animation.
user-invocable: true
---

# The glass interface

Flutter + Riverpod (Notifier pattern) + `go_router` with a `StatefulShellRoute`
so tab branches stay mounted. `lib/core/widgets/` holds the shared primitives —
look there before writing a new one:

`aurora_background` · `bar_glass` · `floating_glass` · `glass_card` · `glass_sheet`
· `glass_toast` · `context_popup` · `pill_button` · `identity_avatar` · `cube_logo`
· `appear_animation` · `unread_badge` · `confirm_dialog` · `triple_tap_detector`

## There is no AppBar

The chat header capsule, the pinned island and the composer are three siblings of
the message list inside one `Stack`, each carrying the same glass. The
conversation runs edge to edge behind them.

**The list's top and bottom padding is measured, not guessed.** Both ends change
height — the composer grows with multi-line text and the reply island, the header
gains and loses the pinned bar and the folder row. Search `chat_screen.dart` for
"measured off this column" to find the mechanism, and keep any new bar inside
that column rather than adding a fixed offset.

This also fixed a real bug: the pinned island appearing used to re-parent the
list, detaching the scroll position and snapping the conversation to the bottom
mid-read. A change that re-parents the list reintroduces it.

## Colours are mutable statics

`AppColors` (`lib/core/theme/colors.dart`) is a class of mutable static fields
that `ThemeController` rewrites when a palette is chosen. That is why palettes
retint the interface itself and not just the accents: `glassBase` is white pulled
some way toward the palette's tint, so a rose theme is a rose interface rather
than a grey one with pink buttons.

Read colours through `AppColors`. A hardcoded `Colors.white` or a literal hex is
a surface that will not follow the theme.

## Blur is the GPU budget

`AppBlur.sigma` in `lib/core/theme/glass.dart` is **14**, and it is a measured
number, not a taste call. On a mid-range Android scrolling a chat:

```
build  (CPU / Dart)   avg 1.2   p90  1.7 ms
raster (GPU)          avg 6.3   p90 11.7 ms
```

Three `BackdropFilter`s are permanently on screen in a conversation — nav bar,
header, composer — and each re-runs the gaussian on every frame the content
behind it moves. Two earlier rounds of optimisation went entirely into the 1.2 ms
column and the phone was exactly as warm afterwards.

14 rather than 30 because the panes are filled at 52–66% opacity; past roughly a
dozen pixels of radius, a gaussian of a mostly-hidden backdrop stops being
distinguishable. It went to 9 for an hour on 2026-08-17 and came back — not
because 9 was wrong, but because it shipped alongside a refresh-rate change that
made the app barely usable, and reverting one unverified change while leaving
another on top of it is not a revert.

**If a surface needs a different radius, give that surface its own constant and
say why.** Raising this one returns the cost everywhere at once.

Group `BackdropFilter`s where you can — ungrouped ones each snapshot the backdrop
separately.

## Animation parks when nothing is happening

`UiActivity` (`lib/core/util/ui_activity.dart`) is one process-wide signal that
arms a countdown on any touch. Decorative animation subscribes to it instead of
running a ticker forever — a ticker running is a frame scheduled, and with one
online peer on screen the app otherwise never reaches a still frame, compositing
at 120 Hz on ProMotion while the user just reads.

Rules that follow:

- No always-on ticker. Subscribe to `UiActivity`, or drive off a wall clock at a
  low rate the way the aurora does (~30 fps, paused while backgrounded).
- One shared signal, not a timer per widget — a chat list holds a dozen online
  dots.
- The aurora is a single `CustomPainter` so it never rebuilds the widget tree.
  Keep it that way.
- Animate what every touch does, not what happens rarely. A whole animation
  branch was written and deleted on 2026-08-17 for being polish ahead of a
  measured problem.
- Decode images at the size they are drawn. Uncapped `Image.file` decodes were a
  real, measured cost; gallery thumbnails set `cacheWidth`/`cacheHeight`.

## Localization

Every user-visible string goes through `AppLocalizations`. Add the key to both
`lib/l10n/app_en.arb` and `lib/l10n/app_uk.arb` — they are currently at 595 keys
each and in sync — then run `flutter gen-l10n` and commit the regenerated
`app_localizations*.dart`, which are checked in.
