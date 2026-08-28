import 'package:flutter/widgets.dart';

/// Reduce Motion, in one place.
///
/// The phone has a switch for this — "Reduce Motion" on iOS, "Remove
/// animations" on Android — and Flutter hands it over as
/// `MediaQuery.disableAnimations`. Nothing in this app read it, so a user who
/// had turned it on still got the aurora drifting behind every screen, a dot
/// breathing on every avatar, and each list sliding up into place.
///
/// That setting is not a preference about taste. It is turned on by people who
/// get motion sickness or vertigo from movement they did not ask for, and the
/// two things this app moves the most — a full-screen gradient that never stops
/// and a pulse repeated once per visible row — are exactly the pattern the
/// guidance names: automatic, repetitive, peripheral.
///
/// > **Design guideline — Accessibility > Cognitive**: "When this setting is
/// > active, ensure your app or game responds by reducing automatic and
/// > repetitive animations, including zooming, scaling, and peripheral motion."
///
/// What "reduced" means here, following the same guidance:
///
///  * **Repetitive decoration stops.** The aurora holds a still frame; the
///    online dot holds a lit one. Neither disappears — the interface looks the
///    same, it just stops moving on its own.
///  * **Transitions become fades.** The guidance asks for x/y/z motion to be
///    replaced by a fade rather than removed, because something has to say a
///    screen changed. So a push cross-fades instead of sliding.
///  * **Entrances collapse.** A list that staggers itself into view is a
///    flourish; with Reduce Motion on, the rows are simply there.
///
/// It costs nothing when the setting is off, and when it is on it also happens
/// to remove every scheduled frame the app draws while nobody is touching it —
/// which is the same win [UiActivity] chases, granted here for free.
abstract final class AppMotion {
  /// True when this device asked for less movement.
  ///
  /// `maybe`, because a widget test pumps a bare `MediaQuery`-less tree often
  /// enough that throwing there would be the only thing this ever did.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// [full], or nothing at all when motion is reduced.
  ///
  /// Zero rather than "short": a 60 ms slide is still a slide, and the point is
  /// that the thing does not travel. Where a fade is the right answer instead,
  /// ask for [reduced] and pick the fade — a duration cannot make that choice.
  static Duration duration(BuildContext context, Duration full) =>
      reduced(context) ? Duration.zero : full;
}
