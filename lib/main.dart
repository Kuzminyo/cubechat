import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/notifications/ios_background_refresh.dart';
import 'core/notifications/notification_service.dart';
import 'core/storage/hive_init.dart';
import 'core/util/app_build.dart';
import 'core/util/build_probe.dart';
import 'core/util/debug_log.dart';
import 'core/util/platform_info.dart';
import 'core/util/ui_stall_watch.dart';
import 'core/util/media_storage.dart';
import 'features/chats/data/chat_list_warmup.dart';
import 'features/map/presentation/people_map_screen.dart';
import 'features/onboarding/data/onboarding_controller.dart';

// The build stamp used to live here as a private constant, which meant the
// boot log was the only thing that could see it. It is in
// `core/util/app_build.dart` now, next to the version, so the profile screen
// can show both — see [appBuildStamp].

/// Ask Android for the panel's real refresh rate.
///
/// On a 90/120 Hz Xiaomi the app looked *worse* than on a 60 Hz phone: MIUI
/// leaves an app that never states a preference on the 60 Hz mode while the
/// system UI around it runs at 90, so every scroll is a 60 Hz animation on a
/// 90 Hz panel — uneven frame pacing, which reads as stutter even though no
/// frame is being missed. Stating the preference is what fixes it; it isn't a
/// request to draw *more*, and the idle cost is unchanged because the aurora
/// and the dots park when nothing is moving either way.
///
/// Android only — deliberately. iOS caps at 60 Hz through
/// `CADisableMinimumFrameDurationOnPhone` in Info.plist, which was set to hold
/// ProMotion iPhones down for heat; this must not quietly undo that.
/// Ask Android for the panel's real refresh rate.
///
/// On a 90/120 Hz Xiaomi the app looked *worse* than on a 60 Hz phone: MIUI
/// leaves an app that never states a preference on the 60 Hz mode while the
/// system UI around it runs at 90, so every scroll is a 60 Hz animation on a
/// 90 Hz panel — uneven frame pacing, which reads as stutter even though no
/// frame is being missed. Stating the preference is what fixes it; it isn't a
/// request to draw *more*, and the idle cost is unchanged because the aurora
/// and the dots park when nothing is moving either way.
///
/// **Do not "save heat" by asking for the low mode instead.** Tried on
/// 2026-08-17 and reverted within the hour. The arithmetic looked sound —
/// raster p90 was 9.6 ms, comfortably inside a 60 Hz budget and past a 120 Hz
/// one, so half the frames should have been half the work for no visible
/// difference. On the phone it was the opposite: build p90 went 4.7 → 7.8 and
/// raster 9.6 → 14.8, and the app was reported as barely usable. Whatever
/// `setLowRefreshRate` does on that device — a mode with a different
/// resolution, a panel that keeps switching, a compositor scaling the surface —
/// it is not "the same frames, fewer of them". The paragraph above was already
/// the warning, and it was read as being about something else.
///
/// Android only — deliberately. iOS caps at 60 Hz through
/// `CADisableMinimumFrameDurationOnPhone` in Info.plist, which was set to hold
/// ProMotion iPhones down for heat; this must not quietly undo that.
Future<void> _matchDisplayRefreshRate() async {
  if (kIsWeb || !Platform.isAndroid) return;
  try {
    await FlutterDisplayMode.setHighRefreshRate();
    final active = await FlutterDisplayMode.active;
    DebugLog.instance.log(
        'DISPLAY',
        'mode ${active.width}x${active.height} '
            '@${active.refreshRate.toStringAsFixed(1)}Hz');
  } catch (e) {
    // Plenty of devices expose no mode list at all; the platform default is a
    // perfectly good answer and is not worth failing a launch over.
    DebugLog.instance.log('DISPLAY', 'refresh-rate request failed: $e');
  }
}

/// Run one startup step under a time limit, and say how it went.
///
/// Everything awaited before [runApp] postpones the first frame, and on Android
/// the launch theme — the logo — stays on screen for exactly that long. So a
/// platform channel that stalls does not look like a slow feature; it looks
/// like an app that will not open, which is what a tester saw when it took four
/// attempts to get in. None of these steps is worth that: a bound turns "never
/// starts" into "starts without that one thing", which is always the better
/// failure.
///
/// The line it logs is also the diagnosis. Without it a hang here leaves no
/// trace at all — the log is in memory and the app never got far enough to show
/// it — so the next report can name the step instead of the symptom.
Future<void> _bootStep(
  String what,
  Future<void> Function() step, {
  Duration limit = const Duration(seconds: 5),
}) async {
  final watch = Stopwatch()..start();
  try {
    await step().timeout(limit);
    // Sixty rather than two hundred and fifty.
    //
    // At the old bar a healthy boot printed nothing, which was the intent —
    // and it also meant that "the icon sits there too long" had no evidence
    // behind it at all. The steps here now add up to under two hundred
    // milliseconds together, so every one of them is invisible, and the next
    // thing to cut cannot be chosen without knowing which one it is.
    //
    // Six lines at worst, on one launch, in a two-hundred-line buffer. The
    // rest of the boot is the engine starting and the system's own launch
    // screen, neither of which this can see.
    if (watch.elapsedMilliseconds >= 60) {
      DebugLog.instance
          .log('BOOT', '$what took ${watch.elapsedMilliseconds}ms');
    }
  } on TimeoutException {
    DebugLog.instance.log(
      'BOOT',
      '$what still going after ${limit.inSeconds}s — starting without it',
    );
  } catch (e) {
    DebugLog.instance.log(
        'BOOT',
        '$what failed after '
            '${watch.elapsedMilliseconds}ms: $e');
  }
}

/// Put every uncaught error into the log the user can actually send.
///
/// Until now nothing did. A crash — "it closes when I come back from a chat" —
/// left the in-app log with the last ordinary line before it and nothing else,
/// so the one report that matters most was the one report with no evidence in
/// it. `debugPrint` goes to a console nobody has on a phone.
///
/// Both hooks, because they catch different things: [FlutterError.onError] is
/// the framework's own errors (a build that throws, a failed layout, a disposed
/// object used again), and `PlatformDispatcher.onError` is everything else that
/// escapes an async gap. Neither is *handled* here — the framework's own
/// behaviour is kept, so a debug build still shows the red screen and a release
/// build still terminates if that is what it was going to do. This only makes
/// sure the reason is written down first.
///
/// One line, not a full stack: [DebugLog] holds 200 lines and a stack trace is
/// twenty of them, which would evict the context that says what the user was
/// doing. The first frame naming this app's own code is the one that matters,
/// and it is picked out below.
void _logUncaughtErrors() {
  final chained = FlutterError.onError;
  FlutterError.onError = (details) {
    DebugLog.instance.log(
      'CRASH',
      '${details.exception} — ${_originOf(details.stack)}',
    );
    chained?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    DebugLog.instance.log('CRASH', '$error — ${_originOf(stack)}');
    // False: not handled. Anything that reaches here was going to end the
    // isolate, and pretending otherwise would hide a real fault behind a log
    // line — which is the opposite of the point.
    return false;
  };
}

/// The first frame that belongs to this app rather than to the framework.
///
/// A stack from a widget error is forty frames of `package:flutter` above the
/// line that actually broke. This walks down to the first `package:cubechat`
/// frame, which is the one worth a place in a 200-line buffer.
String _originOf(StackTrace? stack) {
  if (stack == null) return 'no stack';
  for (final line in stack.toString().split('\n')) {
    if (line.contains('package:cubechat/')) return line.trim();
  }
  final first = stack.toString().split('\n').first.trim();
  return first.isEmpty ? 'no stack' : first;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  DebugLog.install();
  _logUncaughtErrors();
  // Before anything slow, so the boot steps below are themselves watched.
  UiStallWatch.instance.install();
  // First line of the app that touches storage, and that is the point.
  //
  // It reads one boolean out of the settings box, but it is the first thing to
  // ask for the cipher — and the cipher is a round trip to the platform
  // keystore, which is the single slowest step of a cold start. Kicking it off
  // here means every other step below runs inside it rather than after it.
  //
  // Measured on a real phone at build 975: 281 ms from the boot line to the
  // first route, of which this was 208 and everything else fitted inside it.
  // That is the floor for an app whose storage is encrypted; the only way past
  // it is not encrypting, which is not on the table. See the await below.
  var seenOnboarding = true;
  final onboardingRead = readSeenOnboardingFlag();
  // First, so that a stall in any step below still leaves a log that says which
  // build was trying to start. This used to sit after Hive and notifications,
  // where a hang meant no boot line at all.
  DebugLog.instance.log(
      'BOOT',
      'cubechat $appVersion $appBuildStamp '
          'debug=$kDebugMode profile=$kProfileMode release=$kReleaseMode');

  // Storage genuinely gates the first frame — the tree reads it immediately —
  // so it gets the longest leash. It also goes through the platform keystore,
  // which is the slowest thing here on a cold Android start.
  // Ahead of Hive, because the message decoder repairs media paths as it reads
  // and needs to know where the app lives before the first row is decoded.
  await _bootStep('media-paths', MediaPaths.init,
      limit: const Duration(seconds: 3));
  await _bootStep('hive', HiveInit.ensureInitialized,
      limit: const Duration(seconds: 10));
  // Kept ahead of runApp for iOS, where this call is what raises the very first
  // permission prompt; bounded because on Android it is a plugin channel like
  // any other.
  await _bootStep('notifications', NotificationService.instance.init);
  // Before anything touches Bluetooth, which is the plugin's own condition:
  // the option is only read when CoreBluetooth's central manager is created,
  // and the first BLE call of the process is what creates it.
  //
  // What it buys is the iOS half of staying reachable. With a restore
  // identifier, a peer connecting to us is a launch event — the system brings
  // a terminated cubechat back into the background to handle it — and without
  // one the session simply dies with the process and the message waits for the
  // user. The peripheral side does the same thing natively; see
  // CubechatBlePeripheralPlugin.
  if (PlatformInfo.isIOS) {
    await _bootStep(
      'ble-restore-state',
      // showPowerAlert stays off deliberately. It defaults to *on* in the
      // plugin's Dart signature but is never applied unless this method is
      // called, so leaving it at the default here would quietly introduce a
      // system "turn Bluetooth on?" popup that the app has never shown.
      () =>
          FlutterBluePlus.setOptions(showPowerAlert: false, restoreState: true),
      limit: const Duration(seconds: 2),
    );
  }
  // Not awaited, and not a boot step.
  //
  // A field log has `orientation still going after 2s — starting without it`:
  // two whole seconds of a launch spent inside a platform call that locks the
  // screen the way it is already being held. Nothing downstream reads the
  // result, and a lock that lands a frame or two into the first screen is not
  // something anybody can see — the phone is portrait when the app opens
  // because the person is holding it that way.
  //
  // The two-second cap was the right instinct applied to the wrong half: the
  // question is not "how long may this take" but "why is the launch waiting
  // for it at all".
  unawaited(SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]));
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  // The container is built here rather than by a ProviderScope widget so the
  // iOS background-refresh channel can reach the *same* providers the UI uses.
  // When iOS launches us straight into the background for a BGAppRefreshTask,
  // no frame is rendered and the widget tree may never build — a handler
  // registered from inside the tree would simply never exist.
  // Awaited here, started long before. It decides which screen the router
  // opens on, which cannot be decided after the fact without showing the wrong
  // one first — so the *answer* has to be in hand before the first frame, and
  // that is not the same as the *work* being done here.
  //
  // Measured at 265 ms on a real phone, sequentially after the boxes it does
  // not depend on. Kicked off at the top of `main` it overlaps them and costs
  // whatever is left when they finish, which on that phone was nothing.
  await _bootStep(
    'onboarding-flag',
    () async => seenOnboarding = await onboardingRead,
    limit: const Duration(seconds: 2),
  );

  final container = ProviderContainer();
  IosBackgroundRefresh.instance.install(container);

  // The one thing above that is allowed to hold the first frame for a screen's
  // worth of content rather than for a decision.
  //
  // Everything else here is bounded because a stall would look like an app
  // that will not open. This is bounded for the same reason and admitted for a
  // different one: without it the first frame is a chat list with no chats in
  // it, which renders the "no chats yet" empty state on a phone full of
  // conversations, and the rows then replace it without an entrance because
  // [AppearOnce] has already switched the animation off. A wrong screen
  // followed by a cut is worse than a launch icon held for the length of a
  // disk read. See [warmChatList].
  //
  // A second is the whole budget. Past that the old behaviour is better than a
  // logo that will not go away, and the log line says which it was.
  await _bootStep(
    'chat-list',
    () => warmChatList(container),
    limit: const Duration(seconds: 1),
  );

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: CubechatApp(seenOnboarding: seenOnboarding),
    ),
  );

  // Deliberately after runApp, and deliberately not awaited.
  //
  // This is an Android-only platform call that was sitting in the critical
  // path, which is the shape of the bug it is being moved out of: the logo
  // hanging, on Android only. Nothing it does decides what the first frame
  // contains — the panel switching mode a few frames later is invisible — so it
  // has no business delaying one.
  // After the first frame, not merely after `runApp`.
  //
  // It was already unawaited — it decides nothing about what the first frame
  // contains — and it still took 751 ms on a real phone, all of it on the
  // platform thread, which is the same thread the engine is finishing its own
  // start-up on and every plugin channel answers from. Unawaited work is not
  // free work; it is work nobody is waiting for, on a thread several things
  // are.
  //
  // Reported as: the icon, a pause, and only then the app. Handing it the
  // frame *after* the first one costs nothing visible — a panel changing
  // refresh mode a few frames in is invisible — and takes it out of the
  // window where it can contend.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_bootStep('display-mode', _matchDisplayRefreshRate));
  });

  // After runApp for the same reason: a question, not a step. The answer lands
  // in the log a few frames in, which is where anybody reading it is looking.
  unawaited(_bootStep('build-facts', BuildProbe.logBuildFacts,
      limit: const Duration(seconds: 3)));

  // Also after runApp, and also unawaited: the map is four tabs away, so
  // opening its tile cache has no business delaying the first frame. By the
  // time anyone reaches the Map tab this is long done, and if it never
  // finishes the map simply fetches every tile as it did before.
  unawaited(_bootStep('map-tile-cache', initMapTileCache));
}
