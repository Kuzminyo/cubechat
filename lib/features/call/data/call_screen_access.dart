import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/util/app_build.dart';
import '../../../core/util/platform_info.dart';

/// What this phone allows an incoming call to show over the lock screen.
///
/// Android only. A phone in use gets the heads-up in the shade and needs
/// nothing for it. The lock screen gets the call screen by itself on most
/// phones; two things can take that away, and they are the whole list:
/// Android 14's full-screen switch, and on Xiaomi, Redmi and Poco their own
/// "show on lock screen", which no app can turn on for itself.
///
/// It used to be four. "Appear on top" and MIUI's "pop-up windows in the
/// background" were only for opening the screen on an unlocked phone, which
/// is gone - "permissions should just be there, not something to go and
/// switch on" was the report, and the honest answer is to stop needing them.
@immutable
class CallScreenAccess {
  const CallScreenAccess({
    required this.fullScreenIntent,
    required this.xiaomi,
    this.xiaomiLockScreen = true,
    this.worthAsking = false,
  });

  /// Nothing to ask for: not Android, or everything already granted.
  static const granted = CallScreenAccess(
    fullScreenIntent: true,
    xiaomi: false,
  );

  /// Android 14 can take full-screen intents away; without them not even the
  /// lock screen gets the call screen.
  final bool fullScreenIntent;

  /// Xiaomi, Redmi or Poco, which gate the lock screen behind a permission of
  /// their own that no app can grant - only point at.
  final bool xiaomi;

  /// MIUI's "show on lock screen". Read from MIUI's own app-op; true when this
  /// is not MIUI or it could not be read.
  final bool xiaomiLockScreen;

  bool get vendorComplete => xiaomiLockScreen;

  bool get complete => fullScreenIntent && vendorComplete;

  /// Off, and worth one question: an update took it away, or nobody has been
  /// asked about it yet.
  ///
  /// Reported as "the switch resets after every update", on every phone, and
  /// off in the system settings too — so it is not this app forgetting
  /// anything. Android re-decides the full-screen permission when an APK is
  /// installed over itself from outside Google Play, and MIUI does the same
  /// with its lock-screen one; no app can grant either back to itself. What an
  /// app can do is notice, the first time it runs after the update, and take
  /// the person straight to the switch.
  final bool worthAsking;
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
      final fresh = CallScreenAccess(
        fullScreenIntent: map['fullScreenIntent'] ?? true,
        xiaomi: map['xiaomi'] ?? false,
        xiaomiLockScreen: map['xiaomiLockScreen'] ?? true,
      );
      state = CallScreenAccess(
        fullScreenIntent: fresh.fullScreenIntent,
        xiaomi: fresh.xiaomi,
        xiaomiLockScreen: fresh.xiaomiLockScreen,
        worthAsking: await _worthAsking(fresh.complete),
      );
    } catch (_) {
      // No plugin on this engine: a test, or a build without one.
    }
  }

  /// The build this phone last had the lock-screen call switch on in.
  static const grantedInBuildKey = 'callScreen.grantedInBuild';

  /// Whether the question has been put at least once on this install.
  static const askedKey = 'callScreen.asked';

  /// Remember the build whenever it is on. When it is off, ask if it was on in
  /// a *different* build — an update took it — or if nobody has ever asked.
  /// Off in the same build it was on in means the person turned it off, and
  /// that is theirs to decide.
  ///
  /// The second half is what makes the first update onto this code work: the
  /// build was never recorded before it, so without it the very reset that was
  /// reported would pass without a word.
  Future<bool> _worthAsking(bool complete) async {
    final prefs = await SharedPreferences.getInstance();
    if (complete) {
      await prefs.setString(grantedInBuildKey, appBuildStamp);
      return false;
    }
    final grantedIn = prefs.getString(grantedInBuildKey);
    if (grantedIn != null) return grantedIn != appBuildStamp;
    return !(prefs.getBool(askedKey) ?? false);
  }

  /// Asked: whether they went to the switch or not, this has been told about.
  /// The next time it is on it is remembered afresh, and the next update that
  /// takes it away asks again.
  Future<void> acknowledgeAsked() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(grantedInBuildKey);
    await prefs.setBool(askedKey, true);
    state = CallScreenAccess(
      fullScreenIntent: state.fullScreenIntent,
      xiaomi: state.xiaomi,
      xiaomiLockScreen: state.xiaomiLockScreen,
    );
  }

  /// Opens whichever settings page grants the missing piece: Android's
  /// full-screen permission first, then MIUI's own page.
  Future<void> openSettings() async {
    try {
      if (!state.fullScreenIntent &&
          await _channel.invokeMethod<bool>('openFullScreenSettings') == true) {
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
