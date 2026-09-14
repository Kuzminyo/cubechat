import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/platform_info.dart';

/// What this phone allows an incoming call to open, when the app is not on
/// screen.
///
/// Android only. Over a locked screen the call opens full screen on its own; on
/// a phone that is unlocked and in use, Android makes it a heads-up unless the
/// user has let the app "appear on top" — and "a notification with Answer and
/// Decline is not convenient, it has to be a real screen" was the report. So
/// the missing permission is shown where calls are configured and on the call
/// screen, with the button that opens the right settings page.
@immutable
class CallScreenAccess {
  const CallScreenAccess({
    required this.overlay,
    required this.fullScreenIntent,
    required this.xiaomi,
  });

  /// Nothing to ask for: not Android, or everything already granted.
  static const granted = CallScreenAccess(
    overlay: true,
    fullScreenIntent: true,
    xiaomi: false,
  );

  /// "Appear on top": the screen opens on an unlocked phone too.
  final bool overlay;

  /// Android 14 can take full-screen intents away; without them not even the
  /// lock screen gets the call screen.
  final bool fullScreenIntent;

  /// Xiaomi, Redmi or Poco, which gate both behind two permissions of their own
  /// that no app can read — only point at.
  final bool xiaomi;

  bool get complete => overlay && fullScreenIntent;
}

class CallScreenAccessController extends Notifier<CallScreenAccess> {
  static const _channel = MethodChannel('cubechat/incoming_call');

  @override
  CallScreenAccess build() {
    unawaited(refresh());
    return CallScreenAccess.granted;
  }

  /// Asked again whenever the app comes back to the front, because the only
  /// way to change the answer is to leave for the system settings.
  Future<void> refresh() async {
    if (!PlatformInfo.isAndroid) return;
    try {
      final map = await _channel.invokeMapMethod<String, bool>('access');
      if (map == null) return;
      state = CallScreenAccess(
        overlay: map['overlay'] ?? true,
        fullScreenIntent: map['fullScreenIntent'] ?? true,
        xiaomi: map['xiaomi'] ?? false,
      );
    } catch (_) {
      // No plugin on this engine: a test, or a build without one.
    }
  }

  /// Opens whichever settings page grants the next missing piece: the
  /// full-screen permission first, since without it even the lock screen gets
  /// a banner, then "appear on top". On Xiaomi, their own page as well.
  Future<void> openSettings() async {
    try {
      if (!state.fullScreenIntent &&
          await _channel.invokeMethod<bool>('openFullScreenSettings') == true) {
        return;
      }
      if (!state.overlay) {
        await _channel.invokeMethod<bool>('openOverlaySettings');
        return;
      }
      if (state.xiaomi) await _channel.invokeMethod<bool>('openVendorSettings');
    } catch (_) {}
  }

  /// MIUI's permission page for the app.
  Future<void> openVendorSettings() async {
    try {
      await _channel.invokeMethod<bool>('openVendorSettings');
    } catch (_) {}
  }
}

final callScreenAccessProvider =
    NotifierProvider<CallScreenAccessController, CallScreenAccess>(
  CallScreenAccessController.new,
);

/// "Not now" on the call screen, for the rest of this run of the app. Not
/// saved: a permission that would make calls work is worth asking about again
/// tomorrow, just not on every call today.
final callScreenAccessDismissedProvider = StateProvider<bool>((_) => false);
