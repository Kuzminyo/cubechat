import 'package:flutter/widgets.dart';

/// Hands back what a tab built last while its branch is offstage, instead of
/// building again.
///
/// The tab shell keeps every branch mounted, and it says which one is on screen
/// through [TickerMode] — off for the branches it has taken offstage. A hidden
/// tab still rebuilds on every change to what it watches, and a tab that
/// watches the messages rebuilds whenever the one in front of it touches them.
/// A Galaxy S24+ log (2026-10-15): every chat open and close carried a full
/// rebuild of the hidden Contacts tab — `contacts`, ten call rows, nine contact
/// rows, twenty-two glass panes — in frames of 17-39 ms of build against a
/// 120 Hz budget of 8.3. On the slow phones the same frame is several times
/// longer, which is what a chat that opens with a lurch is.
///
/// Skipping the build also drops the subscriptions: a Riverpod consumer stops
/// watching whatever its last build did not watch. So a hidden tab costs
/// nothing at all until it is shown, and showing it flips [TickerMode], which
/// rebuilds it once against fresh data.
///
/// Use it from a [State] whose build is the whole tab:
///
/// ```dart
/// Widget build(BuildContext context) => buildUnlessOffstage(() { ... });
/// ```
mixin FreezeWhenOffstage<T extends StatefulWidget> on State<T> {
  Widget? _frozen;

  Widget buildUnlessOffstage(Widget Function() build) {
    // Read every time: it is what makes a change of tab rebuild this at all.
    final visible = TickerMode.valuesOf(context).enabled;
    final frozen = _frozen;
    if (!visible && frozen != null) return frozen;
    return _frozen = build();
  }
}
