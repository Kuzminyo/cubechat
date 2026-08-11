import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/notifications/ios_background_refresh.dart';
import 'core/notifications/notification_service.dart';
import 'core/storage/hive_init.dart';
import 'core/util/debug_log.dart';
import 'core/util/media_storage.dart';
import 'features/map/presentation/people_map_screen.dart';
import 'features/onboarding/data/onboarding_controller.dart';

/// Build-time marker bumped on every release. Surfaces in Diagnostics so we
/// can tell at a glance whether a phone is running the latest APK.
const String _buildStamp = '2026-08-11-apk-signed-under-our-own-name';

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
Future<void> _matchDisplayRefreshRate() async {
  if (kIsWeb || !Platform.isAndroid) return;
  try {
    await FlutterDisplayMode.setHighRefreshRate();
    final active = await FlutterDisplayMode.active;
    DebugLog.instance.log('DISPLAY', 'mode ${active.width}x${active.height} '
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
    // Only worth a line when it was slow enough to be felt; a healthy boot
    // should not have to push the interesting entries out of the buffer.
    if (watch.elapsedMilliseconds >= 250) {
      DebugLog.instance.log('BOOT', '$what took ${watch.elapsedMilliseconds}ms');
    }
  } on TimeoutException {
    DebugLog.instance.log(
      'BOOT',
      '$what still going after ${limit.inSeconds}s — starting without it',
    );
  } catch (e) {
    DebugLog.instance.log('BOOT', '$what failed after '
        '${watch.elapsedMilliseconds}ms: $e');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  DebugLog.install();
  // First, so that a stall in any step below still leaves a log that says which
  // build was trying to start. This used to sit after Hive and notifications,
  // where a hang meant no boot line at all.
  DebugLog.instance.log('BOOT', 'cubechat $_buildStamp '
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
  await _bootStep(
    'orientation',
    () => SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]),
    limit: const Duration(seconds: 2),
  );
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
  // One more read before the first frame, and a cheap one — the box is
  // already open by now. It decides which screen the router opens on, which
  // cannot be decided after the fact without showing the wrong one first.
  var seenOnboarding = true;
  await _bootStep(
    'onboarding-flag',
    () async => seenOnboarding = await readSeenOnboardingFlag(),
    limit: const Duration(seconds: 2),
  );

  final container = ProviderContainer();
  IosBackgroundRefresh.instance.install(container);
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
  unawaited(_bootStep('display-mode', _matchDisplayRefreshRate));

  // Also after runApp, and also unawaited: the map is four tabs away, so
  // opening its tile cache has no business delaying the first frame. By the
  // time anyone reaches the Map tab this is long done, and if it never
  // finishes the map simply fetches every tile as it did before.
  unawaited(_bootStep('map-tile-cache', initMapTileCache));
}
