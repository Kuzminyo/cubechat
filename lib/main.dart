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

/// Build-time marker bumped on every release. Surfaces in Diagnostics so we
/// can tell at a glance whether a phone is running the latest APK.
const String _buildStamp = '2026-08-02-relay-intro-presence-autodelete';

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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  DebugLog.install();
  await HiveInit.ensureInitialized();
  await NotificationService.instance.init();
  DebugLog.instance.log('BOOT', 'cubechat $_buildStamp '
      'debug=$kDebugMode profile=$kProfileMode release=$kReleaseMode');
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);
  await _matchDisplayRefreshRate();
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
  final container = ProviderContainer();
  IosBackgroundRefresh.instance.install(container);
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const CubechatApp(),
    ),
  );
}
