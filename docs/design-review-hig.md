# Design review: the interface against Apple's HIG

Reviewed 2026-08-28 against Apple's Human Interface Guidelines, read as
platform-agnostic rules rather than as iOS API advice — the app is Flutter and
ships to both phones, so "UITabBarController" is read as "the nav bar" and
"Dynamic Type" as `MediaQuery.textScaler`.

Six screens were pumped through Flutter's own machine-checkable accessibility
guidelines (chats, peers, contacts, profile, storage, backup); the rest of the
review is by reading, with the numbers computed rather than eyeballed.

**Verdict: good, with two accessibility gaps that were real.** The visual
system is coherent and unusually well-reasoned — most of what a review like
this normally finds (arbitrary spacing, a fourth typeface, a colour that means
two things) is already absent, and several of the constants carry the
measurement that put them there. What was missing was the *non-visual* half:
the interface had no answer for a phone whose owner had turned an accessibility
setting on.

---

## Critical — fixed on this branch

### 1. Reduce Motion was not read at all

**What.** The phone's Reduce Motion switch (iOS) / Remove animations (Android)
arrives as `MediaQuery.disableAnimations`. Nothing in the app read it. A user
who had turned it on still got the aurora drifting behind every screen, the
online dot breathing once per visible row, every list staggering itself into
view, and every push sliding sideways with a parallax under it.

**Why.** *Accessibility > Cognitive*: "Be cautious with fast-moving and
blinking animations… People who are prone to these effects can turn on the
Reduce Motion accessibility setting. When this setting is active, ensure your
app responds by reducing automatic and repetitive animations, including
zooming, scaling, and peripheral motion." The two largest pieces of motion here
— a full-screen gradient that never stops, and a pulse repeated once per row —
are precisely the named pattern: automatic, repetitive, peripheral.

**Fix.** `lib/core/util/motion.dart` (`AppMotion`) is the single reader. Under
it the aurora holds a still frame, the online dot parks lit, an entrance is
simply there, and a push cross-fades. The guidance asks for x/y/z travel to be
*replaced* by a fade rather than removed — something still has to say the
screen changed — so the transition survives as a fade, with the edge-back
gesture still attached to it.

Covered by `test/reduce_motion_test.dart`.

### 2. The quietest tier of text was below the contrast floor

**What.** `AppColors.textOnGlassFaint` — timestamps, hints, the line under a
row, read at 99 call sites — was white at 0.4 alpha.

**Why.** *Accessibility > Vision*: text up to 17 pt needs a contrast ratio of
at least 4.5:1. Composited over a pane at the emerald palette's own dark
(≈ `#0E1F16`, and that is the *most* favourable background it ever lands on,
since a glass pane is darker than the aurora behind it) white at 0.4 resolves
to `#6E7874` and measures **3.75:1**. This is also the tier the smallest type
in the app is written in, which is the combination the guideline is about.

**Fix.** 0.52, which measures **5.4:1** on the same background — margin left
for the lighter palettes and for a photograph behind it. Still visibly the
quiet tier: `textOnGlassDim` at 0.6 is 6.8:1 and reads as ordinary secondary
text, so there is room for a third level between that and the floor.

### 3. Two controls were invisible or wrong to a screen reader

Found by `labeledTapTargetGuideline` and `androidTapTargetGuideline`, not by
reading — which is the argument for checking them in.

**The profile photo** is the subject of that whole screen and to a reader it
was a 92-point tappable rectangle with no name. *Accessibility > Vision*:
"Describe your app's interface and content for screen readers." It now carries
a label and an activation; the `RawGestureDetector` under it no longer
publishes a second, nameless tappable node on top.

**The app title on the chats list** was announced as a control. The hidden
triple-tap behind it (Emergency Wipe) publishes a tap action, and activating it
did nothing, because one tap out of three is not the gesture. It is excluded
from semantics now. Safe to hide rather than expose properly *because the
alternative already exists*: Emergency Wipe is a labelled button on the profile
screen with the same confirmation — which is what *Accessibility > Mobility*
asks for, "core functionality accessible through more than one type of physical
interaction".

**The cover's overflow button** had no label at all. It says "Photo options"
rather than "More", because every other menu in the app is already "More" and a
reader that says the same word on six screens has told you where the button is,
not what it does.

Covered by `test/accessibility_guidelines_test.dart`.

---

## Improvements — fixed

### The nav bar now says which tab you are on

Selection was drawn three ways — the glow behind the icon, the filled icon
variant, the label going bold — and every one of them is a colour or a shape.
A screen reader saw five identical buttons. *Accessibility > Vision*: "Convey
information with more than color alone." `Semantics.selected` is the non-visual
channel for exactly this, and it announces in the platform's own phrasing and
language.

---

## Improvements — found, deliberately not changed

Each of these is a real finding. None was changed here, and the reason is the
same in every case: it is a visual decision that wants a device in front of it,
and this review was written without one.

### Fifteen call sites below the 11-point minimum

*Typography > Ensuring legibility* gives mobile a default of 17 pt and a
**minimum of 11**. Thirteen sites use 10.5 and two use 10 — message
timestamps, the nav bar's tab labels, the chat tile's mark, the diagnostics
screen. On top of that `_ClampedTextScale` allows a user override down to
**0.85**, so 10 pt is drawn at 8.5.

Two of these are defensible as they stand: the same section notes that when
people enlarge text "they don't expect the tab titles to increase in size", and
diagnostics is a developer screen. The message timestamp is the one worth
moving, and moving it changes bubble metrics — which is a golden-test
conversation, not a one-line edit.

### Two tap targets between 44 and 48

*Accessibility > Mobility* gives mobile a default control size of 44×44. Apple
asks 44; Material asks 48. Two controls sit between the two numbers: the chats
overflow button (44 wide, in a `_overflowSlot` of 44) and the search field it
collapses into (46 high).

The checked-in test therefore holds the app to Apple's 44 and not Material's
48, and says so. This interface contains no Material control anywhere — no
AppBar, no FAB — and its geometry is drawn to 44 throughout; 48 would be a
different design, not a bug fix. On Android those two are inside a
recommendation, not outside a requirement.

### Increase Contrast is not read

Now that the baseline meets 4.5:1 this is an improvement rather than a
requirement — the guidance asks for a higher-contrast scheme *if the app does
not provide the minimum by default*. `MediaQuery.highContrast` would map
cleanly onto `ThemeController._apply`, which already rewrites every ink and
border alpha in one place: a boost pass would be a handful of numbers, not a
refactor.

### No scroll edge effect

The 2025 Liquid Glass language calls for background content to be blurred and
reduced in opacity **at the scroll edges**, so the functional layer stays
legible over whatever scrolls under it. The app has the layer separation right
already (see below) but nothing at the edge: content passes under the header
capsule and the composer at full contrast.

Not attempted here for the reason this tree gives everywhere: a `ShaderMask`
across a scrolling list is a full-screen save layer per frame, on a GPU budget
that is already the measured constraint. The cheap version — an opaque gradient
veil in `AppColors.paneBase`, one quad, no layer — is worth a build and a look,
and it is a look, not an argument.

### Semantics coverage stops at six screens

The guideline test pumps the six screens that build under a bare
`ProviderScope`. The chat screen, the map and the channel screens need heavier
harnesses and are not yet audited. They are also where the densest controls
are, so that is where the next findings will be.

### Haptics are used, but not systematically

*Feedback*: "When you provide feedback using color, text, sound, and haptics,
people can receive it whether they silence their device, look away from the
screen, or use accessibility features." Nine files call `HapticFeedback`;
several equally significant actions elsewhere are silent. This is a pass over
the action inventory, not a code change.

---

## What the design already does well

Worth recording, because a review that only lists faults misrepresents the
thing it is reviewing.

- **Scalable text is honoured, and bounded.** `_ClampedTextScale` clamps to
  0.85–1.3 rather than ignoring the setting, with the reasoning written down:
  the app is built from fixed-height capsules, and honouring most of an
  accessibility request beats honouring none of it. The alternative most apps
  reach for — `TextScaler.noScaling` — is the failure this avoided.
- **The layer separation matches Liquid Glass exactly**, and predates it.
  There is no AppBar: the header capsule, the pinned island and the composer
  float over a conversation that runs edge to edge behind them. That *is* the
  functional-layer-over-content-layer model, arrived at independently.
- **Colour is a system, not a palette.** `AppColors.glassBase` is white pulled
  toward the palette's tint, so a rose theme is a rose *interface* rather than
  a grey one wearing pink buttons — and `paneBase` got the same treatment for
  the dark end. Author tints turn hue while holding saturation and lightness,
  so six people are six colours of one weight.
- **One colour means one thing.** The search highlight is amber precisely
  because it is the one hue nothing else uses, and it is deliberately *not*
  themed — *Color > Best practices*: "Avoid using the same color to mean
  different things."
- **Motion already parks itself.** `UiActivity` is one process-wide idle signal
  rather than a timer per widget, and decorative animation subscribes to it.
  The Reduce Motion work above landed on top of an architecture that was
  already shaped for it.
- **Type is three families with a stated job each**, and the monospace weight
  is pinned to the bundled asset for a reason that is written down — a
  fingerprint on an offline-first app must not fall through to a font download.

---

## Platform notes

**Both.** Everything above is framework-agnostic; all of it lands in shared
Dart.

**Android.** The only place the two platforms disagree in this review is the
tap-target number (48 vs 44), covered above. `MediaQuery.disableAnimations` is
driven by *Remove animations* in developer/accessibility settings, so the
Reduce Motion work is testable there without an iPhone.

**iOS.** Reduce Motion is the switch in Settings → Accessibility → Motion.
Worth checking the aurora specifically: it is the one surface where "holds
still" and "disappeared" could be confused, and it should read as a still
photograph, not as a missing background.
