import 'package:flutter/services.dart';

import 'debug_log.dart';
import 'platform_info.dart';

/// Ask the OS to keep this screen out of screenshots and screen recordings.
///
/// Android honours this: `FLAG_SECURE` makes the system refuse a screenshot
/// outright and renders black to a recorder or a cast. It is set around the
/// view-once photo and cleared on the way out, rather than held for the whole
/// app — the flag also blanks the app in the recents thumbnail, and a messenger
/// showing an empty card in the task switcher all day is worse to live with
/// than the thing it would be preventing.
///
/// **iOS has no equivalent and this is a no-op there.** UIKit offers no way to
/// refuse a screenshot; the platform's position is that the person holding the
/// phone owns what is on it. What iOS does offer is
/// `userDidTakeScreenshotNotification` — after the fact — so the honest options
/// there are to tell the sender it happened or to burn the photo, not to
/// pretend the picture is protected. Nothing here claims otherwise: a caller
/// that needs to know whether the promise was actually made must check
/// [isSupported].
///
/// Worth being plain about even on Android: this stops the OS screenshot and a
/// screen recorder. It cannot stop a second phone pointed at the first one.
class SecureWindow {
  const SecureWindow._();

  static const MethodChannel _channel = MethodChannel('cubechat/secure_window');

  /// Whether the platform can actually refuse a capture.
  static bool get isSupported => PlatformInfo.isAndroid;

  static Future<void> enable() => _set(true);
  static Future<void> disable() => _set(false);

  static Future<void> _set(bool on) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<bool>('setSecure', {'on': on});
    } catch (e) {
      // Never worth failing the screen over: the photo still has to open, and
      // a build whose Activity did not register the channel would otherwise
      // make a view-once picture unopenable rather than merely unprotected.
      DebugLog.instance.log('VIEWONCE', 'secure-window $on failed: $e');
    }
  }
}
