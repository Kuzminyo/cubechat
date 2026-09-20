import 'package:cubechat/core/util/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    AudioSession.takesFocus = false;
  });

  test('Android voice notes request native speech effects without call routing',
      () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final config = AudioSession.voiceRecord;
    // Check the values that cross the plugin boundary, not just Dart fields.
    final map = config.toMap();
    expect(map['autoGain'], isTrue);
    expect(map['noiseSuppress'], isTrue);
    expect(map['echoCancel'], isFalse);
    final android = map['androidConfig'] as Map<String, dynamic>;
    expect(android['audioSource'], 'mic');
    expect(android['useLegacy'], isFalse);
    expect(android['manageBluetooth'], isFalse);
    expect(android['audioManagerMode'], 'modeNormal');
    expect(android['speakerphone'], isFalse);
    expect(android['muteAudio'], isFalse);
  });

  test('iOS AAC keeps A2DP policy without claiming unsupported file effects',
      () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final config = AudioSession.voiceRecord;
    expect(config.autoGain, isFalse);
    expect(config.noiseSuppress, isFalse);
    expect(config.echoCancel, isFalse);
    expect(
      config.iosConfig.categoryOptions,
      contains(IosAudioCategoryOption.allowBluetoothA2DP),
    );
    expect(
      config.iosConfig.categoryOptions,
      isNot(contains(IosAudioCategoryOption.allowBluetooth)),
    );
    expect(
      config.iosConfig.categoryOptions,
      contains(IosAudioCategoryOption.mixWithOthers),
    );
    AudioSession.takesFocus = true;
    expect(
      AudioSession.voiceRecord.iosConfig.categoryOptions,
      isNot(contains(IosAudioCategoryOption.mixWithOthers)),
    );
    expect(
      AudioSession.voiceRecord.iosConfig.categoryOptions,
      isNot(contains(IosAudioCategoryOption.allowBluetooth)),
    );
  });

  test('voice notes retain interoperable mono AAC with bounded payload budget',
      () {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      debugDefaultTargetPlatformOverride = platform;
      final config = AudioSession.voiceRecord;
      expect(config.encoder, AudioEncoder.aacLc);
      expect(config.numChannels, 1);
      expect(config.sampleRate, 32000);
      // A minute of note, in bytes before container overhead. Pinned as the
      // cost rather than as the number, because the cost is what the BLE
      // budget is spent on: 480 KB a minute at roughly 14 KB/s on the radio.
      expect(config.bitRate * 60 ~/ 8, 480000);
    }
  });
}
