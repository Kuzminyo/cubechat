import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/storage/hive_init.dart';
import 'core/util/debug_log.dart';

/// Build-time marker bumped on every release. Surfaces in Diagnostics so we
/// can tell at a glance whether a phone is running the latest APK.
const String _buildStamp = '2026-05-19-no-circles';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  DebugLog.install();
  await HiveInit.ensureInitialized();
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
  runApp(const ProviderScope(child: CubechatApp()));
}
