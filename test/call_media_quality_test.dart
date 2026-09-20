import 'package:cubechat/features/call/data/call_media.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('FlutterWebRTC.Method');
const _eventName = 'FlutterWebRTC/peerConnectionEventquality-peer';
const _track = {
  'id': 'mic',
  'label': 'headset',
  'kind': 'audio',
  'enabled': true,
  'settings': <String, Object?>{}
};
Map<String, Object?> _sender() => {
      'senderId': 'sender',
      'track': _track,
      'ownsTrack': true,
      'rtpParameters': {
        'transactionId': 'fresh-parameters',
        'rtcp': {'cname': 'audio', 'reducedSize': true},
        'encodings': [
          {'active': true, 'ssrc': 123, 'priority': 'low'}
        ],
        'headerExtensions': <Object?>[],
        'codecs': <Object?>[],
      },
    };

void main() {
  testWidgets(
      'RTCP adapts the native sender, stale reports cannot restore it, close stops polling',
      (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    var sequence = 1;
    var loss = 0.12;
    var rtt = 0.8;
    var statsCalls = 0;
    final caps = <int>[];
    final sources = <Object?>[];
    messenger.setMockMethodCallHandler(
        const MethodChannel(_eventName), (_) async => null);
    messenger.setMockMethodCallHandler(_channel, (call) async {
      switch (call.method) {
        case 'createPeerConnection':
          return {'peerConnectionId': 'quality-peer'};
        case 'getUserMedia':
          return {
            'streamId': 'local',
            'audioTracks': [_track],
            'videoTracks': <Object?>[]
          };
        case 'addTrack':
          return _sender();
        case 'createOffer':
        case 'getLocalDescription':
          return {
            'type': 'offer',
            'sdp': 'v=0\r\na=candidate:1 1 udp 1 127.0.0.1 9 typ relay\r\n'
          };
        case 'getStats':
          statsCalls++;
          return {
            'stats': [
              {
                'id': 'remote-audio',
                'type': 'remote-inbound-rtp',
                'timestamp': statsCalls.toDouble(),
                'values': {
                  'kind': 'audio',
                  'reportsReceived': sequence,
                  'fractionLost': loss,
                  'roundTripTime': rtt
                },
              }
            ]
          };
        case 'getSenders':
          return {
            'senders': [_sender()]
          };
        case 'rtpSenderSetParameters':
          final args = call.arguments as Map<Object?, Object?>;
          final parameters = args['parameters'] as Map<Object?, Object?>;
          final encoding = (parameters['encodings'] as List<Object?>).single
              as Map<Object?, Object?>;
          caps.add(encoding['maxBitrate']! as int);
          sources.add(encoding['ssrc']);
          return {'result': true};
        default:
          return null;
      }
    });
    Future<void> event(Map<String, Object?> data) async {
      await messenger.handlePlatformMessage(_eventName,
          const StandardMethodCodec().encodeSuccessEnvelope(data), (_) {});
      await tester.pump();
    }

    final media = WebRtcCallMedia();
    try {
      final opening = media.offer({});
      await tester.pump();
      await event({'event': 'iceGatheringState', 'state': 'complete'});
      await opening;
      await event({'event': 'peerConnectionState', 'state': 'connected'});
      expect(caps, [16000]);
      loss = 0;
      rtt = 0.1;
      for (var i = 0; i < 9; i++) {
        await tester.pump(const Duration(seconds: 3));
      }
      expect(caps, [16000], reason: 'a repeated RTCP report is not recovery');
      for (var i = 0; i < 8; i++) {
        sequence++;
        await tester.pump(const Duration(seconds: 3));
        // RTCP can arrive less often than our three-second poll.
        await tester.pump(const Duration(seconds: 3));
      }
      expect(caps, [16000, 32000]);
      expect(sources, [123, 123]);
      await tester.runAsync(media.close);
      final afterClose = statsCalls;
      await tester.pump(const Duration(seconds: 30));
      expect(statsCalls, afterClose);
    } finally {
      await tester.runAsync(media.close);
      messenger.setMockMethodCallHandler(_channel, null);
      messenger.setMockMethodCallHandler(const MethodChannel(_eventName), null);
    }
  });
}
