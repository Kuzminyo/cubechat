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
· `glass_toast` · `undo_toast` · `context_popup` · `pill_button` · `identity_avatar`
· `cube_logo` · `appear_animation` · `unread_badge` · `confirm_dialog`
· `triple_tap_detector` · `hue_strip` · `circle_video_icon` · `view_once_icon`

**Editing anything in `lib/features/chat/`? Read `lib/features/chat/README.md`
first.** It holds the module's three load-bearing rules — the transcript is
addressed by index (never filter the source list), bubbles are keyed by message
id, and a received message is stamped on arrival rather than on send — plus a
list of things already tried there and rejected.

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

## Blur: how it is wired now

All of it lives in `lib/core/theme/glass.dart` and `glass_tier.dart`.

- **`AppBlur.sigma` is 14. Do not lower it.** The panes are filled at 52–66%
  opacity, so past about a dozen pixels a gaussian of a mostly-hidden backdrop
  is indistinguishable, and a drop to 9 was shipped and reverted. If one surface
  needs a different radius, give that surface its own constant and say why.
- **`GlassTier`** — `auto`, `full`, `light` — decides whether panes filter at
  all. `auto` measures the GPU once and remembers; the choice is stable, made at
  startup or by a tap in Customize, **never per frame**.
- **A conversation's islands share one backdrop read.** Header, pinned bar and
  composer sit inside a `BackdropGroup` the chat screen sets up
  (`AppBlur.groupedPanes`), so three panes cost one read of what is behind them.
  Panes elsewhere, and `FloatingGlass`, still filter on their own. The islands
  keep blurring through a route slide on purpose — turning it off flickers,
  reported twice.
- **The nav bar no longer blurs.**

**Do not treat the blur as the expensive thing.** That sentence was retired on
2026-09-04: on a phone with a healthy frame budget the whole gaussian is worth a
couple of points of one core. What the raster thread actually spends its time on
is full-screen gradients and the translucent fills over them, so the lever is
drawing less area. `test/layer_budget_test.dart` counts the passes that render to
a texture of their own per screen and fails if they grow. The measurements are
in the `perf-triage` skill.

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
