import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

import '../../../core/util/audio_session.dart';
import '../../../core/util/debug_log.dart';
import '../../../core/util/platform_info.dart';

/// The sounds a call makes before anybody is talking.
enum CallTone {
  /// This phone is being called.
  incoming,
}

/// Plays and stops [CallTone]s. Injected so the controller can be tested with
/// no audio plugin, and so the rules about when a tone plays live in one place
/// that is not the one making the noise.
abstract interface class CallTones {
  Future<void> play(CallTone tone);
  Future<void> stop();
}

/// For tests and for platforms with nothing to ring.
class SilentCallTones implements CallTones {
  const SilentCallTones();

  @override
  Future<void> play(CallTone tone) async {}

  @override
  Future<void> stop() async {}
}

/// The ringtone, through the same audio plugin voice notes use.
///
/// **An incoming call made no sound at all.** The call screen came up in
/// silence, so a phone lying on a table missed every call, and the caller —
/// seeing "ringing" and hearing nothing — hung up after ten seconds (callId
/// 22fc7aa8). A ring existed nowhere in the tree.
///
/// **Only the incoming ring, not a ringback on the caller's side, and that is
/// deliberate.** By the time a caller hears ringing, WebRTC already owns the
/// audio: the microphone is open. audioplayers on iOS deactivates the shared
/// `AVAudioSession` the moment its last player stops, and on Android setting a
/// player's context writes `AudioManager.mode` process-wide. Either would pull
/// the session out from under the call at exactly the moment it connects — a
/// call with no sound, traded for a tone before it. The callee has no media
/// open until they answer, which is why the ring is safe there, and why it is
/// stopped and awaited before the microphone is asked for.
///
/// Foreground only. Ringing a phone that is locked or backgrounded needs
/// CallKit on iOS and a full-screen notification on Android; neither exists
/// here yet.
class AudioCallTones implements CallTones {
  AudioPlayer? _player;
  Timer? _buzz;
  CallTone? _playing;

  static const _asset = 'sounds/call_incoming.wav';

  /// A ringtone, not a voice note: the ring volume and the ringer mode decide,
  /// and other audio gives way until the call is answered or gone.
  static const _android = AudioContextAndroid(
    isSpeakerphoneOn: false,
    audioMode: AndroidAudioMode.normal,
    stayAwake: false,
    contentType: AndroidContentType.sonification,
    usageType: AndroidUsageType.notificationRingtone,
    audioFocus: AndroidAudioFocus.gainTransient,
  );

  /// `soloAmbient` is the category the ring/silent switch mutes, which is what
  /// a ringer should do. The vibration below still reaches a silenced phone.
  static final _ios = AudioContextIOS(
    category: AVAudioSessionCategory.soloAmbient,
  );

  @override
  Future<void> play(CallTone tone) async {
    if (_playing == tone) return;
    await stop();
    if (!PlatformInfo.isMobile) return;
    _playing = tone;
    try {
      final player = _player ??= AudioPlayer();
      await player.setAudioContext(AudioContext(android: _android, iOS: _ios));
      if (PlatformInfo.isIOS) AudioSession.markPlaybackPolicyStale();
      await player.setReleaseMode(ReleaseMode.loop);
      if (_playing != tone) return;
      await player.play(AssetSource(_asset));
      // Answered or hung up while the plugin was still starting: the stop
      // above found nothing playing yet, so it is this side's to undo.
      if (_playing != tone) {
        await player.stop();
        return;
      }
      DebugLog.instance.log('CALL', 'ringtone on');
    } catch (e) {
      // A ring that cannot play is not a reason to miss the call: the screen
      // and the vibration still say it.
      DebugLog.instance.log('CALL', 'ringtone could not play: $e');
    }
    if (_playing != tone) return;
    unawaited(HapticFeedback.vibrate());
    _buzz = Timer.periodic(
      const Duration(milliseconds: 2400),
      (_) => unawaited(HapticFeedback.vibrate()),
    );
  }

  @override
  Future<void> stop() async {
    _buzz?.cancel();
    _buzz = null;
    if (_playing == null) return;
    _playing = null;
    try {
      await _player?.stop();
      DebugLog.instance.log('CALL', 'ringtone off');
    } catch (e) {
      DebugLog.instance.log('CALL', 'ringtone could not stop: $e');
    }
  }
}
