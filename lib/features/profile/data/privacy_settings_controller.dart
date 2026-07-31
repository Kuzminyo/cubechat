import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// What this device tells other people about *when* it was here and *when* it
/// read them.
///
/// Both signals are optional in the protocol — a presence beacon is a frame we
/// choose to publish, a read receipt is a frame we choose to answer with — so
/// switching them off costs nothing but the signal itself. Messages, delivery
/// and everything else are untouched.
///
/// **Both are symmetric, deliberately.** Turning off "last seen" also stops us
/// *reading* other people's, and the same for read receipts. Anything else
/// would be a one-way mirror: you would keep watching people who can no longer
/// watch you, and a privacy switch that quietly buys you an advantage over the
/// person on the other end is not a privacy switch. It is also the behaviour
/// every mainstream messenger has settled on, so it will not surprise anyone.
///
/// **On by default.** Seeing that someone is around, and that they read you, is
/// most of what makes a conversation feel alive; a messenger that hides it
/// unasked feels broken rather than private.
@immutable
class PrivacySettings {
  const PrivacySettings({
    required this.shareLastSeen,
    required this.shareReadReceipts,
  });

  /// True: publish the presence beacon, and show peers' online state.
  /// False: publish nothing, and treat every peer's presence as unknown.
  final bool shareLastSeen;

  /// True: answer with read receipts, and show the read tick on our own
  /// messages. False: never answer, and never show the tick.
  final bool shareReadReceipts;

  static const initial =
      PrivacySettings(shareLastSeen: true, shareReadReceipts: true);

  PrivacySettings copyWith({bool? shareLastSeen, bool? shareReadReceipts}) =>
      PrivacySettings(
        shareLastSeen: shareLastSeen ?? this.shareLastSeen,
        shareReadReceipts: shareReadReceipts ?? this.shareReadReceipts,
      );

  @override
  bool operator ==(Object other) =>
      other is PrivacySettings &&
      other.shareLastSeen == shareLastSeen &&
      other.shareReadReceipts == shareReadReceipts;

  @override
  int get hashCode => Object.hash(shareLastSeen, shareReadReceipts);
}

class PrivacySettingsController extends Notifier<PrivacySettings> {
  static const _keyLastSeen = 'privacy.shareLastSeen';
  static const _keyReceipts = 'privacy.shareReadReceipts';

  Box<dynamic>? _box;

  @override
  PrivacySettings build() {
    unawaited(_load());
    return PrivacySettings.initial;
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      state = PrivacySettings(
        shareLastSeen: box.get(_keyLastSeen) as bool? ?? true,
        shareReadReceipts: box.get(_keyReceipts) as bool? ?? true,
      );
    } catch (e) {
      debugPrint('PrivacySettings load failed: $e');
    }
  }

  Future<void> setShareLastSeen(bool value) async {
    state = state.copyWith(shareLastSeen: value);
    await _put(_keyLastSeen, value);
  }

  Future<void> setShareReadReceipts(bool value) async {
    state = state.copyWith(shareReadReceipts: value);
    await _put(_keyReceipts, value);
  }

  Future<void> _put(String key, bool value) async {
    try {
      await _box?.put(key, value);
    } catch (e) {
      debugPrint('PrivacySettings persist failed: $e');
    }
  }

  /// Back to the defaults — used by Emergency Wipe, which restores every
  /// setting to what a fresh install would have.
  Future<void> reset() async {
    state = PrivacySettings.initial;
    try {
      await _box?.delete(_keyLastSeen);
      await _box?.delete(_keyReceipts);
    } catch (e) {
      debugPrint('PrivacySettings reset failed: $e');
    }
  }
}

final privacySettingsProvider =
    NotifierProvider<PrivacySettingsController, PrivacySettings>(
  PrivacySettingsController.new,
);
