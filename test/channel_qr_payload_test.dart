import 'dart:typed_data';

import 'package:cubechat/features/channels/models/channel.dart';
import 'package:cubechat/features/qr/data/channel_qr_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('channel QR payload round-trips the name and membership key', () {
    final channel = Channel(
      name: '#road-trip',
      hasPassword: true,
      key: Uint8List.fromList(List<int>.generate(32, (i) => i)),
      tag: Uint8List(8),
      joinedAt: DateTime(2026, 8, 3),
    );

    final encoded = ChannelQrPayload.encode(channel);
    final decoded = ChannelQrPayload.tryDecode(encoded);

    expect(encoded, startsWith(ChannelQrPayload.prefix));
    expect(decoded?.name, '#road-trip');
    expect(decoded?.key, channel.key);
  });

  test('unrelated QR data is ignored', () {
    expect(ChannelQrPayload.tryDecode('https://example.com'), isNull);
  });

  test('truncated channel payload is rejected', () {
    expect(
      () => ChannelQrPayload.tryDecode('${ChannelQrPayload.prefix}abc'),
      throwsFormatException,
    );
  });
}
