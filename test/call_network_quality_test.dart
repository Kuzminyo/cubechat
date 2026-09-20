import 'package:cubechat/features/call/domain/call_network_quality.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('loss reduces bandwidth immediately; recovery needs sustained health',
      () {
    final quality = CallNetworkQuality();
    final normal = quality.bitrate;
    quality.sample(loss: 0.12, rtt: 0.8);
    expect(quality.bitrate, lessThan(normal));
    final constrained = quality.bitrate;
    quality.sample(loss: 0, rtt: 0.1);
    expect(quality.bitrate, constrained);
    for (var i = 0; i < 8; i++) {
      quality.sample(loss: 0, rtt: 0.1);
    }
    expect(quality.bitrate, normal);
  });

  test('missing measurements cannot restore quality', () {
    final quality = CallNetworkQuality()..sample(loss: 0.2, rtt: 1);
    final constrained = quality.bitrate;
    for (var i = 0; i < 12; i++) {
      quality.sample();
    }
    expect(quality.bitrate, constrained);
  });

  test('oscillating network does not alternate bitrate every sample', () {
    final quality = CallNetworkQuality()..sample(loss: 0.1, rtt: 0.7);
    final constrained = quality.bitrate;
    for (var i = 0; i < 10; i++) {
      quality.sample(loss: 0, rtt: 0.1);
      quality.sample(loss: 0.06, rtt: 0.4);
    }
    expect(quality.bitrate, constrained);
  });
}
