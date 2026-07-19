import 'dart:typed_data';

import 'package:cubechat/core/transport/frame.dart';
import 'package:cubechat/core/transport/frame_fragment.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(int seed, int len) =>
    Uint8List.fromList(List.generate(len, (i) => (seed * 7 + i) & 0xFF));

void main() {
  group('fragmentFrame', () {
    test('returns the frame unchanged when it already fits', () {
      final frame = Frame(type: FrameType.transport, payload: _bytes(1, 50)).encode();
      final parts = fragmentFrame(frame, 200);
      expect(parts, hasLength(1));
      expect(parts.single, frame);
    });

    test('every fragment fits the max size and is a fragment frame', () {
      final frame = Frame(type: FrameType.transport, payload: _bytes(2, 900)).encode();
      const maxFrameBytes = 180;
      final parts = fragmentFrame(frame, maxFrameBytes);
      expect(parts.length, greaterThan(1));
      for (final p in parts) {
        expect(p.length, lessThanOrEqualTo(maxFrameBytes));
        expect(p[0], FrameType.fragment.value);
      }
    });

    test('all fragments share one fragId and carry a consistent count', () {
      final frame = Frame(type: FrameType.transport, payload: _bytes(3, 500)).encode();
      final parts = fragmentFrame(frame, 120);
      final fragId = parts.first.sublist(1, 5);
      for (var i = 0; i < parts.length; i++) {
        expect(parts[i].sublist(1, 5), fragId);
        expect(parts[i][5], i); // index
        expect(parts[i][6], parts.length); // count
      }
    });

    test('handles exactly 255 fragments but rejects 256', () {
      // maxSlice = 1 -> one byte per fragment, so fragment count == byte count.
      const maxFrameBytes = 1 + kFragHeaderLen + 1;
      expect(fragmentFrame(_bytes(4, 255), maxFrameBytes), hasLength(255));
      expect(() => fragmentFrame(_bytes(4, 256), maxFrameBytes),
          throwsArgumentError);
    });
  });

  group('FrameFragmentReassembler', () {
    Uint8List? feedAll(
      FrameFragmentReassembler r,
      List<Uint8List> parts, {
      String link = 'peerA',
    }) {
      Uint8List? out;
      for (final p in parts) {
        final frame = Frame.decode(p);
        expect(frame.type, FrameType.fragment);
        out = r.ingest(link, frame.payload) ?? out;
      }
      return out;
    }

    test('round-trips a fragmented frame in order', () {
      final original = Frame(type: FrameType.transport, payload: _bytes(5, 700)).encode();
      final parts = fragmentFrame(original, 150);
      final r = FrameFragmentReassembler();
      final out = feedAll(r, parts);
      expect(out, isNotNull);
      expect(out, original);
    });

    test('round-trips when fragments arrive out of order', () {
      final original = Frame(type: FrameType.transport, payload: _bytes(6, 640)).encode();
      final parts = fragmentFrame(original, 130).reversed.toList();
      final r = FrameFragmentReassembler();
      final out = feedAll(r, parts);
      expect(out, original);
    });

    test('returns null until the last fragment lands', () {
      final original = Frame(type: FrameType.transport, payload: _bytes(7, 400)).encode();
      final parts = fragmentFrame(original, 120);
      final r = FrameFragmentReassembler();
      for (var i = 0; i < parts.length - 1; i++) {
        expect(r.ingest('peerA', Frame.decode(parts[i]).payload), isNull);
      }
      expect(r.ingest('peerA', Frame.decode(parts.last).payload), original);
    });

    test('ignores a duplicate fragment', () {
      final original = Frame(type: FrameType.transport, payload: _bytes(8, 300)).encode();
      final parts = fragmentFrame(original, 110);
      final r = FrameFragmentReassembler();
      // Feed the first fragment twice, then the rest.
      expect(r.ingest('peerA', Frame.decode(parts.first).payload), isNull);
      expect(r.ingest('peerA', Frame.decode(parts.first).payload), isNull);
      Uint8List? out;
      for (var i = 1; i < parts.length; i++) {
        out = r.ingest('peerA', Frame.decode(parts[i]).payload) ?? out;
      }
      expect(out, original);
    });

    test('scopes fragIds per link — two links never cross-contaminate', () {
      // Two frames fragmented independently; force identical-looking ids by
      // reusing the same reassembler under different link keys.
      final a = Frame(type: FrameType.transport, payload: _bytes(9, 500)).encode();
      final b = Frame(type: FrameType.peerAnnouncement, payload: _bytes(10, 480)).encode();
      final partsA = fragmentFrame(a, 140);
      final partsB = fragmentFrame(b, 140);
      final r = FrameFragmentReassembler();
      final outA = feedAll(r, partsA, link: 'peerA');
      final outB = feedAll(r, partsB, link: 'peerB');
      expect(outA, a);
      expect(outB, b);
    });

    test('drops malformed fragment payloads', () {
      final r = FrameFragmentReassembler();
      expect(r.ingest('peerA', Uint8List(0)), isNull);
      expect(r.ingest('peerA', Uint8List.fromList([1, 2, 3])), isNull);
      // count=0 is invalid.
      expect(r.ingest('peerA', Uint8List.fromList([0, 0, 0, 0, 0, 0, 9])), isNull);
    });
  });
}
