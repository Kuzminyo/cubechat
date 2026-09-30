import 'dart:async';

import 'package:flutter/services.dart';

/// The app's four touch ticks, by what the touch means rather than by motor
/// strength, so the same kind of action feels the same everywhere.
///
/// The app had haptics in about fifteen places, each picking a strength on its
/// own, and none at all on the settings switches or the profile's section
/// rows — the controls touched most often in a settings pass. The system's own
/// "touch feedback" setting still wins: with it off, the platform plays none.
///
/// Fire-and-forget: a tick is never worth awaiting before the action it marks.
abstract final class Haptics {
  /// Picking something: a row, a tab, one choice out of several.
  static void tap() => unawaited(HapticFeedback.selectionClick());

  /// A switch flipped.
  static void toggle() => unawaited(HapticFeedback.lightImpact());

  /// Something done that matters: sent, saved, a gesture that completed.
  static void confirm() => unawaited(HapticFeedback.mediumImpact());

  /// About to do something that cannot be taken back.
  static void warn() => unawaited(HapticFeedback.heavyImpact());
}
