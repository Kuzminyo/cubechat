import 'package:flutter/services.dart';

import '../util/platform_info.dart';

/// Lets go of the background time iOS was asked for so the app could say
/// goodbye. See `holdForGoodbye` in `AppDelegate.swift`: the task is taken
/// natively the moment the app goes to the background, and this ends it once
/// the "not in the app" beacon has gone out, rather than holding the phone
/// awake for the full allowance.
abstract final class IosGoodbyeHold {
  static const _channel = MethodChannel('cubechat/goodbye');

  static Future<void> said() async {
    if (!PlatformInfo.isIOS) return;
    try {
      await _channel.invokeMethod<void>('said');
    } catch (_) {
      // An older native half, or a test — the hold ends on its own timer.
    }
  }
}
