import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../../../core/util/image_encode.dart';

/// How hard a photo is squeezed before it is sent — the bad-connection mode's
/// "choose the media quality".
///
/// Every photo used to be fitted to one budget, set for the worst Bluetooth
/// link: fine for a phone in a field, needlessly soft for one on Wi-Fi, and
/// still too heavy for a single bar of EDGE. Which of those somebody is on is
/// theirs to know, so it is theirs to say.
///
/// Photos only, and said so where it is set. A video goes as the file it is —
/// there is no transcoder here to squeeze it with — and the preview screen's
/// "original" still sends any photo untouched, whatever this says.
///
/// [MediaQuality.standard] by default, which is the one budget every build
/// before this used: nothing changes for anybody who never opens the setting.
class MediaQualityController extends Notifier<MediaQuality> {
  static const _key = 'media.photo_quality';

  Box<dynamic>? _box;
  Future<void>? _loading;

  /// Completes once the stored choice has been read. The circle lens setting
  /// has the reason written out: act on a setting before it is loaded and it
  /// looks exactly like one that did not survive a restart.
  Future<void> get loaded => _loading ?? Future<void>.value();

  /// The choice as stored, for a sender about to encode — waited for rather
  /// than read, so a photo sent in the first moment after launch is not
  /// quietly sent at the default.
  Future<MediaQuality> resolved() async {
    await loaded;
    return state;
  }

  @override
  MediaQuality build() {
    unawaited(_loading = _load());
    return MediaQuality.standard;
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final name = box.get(_key) as String?;
      state = MediaQuality.values
              .where((q) => q.name == name)
              .firstOrNull ??
          MediaQuality.standard;
    } catch (e) {
      debugPrint('Media quality load failed: $e');
    }
  }

  Future<void> set(MediaQuality quality) async {
    state = quality;
    // A choice made while the box is still opening would otherwise have no box
    // to go into, and then be overwritten by the load it raced.
    await loaded;
    state = quality;
    try {
      await _box?.put(_key, quality.name);
    } catch (e) {
      debugPrint('Media quality persist failed: $e');
    }
  }

  /// Back to the default — Emergency Wipe puts every setting back to what a
  /// fresh install would have.
  Future<void> reset() async {
    await loaded;
    state = MediaQuality.standard;
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('Media quality reset failed: $e');
    }
  }
}

final mediaQualityProvider =
    NotifierProvider<MediaQualityController, MediaQuality>(
  MediaQualityController.new,
);
