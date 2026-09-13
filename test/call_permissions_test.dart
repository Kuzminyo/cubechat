import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the android manifest asks for the audio permissions a call needs', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    for (final permission in <String>[
      'android.permission.RECORD_AUDIO',
      'android.permission.MODIFY_AUDIO_SETTINGS',
    ]) {
      expect(manifest, contains(permission), reason: '$permission is missing');
    }
  });

  test('ios explains that calls use the microphone', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(plist, contains('NSMicrophoneUsageDescription'));
  });
}
