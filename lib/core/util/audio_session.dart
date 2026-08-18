import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';

import 'debug_log.dart';
import 'platform_info.dart';

/// How this app is allowed to touch the phone's audio.
///
/// iOS has one audio session per process and every app shares the same device.
/// Taking it without saying how leaves the defaults in charge, and the defaults
/// assume an app whose whole purpose is sound. This one's purpose is a
/// conversation that occasionally contains a voice note, which is a different
/// claim on the speaker entirely.
///
/// The reported symptom: "захожу в приложение, играет трек по наушникам, и в
/// одном наушнике пропадает звук на несколько секунд". That is a Bluetooth
/// route change, and it has a specific cause — see [recordConfig].
class AudioSession {
  const AudioSession._();

  /// Category options for recording a voice note.
  ///
  /// `record` defaults to `[defaultToSpeaker, allowBluetooth,
  /// allowBluetoothA2DP]`, and **allowBluetooth is the one that costs**. It
  /// permits HFP — the hands-free profile, which is a bidirectional *mono*
  /// link — so the moment the session activates, iOS tears the headphones off
  /// A2DP stereo and re-establishes them as a headset. Music that was playing
  /// in both ears comes back in one, a couple of seconds later, which is
  /// exactly the report.
  ///
  /// Dropping it means a voice note is recorded through the phone's own
  /// microphone rather than the one in the earbud. That is the right trade for
  /// this app: a voice note is a few seconds held at arm's length, and nobody
  /// has asked to record through their headset — whereas everyone notices
  /// their music being cut in half.
  ///
  /// `allowBluetoothA2DP` stays, so playback still goes to the headphones.
  static const IosRecordConfig iosRecord = IosRecordConfig(
    categoryOptions: [
      IosAudioCategoryOption.defaultToSpeaker,
      IosAudioCategoryOption.allowBluetoothA2DP,
    ],
  );

  /// Play a voice note *alongside* whatever else is going on.
  ///
  /// audioplayers defaults to `playback` with no options, and a `playback`
  /// session without `mixWithOthers` stops everyone else's audio when it
  /// activates. For a music app that is correct; for a chat app it means
  /// tapping a two-second voice note kills the podcast someone was listening
  /// to and does not bring it back.
  ///
  /// `mixWithOthers` also means we never take the session exclusively, so
  /// nothing has to be handed back afterwards.
  static AudioContext get playback => AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: const {AVAudioSessionOptions.mixWithOthers},
        ),
        android: const AudioContextAndroid(
          isSpeakerphoneOn: false,
          stayAwake: false,
          contentType: AndroidContentType.speech,
          usageType: AndroidUsageType.media,
          // Ducking rather than stopping, for the same reason.
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
      );

  /// Apply the playback policy process-wide. Safe to call more than once.
  ///
  /// Deliberately *not* called during boot. Setting the global context creates
  /// the audio plugin's session on iOS, and doing that at launch is half of the
  /// bug this file exists to fix — the app would announce itself to the audio
  /// system before anyone had asked it to make a sound. It is called from the
  /// voice-playback controller the first time a player is actually needed.
  static Future<void> applyPlaybackPolicy() async {
    if (_applied) return;
    _applied = true;
    try {
      await AudioPlayer.global.setAudioContext(playback);
    } catch (e) {
      // A phone that refuses the category is not a reason to fail playing a
      // voice note; it just plays under whatever the defaults were.
      _applied = false;
      DebugLog.instance.log('AUDIO', 'audio context refused: $e');
    }
  }

  static bool _applied = false;

  /// Whether the recording config above is worth logging about on this
  /// platform. Android has no equivalent route problem.
  static bool get isIOS => PlatformInfo.isIOS;
}
