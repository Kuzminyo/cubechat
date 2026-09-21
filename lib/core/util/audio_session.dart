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
/// route change, and it has a specific cause — see [voiceRecord].
class AudioSession {
  const AudioSession._();

  /// Voice-note capture, separate from WebRTC's bidirectional call session.
  ///
  /// **The plain microphone, the way Telegram records one.** Read from their
  /// source on 2026-09-21 rather than remembered: Android's `MediaController`
  /// opens `AudioRecord(MediaRecorder.AudioSource.DEFAULT, 48000, mono, 16-bit)`
  /// and attaches no AutomaticGainControl, NoiseSuppressor or echo canceller
  /// anywhere; iOS's `ManagedAudioRecorder` is a `RemoteIO` unit at 48 kHz —
  /// not the voice-processing one — in the session's `.default` mode.
  ///
  /// This is a revert. Build 1085 switched the platform AGC and noise
  /// suppression on for Android, on the reasoning that the platform would do
  /// the work once. What came back from the field was "плохо слышно, а иногда
  /// микрофон вообще не улавливает тихий звук": a phone's built-in noise
  /// suppressor is tuned for calls, treats quiet speech as the noise floor and
  /// gates it, and the AGC chasing it pumps the level about. A voice note is
  /// held close to the mouth; it does not need rescuing from a noisy line.
  /// record_ios uses AVAudioRecorder for AAC files, which never applied the
  /// effects anyway, so iOS only gains the sample rate.
  static RecordConfig get voiceRecord => RecordConfig(
        encoder: AudioEncoder.aacLc,
        numChannels: 1,
        // More bandwidth and encoder headroom than 22.05 kHz / 24 kbps.
        //
        // **64 kbps, and it is the ceiling worth paying for.** AAC-LC on mono
        // speech is transparent enough here that the next step up buys
        // nothing a listener would name, while every step costs airtime: this
        // is about 480 KB a minute before container overhead, four times the
        // original payload, and a voice note crosses BLE at roughly 14 KB/s.
        //
        // Opus would sound better again at half this rate, and it is why
        // Telegram sounds the way it does. It is not available here: the
        // recorder writes Opus into OGG on Android and CAF on iOS, and neither
        // platform's player opens the other's container — an Android note
        // would simply not play on an iPhone. Carrying our own codec on both
        // sides is the price of that, and it is a different piece of work.
        //
        // Mono either way, for the same transfer budget.
        //
        // 48 kHz, Telegram's rate on both platforms. The cost is set by the
        // bit rate, not by this, so the payload per minute does not move.
        sampleRate: 48000,
        bitRate: 64000,
        autoGain: false,
        noiseSuppress: false,
        echoCancel: false,
        androidConfig: const AndroidRecordConfig(
          // DEFAULT rather than MIC, to match Telegram exactly. AOSP's audio
          // policy maps one to the other; an OEM that tunes them differently
          // tunes DEFAULT for this.
          audioSource: AndroidAudioSource.defaultSource,
          // Match the iOS voice-note policy: do not start headset SCO just
          // because earbuds are connected. Calls manage their own HFP route.
          manageBluetooth: false,
        ),
        iosConfig: iosRecord,
      );

  /// The same microphone as [voiceRecord], delivered as raw 48 kHz PCM for
  /// the Opus encoder rather than written to a file by the platform.
  ///
  /// Every choice above carries over — plain source, no AGC, no noise
  /// suppression — and one more matters here: with echo cancellation off,
  /// record_ios builds its stream on a plain `AVAudioEngine` input rather than
  /// the voice-processing unit, so the samples are the microphone's own.
  static RecordConfig get voiceStream {
    final file = voiceRecord;
    return RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      numChannels: 1,
      sampleRate: 48000,
      autoGain: false,
      noiseSuppress: false,
      echoCancel: false,
      androidConfig: file.androidConfig,
      iosConfig: file.iosConfig,
    );
  }

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
  /// `mixWithOthers` follows the same switch as playback does. Recording and
  /// playing are the same question asked twice: if music should stop while you
  /// watch a round message, it should stop while you record one.
  static IosRecordConfig get iosRecord => IosRecordConfig(
        categoryOptions: [
          IosAudioCategoryOption.defaultToSpeaker,
          IosAudioCategoryOption.allowBluetoothA2DP,
          if (!takesFocus) IosAudioCategoryOption.mixWithOthers,
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
  /// **True when the person has asked us to stop their music.**
  ///
  /// Set from `AudioFocusController`, which reads it out of settings at launch
  /// and writes it when the switch moves. A field rather than a lookup because
  /// this file is deliberately free of Riverpod: it is the boundary with the
  /// platform's audio, and one boolean crossing inwards is cheaper to reason
  /// about than a provider crossing outwards.
  ///
  /// A round message is the case that asked for it. Mixing is right for a voice
  /// note and wrong for a face talking to you over somebody's playlist, and
  /// which one a person wants is not knowable from here.
  static bool takesFocus = false;

  /// Change it and re-apply, so the switch takes effect on the next sound
  /// rather than the next launch.
  static Future<void> setTakesFocus(bool value) async {
    if (takesFocus == value) return;
    takesFocus = value;
    if (!_applied) return;
    _applied = false;
    await applyPlaybackPolicy();
  }

  static AudioContext get playback => AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          // Without `mixWithOthers` a `playback` session stops everyone else's
          // audio when it activates, and does not bring it back. That is the
          // whole of what the switch buys and the whole of what it costs.
          options: takesFocus
              ? const <AVAudioSessionOptions>{}
              : const {AVAudioSessionOptions.mixWithOthers},
        ),
        android: AudioContextAndroid(
          isSpeakerphoneOn: false,
          stayAwake: false,
          contentType: AndroidContentType.speech,
          usageType: AndroidUsageType.media,
          // Ducking rather than stopping, for the same reason — unless asked
          // for the other one, where a plain `gain` pauses the other app
          // properly and hands the focus back when we stop.
          audioFocus: takesFocus
              ? AndroidAudioFocus.gain
              : AndroidAudioFocus.gainTransientMayDuck,
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

  /// Something else set the session's category, so the next voice note must
  /// set it back rather than trust that it is still ours.
  ///
  /// iOS has one session for the whole process. The incoming-call ringtone
  /// takes it as `soloAmbient`, and without this a voice note played after a
  /// declined call would inherit a category that the silent switch mutes.
  static void markPlaybackPolicyStale() => _applied = false;

  /// Whether the recording config above is worth logging about on this
  /// platform. Android has no equivalent route problem.
  static bool get isIOS => PlatformInfo.isIOS;
}
