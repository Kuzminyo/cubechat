import 'dart:async';

import 'package:cubechat/core/util/ui_activity.dart';

/// Suite-wide test setup. Flutter picks this file up automatically and runs
/// every test in the directory through it.
///
/// [UiActivity] is a process-wide singleton that arms a four-second countdown
/// whenever the interface is touched, so decorative animations can park
/// themselves when nothing is happening. In a widget test that countdown is
/// pure liability: the root pointer listener arms it on any tap or drag, and
/// `testWidgets` fails a test that finishes with a timer still pending. Every
/// test that so much as taps a button would have to know about it.
///
/// Disabling the countdown leaves the signal permanently "in use", which is
/// how the app behaved before the idle work landed — animations keep running,
/// and no test has to care. `ui_activity_test.dart` turns it back on for
/// itself, since the countdown is the thing it is testing.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  UiActivity.debugDisableQuietTimer = true;
  await testMain();
}
