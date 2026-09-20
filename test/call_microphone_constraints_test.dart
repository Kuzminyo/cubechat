import 'package:cubechat/features/call/data/call_media.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('FlutterWebRTC.Method');
  const events = MethodChannel('FlutterWebRTC/peerConnectionEventtest-peer');

  test('native microphone receives gain and noise constraints it can parse',
      () async {
    Map<Object?, Object?>? audio;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'createPeerConnection') {
        return {'peerConnectionId': 'test-peer'};
      }
      if (call.method == 'getUserMedia') {
        final args = call.arguments as Map<Object?, Object?>;
        final constraints = args['constraints'] as Map<Object?, Object?>;
        audio = constraints['audio'] as Map<Object?, Object?>;
        throw PlatformException(
            code: 'test-stop', message: 'captured microphone settings');
      }
      return null;
    });
    final media = WebRtcCallMedia();
    try {
      await expectLater(media.offer({}), throwsA(anything));
      expect(audio, isNotNull);
      final optional = audio!['optional'] as List<Object?>?;
      expect(optional, isNotNull,
          reason: 'native parser only reads mandatory/optional');
      expect(optional, contains(equals({'googAutoGainControl': true})));
      expect(optional, contains(equals({'googNoiseSuppression': true})));
      expect(optional, contains(equals({'googEchoCancellation': true})));
    } finally {
      await media.close();
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(events, null);
    }
  });
}
