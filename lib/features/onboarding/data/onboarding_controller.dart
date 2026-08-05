import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// Whether the intro screens have been seen.
///
/// One flag in the settings box rather than its own store — it is a
/// preference, and the same shape as the privacy toggles that live there.
class OnboardingController extends Notifier<bool> {
  static const _key = 'onboarding.seen';

  Box<dynamic>? _box;
  Future<void>? _loading;

  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  bool build() {
    unawaited(_loading = _load());
    // Assume seen until the box says otherwise. The router decides where to
    // start from [readSeenFlag] at boot, not from here, so a false default
    // would only risk flashing the intro at somebody who has already read it.
    return true;
  }

  Future<void> markSeen() async {
    state = true;
    await loaded;
    try {
      await _box?.put(_key, true);
    } catch (e) {
      debugPrint('Onboarding persist failed: $e');
    }
  }

  /// Emergency Wipe: a fresh install is indistinguishable from a wiped one,
  /// intro included.
  Future<void> reset() async {
    state = false;
    await loaded;
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('Onboarding reset failed: $e');
    }
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      state = box.get(_key) == true;
    } catch (e) {
      debugPrint('Onboarding load failed: $e');
    }
  }
}

final onboardingControllerProvider =
    NotifierProvider<OnboardingController, bool>(OnboardingController.new);

/// Read the flag before the first frame, so the router can open straight onto
/// the right screen.
///
/// Deciding this after `runApp` would mean rendering the chats list and then
/// redirecting away from it — a visible flash of somebody else's app on the
/// one launch where the user has never seen it before.
Future<bool> readSeenOnboardingFlag() async {
  try {
    final box =
        await hiveCipherProvider.openEncryptedBox<dynamic>(HiveBoxes.settings);
    return box.get(OnboardingController._key) == true;
  } catch (e) {
    debugPrint('Onboarding flag read failed: $e');
    // Err toward not interrupting: someone who has used the app for months
    // should never be shown the intro because a disk read hiccuped.
    return true;
  }
}
