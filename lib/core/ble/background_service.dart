import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart side of the Android foreground-service bridge. Starting the service
/// pins the process so BLE advertising / GATT / scanning keep running while
/// the app is backgrounded — that's what lets another phone keep seeing us
/// and writing to us when cubechat isn't in the foreground.
///
/// No-ops on platforms without the native channel (iOS handles background BLE
/// differently via UIBackgroundModes; a dedicated iOS path can come later).
class BackgroundService {
  BackgroundService._();
  static final BackgroundService instance = BackgroundService._();

  static const _channel = MethodChannel('cubechat/background');

  /// Start the foreground service (shows the ongoing "Cubechat active"
  /// notification). Returns false if the platform side isn't available.
  Future<bool> start() async {
    try {
      return await _channel.invokeMethod<bool>('start') ?? false;
    } on MissingPluginException {
      return false;
    } catch (e) {
      debugPrint('BackgroundService.start failed: $e');
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // not supported — nothing to stop
    } catch (e) {
      debugPrint('BackgroundService.stop failed: $e');
    }
  }

  /// Whether the OS currently exempts us from battery optimisation. On
  /// Samsung/One UI this must be true for the service to survive the app
  /// being swiped away.
  Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      return await _channel
              .invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
          true;
    } on MissingPluginException {
      return true;
    } catch (e) {
      debugPrint('BackgroundService.isIgnoringBatteryOptimizations: $e');
      return true;
    }
  }

  /// Open the system dialog asking the user to exempt us from battery
  /// optimisation. Returns true if a dialog/settings screen was launched.
  Future<bool> requestIgnoreBatteryOptimizations() async {
    try {
      return await _channel
              .invokeMethod<bool>('requestIgnoreBatteryOptimizations') ??
          false;
    } on MissingPluginException {
      return false;
    } catch (e) {
      debugPrint('BackgroundService.requestIgnoreBatteryOptimizations: $e');
      return false;
    }
  }
}
