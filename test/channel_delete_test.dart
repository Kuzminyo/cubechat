import 'dart:convert';
import 'dart:typed_data';

import 'package:cubechat/core/transport/channel_delete.dart';
import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:flutter_test/flutter_test.dart';

/// The owner closing a room, and everything that must not be able to.
///
/// This is the one instruction in the protocol with no undo: it takes a room
/// off every phone that honours it. So the interesting tests are the refusals
/// — a padded frame, a truncated one, a version nobody knows, and above all a
/// delete lifted from one room and pointed at another.
void main() {
  group('the payload', () {
    test('round-trips a room name', () {
      const name = '#кімната';
      final bytes = const ChannelDelete(channelName: name).encode();
      expect(ChannelDelete.decode(bytes).channelName, name);
    });

    test('sits in the channel family and collides with nothing', () {
      expect(InnerPayloadType.channelDelete.tag, 0xE6);
      final tags = InnerPayloadType.values.map((v) => v.tag).toList();
      expect(
        tags.length,
        tags.toSet().length,
        reason: 'a colliding tag byte has no compile error and no failing '
            'test anywhere else — it ships and breaks installed phones',
      );
    });

    test('a padded frame is refused', () {
      // Exact length, not "at least": trailing bytes are what a relay would
      // add, and every decoder in this protocol refuses them.
      final good = const ChannelDelete(channelName: '#room').encode();
      final padded = Uint8List.fromList(<int>[...good, 0]);
      expect(() => ChannelDelete.decode(padded), throwsFormatException);
    });

    test('a truncated frame is refused', () {
      final good = const ChannelDelete(channelName: '#room').encode();
      expect(
        () => ChannelDelete.decode(good.sublist(0, good.length - 1)),
        throwsFormatException,
      );
      expect(
        () => ChannelDelete.decode(Uint8List.fromList(<int>[1, 4])),
        throwsFormatException,
      );
    });

    test('an unknown version is refused rather than guessed at', () {
      final bytes = const ChannelDelete(channelName: '#room').encode();
      bytes[0] = 0x02;
      expect(() => ChannelDelete.decode(bytes), throwsFormatException);
    });

    test('a nameless delete is refused', () {
      expect(
        () => ChannelDelete.decode(Uint8List.fromList(<int>[1, 0, 0])),
        throwsFormatException,
      );
      expect(
        () => const ChannelDelete(channelName: '').encode(),
        throwsFormatException,
      );
      // Whitespace is not a name either: it would decode, match nothing, and
      // leave a delete floating that no room can claim.
      final spaces = Uint8List.fromList(<int>[1, 3, ...utf8.encode('   ')]);
      expect(() => ChannelDelete.decode(spaces), throwsFormatException);
    });

    test('bytes that are not UTF-8 are refused', () {
      final bad = Uint8List.fromList(<int>[1, 2, 0xC3, 0x28]);
      expect(() => ChannelDelete.decode(bad), throwsFormatException);
    });

    test('a name too long to encode is refused rather than truncated', () {
      final long = '#${'a' * 300}';
      expect(
        () => ChannelDelete(channelName: long).encode(),
        throwsFormatException,
      );
    });

    test('the name is what binds it to one room', () {
      // The frame is signed over this body, so the name travels covered by the
      // signature — which is what stops a delete taken from one room being
      // replayed into another. The receiver compares the two; here we only pin
      // that the name really is carried and comes back intact.
      final bytes = const ChannelDelete(channelName: '#alpha').encode();
      expect(ChannelDelete.decode(bytes).channelName, '#alpha');
      expect(
        ChannelDelete.decode(bytes).channelName == '#beta',
        isFalse,
        reason: 'the ingest drops a mismatch; it can only do that because the '
            'name is in here',
      );
    });
  });
}
