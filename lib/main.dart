import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/notifications/ios_background_refresh.dart';
import 'core/notifications/notification_service.dart';
import 'core/storage/hive_init.dart';
import 'core/util/debug_log.dart';

/// Build-time marker bumped on every release. Surfaces in Diagnostics so we
/// can tell at a glance whether a phone is running the latest APK.
const String _buildStamp = '2026-07-27-floating-header';

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
