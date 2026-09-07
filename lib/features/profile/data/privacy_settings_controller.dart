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
/// Last seen stays symmetric: hiding your own presence also hides other
/// people's presence. Read receipts are send-only: if you switch them off, this
/// device stops answering with its own read receipts, but it still applies
/// receipts that peers explicitly chose to send.
///
/// **On by default.** Seeing that someone is around, and that they read you, is
/// most of what makes a conversation feel alive; a messenger that hides it
/// unasked feels broken rather than private.
@immutable
class PrivacySettings {
  const PrivacySettings({
    required this.shareLastSeen,
    required this.shareReadReceipts,
    required this.shareMapLocation,
    this.allowForwardLink = true,
  });

  /// True: publish the presence beacon, and show peers' online state.
  /// False: publish nothing, and treat every peer's presence as unknown.
  final bool shareLastSeen;

  /// True: answer with read receipts. False: never answer. Incoming receipts
  /// are still applied because they only update ticks on our own messages.
  final bool shareReadReceipts;

  /// True: publish short-lived map coordinates while the map is open.
  /// False: never request a fix for the map and withdraw our visible pin.
  final bool shareMapLocation;

  /// True: somebody forwarding one of our messages may attach a way back to
  /// us, so the line above it opens our profile. False: they attach the name
  /// and nothing else.
  ///
  /// A request rather than an enforcement, and the only kind available: the
  /// person forwarding holds our key either way, and this is us telling their
  /// build we would rather it did not pass it on. It reaches them as an
  /// [InnerPayloadType.forwardPrivacy] frame; somebody on an older build keeps
  /// linking, which is what every build did before the switch existed.
  final bool allowForwardLink;

  static const initial = PrivacySettings(
    shareLastSeen: true,
    shareReadReceipts: true,
    shareMapLocation: false,
    allowForwardLink: true,
  );

  PrivacySettings copyWith({
    bool? shareLastSeen,
    bool? shareReadReceipts,
    bool? shareMapLocation,
    bool? allowForwardLink,
  }) =>
      PrivacySettings(
        shareLastSeen: shareLastSeen ?? this.shareLastSeen,
        shareReadReceipts: shareReadReceipts ?? this.shareReadReceipts,
        shareMapLocation: shareMapLocation ?? this.shareMapLocation,
        allowForwardLink: allowForwardLink ?? this.allowForwardLink,
      );

  @override
  bool operator ==(Object other) =>
      other is PrivacySettings &&
      other.shareLastSeen == shareLastSeen &&
      other.shareReadReceipts == shareReadReceipts &&
      other.shareMapLocation == shareMapLocation &&
      other.allowForwardLink == allowForwardLink;

  @override
  int get hashCode =>
      Object.hash(shareLastSeen, shareReadReceipts, shareMapLocation,
          allowForwardLink);
}

class PrivacySettingsController extends Notifier<PrivacySettings> {
  static const _keyLastSeen = 'privacy.shareLastSeen';
  static const _keyReceipts = 'privacy.shareReadReceipts';
  static const _keyMapLocation = 'privacy.shareMapLocation';
  static const _keyForwardLink = 'privacy.allowForwardLink';

  Box<dynamic>? _box;

  /// The box opening. Writes wait on it; see [_put].
  Future<void>? _loading;

  /// Resolves once the settings on disk are in [state].
  ///
  /// Anything that *reads* a setting to decide whether to act has to wait on
  /// this, and one thing did not: the map beacon. On a background relaunch —
  /// no UI, everything cold, a poke a second in — it read "share my location"
  /// before the box had opened, got the default, and quietly did nothing. See
  /// `MapPresenceController.pokeNow`.
  Future<void> get loaded => _loading ?? Future<void>.value();

  /// True once anything in this session has set a value.
  ///
  /// The box is opened through the platform keystore and is slow enough on a
  /// cold start that somebody can flip a switch — or accept a map invitation,
  /// which turns one on — before it is ready. [_load] would then overwrite
  /// that with what was on disk a moment ago, quietly undoing it.
  bool _changed = false;

  @override
  PrivacySettings build() {
    unawaited(_loading = _load());
    return PrivacySettings.initial;
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      if (_changed) return;
      state = PrivacySettings(
        shareLastSeen: box.get(_keyLastSeen) as bool? ?? true,
        shareReadReceipts: box.get(_keyReceipts) as bool? ?? true,
        shareMapLocation: box.get(_keyMapLocation) as bool? ?? false,
        allowForwardLink: box.get(_keyForwardLink) as bool? ?? true,
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

  Future<void> setShareMapLocation(bool value) async {
    state = state.copyWith(shareMapLocation: value);
    await _put(_keyMapLocation, value);
  }

  Future<void> setAllowForwardLink(bool value) async {
    state = state.copyWith(allowForwardLink: value);
    await _put(_keyForwardLink, value);
  }

  Future<void> _put(String key, bool value) async {
    _changed = true;
    try {
      // Waits for the box rather than dropping the write into a null one,
      // which is how a setting could hold for a session and be gone on the
      // next launch.
      await _loading;
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
      await _box?.delete(_keyMapLocation);
    } catch (e) {
      debugPrint('PrivacySettings reset failed: $e');
    }
  }
}

final privacySettingsProvider =
    NotifierProvider<PrivacySettingsController, PrivacySettings>(
  PrivacySettingsController.new,
);
