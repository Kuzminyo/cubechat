import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../../../core/util/audio_session.dart';

/// Whether a round message takes the speaker to itself.
///
/// **Two right answers, which is why it is a switch.** Playing a two-second
/// voice note should not kill the podcast somebody is listening to — that is
/// the whole argument in [AudioSession.playback] and it is why this app mixes
/// by default. A round video message is not a two-second voice note: it has a
/// face in it and something to say, and hearing it over music is hearing
/// neither. Which of those a person wants is not knowable from here.
///
/// One switch for both ends of it, deliberately. Recording and playing are the
/// same question asked twice — if music should stop while you watch a circle,
/// it should stop while you record one — and two switches that are always set
/// the same way is one switch with extra steps.
///
/// Off by default, which is the behaviour every build so far has had: music
/// keeps playing, ducked on Android. A default that changes what the phone
/// does with somebody else's audio is not a default to flip quietly.
class AudioFocusController extends Notifier<bool> {
  static const _key = 'audio.exclusive_for_circles';

  Box<dynamic>? _box;
  Future<void>? _loading;

  /// Completes once the stored choice has been read and handed to the audio
  /// layer. Anything about to make a sound waits for this, or the first note
  /// of a session plays under whichever policy the default named.
  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  bool build() {
    unawaited(_loading = _load());
    return false;
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      state = box.get(_key) as bool? ?? false;
      AudioSession.takesFocus = state;
    } catch (e) {
      debugPrint('Audio focus load failed: $e');
    }
  }

  Future<void> set(bool exclusive) async {
    state = exclusive;
    // Told before it is stored: the next thing to make a sound should hear the
    // new answer even if the disk write is slow or fails.
    await AudioSession.setTakesFocus(exclusive);
    try {
      await _box?.put(_key, exclusive);
    } catch (e) {
      debugPrint('Audio focus persist failed: $e');
    }
  }

  /// Back to mixing — used by Emergency Wipe, which puts every setting back to
  /// what a fresh install would have.
  Future<void> reset() async {
    state = false;
    await AudioSession.setTakesFocus(false);
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('Audio focus reset failed: $e');
    }
  }
}

final audioFocusProvider =
    NotifierProvider<AudioFocusController, bool>(AudioFocusController.new);
