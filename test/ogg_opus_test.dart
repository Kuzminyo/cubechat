import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cubechat/core/audio/ogg_opus.dart';
import 'package:flutter_test/flutter_test.dart';

/// The container half of Opus voice notes — pure Dart, so every byte of it is
/// checked here rather than on a phone.
void main() {
  /// A 20 ms full-band CELT frame's TOC, with [length] bytes after it.
  Uint8List packet(int length, [int seed = 0]) {
    final rng = math.Random(seed);
    return Uint8List.fromList([
      0xF8,
      for (var i = 1; i < length; i++) rng.nextInt(256),
    ]);
  }

  List<Uint8List> pages(Uint8List file) {
    final out = <Uint8List>[];
    var at = 0;
    while (at < file.length) {
      final segments = file[at + 26];
      var body = 0;
      for (var s = 0; s < segments; s++) {
        body += file[at + 27 + s];
      }
      final end = at + 27 + segments + body;
      out.add(Uint8List.sublistView(file, at, end));
      at = end;
    }
    return out;
  }

  test("Ogg's CRC is not the zip one", () {
    // CRC-32/POSIX's check value is 0x765E7680 for "123456789"; Ogg is the
    // same polynomial and initial value without the final inversion. A page
    // with the zip CRC on it is skipped by every player there is.
    expect(
      oggCrc(Uint8List.fromList('123456789'.codeUnits)),
      0x765E7680 ^ 0xFFFFFFFF,
    );
  });

  test('a packet says how long it is from its first byte', () {
    expect(opusPacketSamples(Uint8List.fromList([0xF8])), 960); // CELT 20 ms
    expect(opusPacketSamples(Uint8List.fromList([0x48])), 960); // SILK WB 20
    expect(opusPacketSamples(Uint8List.fromList([0x08])), 960); // SILK NB 20
    expect(opusPacketSamples(Uint8List.fromList([0x78])), 960); // hybrid FB 20
    expect(opusPacketSamples(Uint8List.fromList([0xE0])), 120); // CELT 2.5
    expect(opusPacketSamples(Uint8List.fromList([0xF9])), 1920); // two frames
    expect(opusPacketSamples(Uint8List.fromList([0xFB, 0x03])), 2880); // three
  });

  test('a note survives being written and read back', () {
    final packets = [
      for (var i = 0; i < 120; i++) packet(40 + (i * 37) % 400, i),
    ];
    final written = OggOpusStream(
      head: const OpusHead(channels: 1, preSkip: 312),
      packets: packets,
      endGranule: 312 + 119 * 960 + 500,
    ).encode();

    final read = OggOpusStream.decode(written);
    expect(read.head.channels, 1);
    expect(read.head.preSkip, 312);
    expect(read.packets, hasLength(120));
    for (var i = 0; i < packets.length; i++) {
      expect(read.packets[i], packets[i], reason: 'packet $i');
    }
    expect(read.endGranule, 312 + 119 * 960 + 500);
    expect(read.audibleSamples, 119 * 960 + 500);
  });

  test('pages are what a player expects', () {
    final file = OggOpusStream(
      head: const OpusHead(channels: 1, preSkip: 312),
      packets: [for (var i = 0; i < 120; i++) packet(80, i)],
    ).encode();
    final all = pages(file);

    // Head alone on the first page, marked beginning-of-stream; tags alone on
    // the second; audio from the third, the last marked end-of-stream.
    expect(all.length, greaterThanOrEqualTo(4));
    expect(all.first[5], 0x02);
    expect(String.fromCharCodes(all[0].sublist(28, 36)), 'OpusHead');
    expect(String.fromCharCodes(all[1].sublist(28, 36)), 'OpusTags');
    expect(all.last[5] & 0x04, 0x04);

    var sequence = 0;
    for (final page in all) {
      final d = ByteData.sublistView(page);
      expect(d.getUint32(18, Endian.little), sequence++);
      final stored = d.getUint32(22, Endian.little);
      final zeroed = Uint8List.fromList(page)..fillRange(22, 26, 0);
      expect(oggCrc(zeroed), stored, reason: 'page ${sequence - 1} CRC');
    }
    // Granule positions only ever grow.
    var last = -1;
    for (final page in all.skip(2)) {
      final g = ByteData.sublistView(page).getInt64(6, Endian.little);
      expect(g, greaterThan(last));
      last = g;
    }
    expect(last, 120 * 960);
  });

  test('a packet longer than 255 bytes is laced across segments', () {
    final big = packet(700, 7);
    final read = OggOpusStream.decode(OggOpusStream(
      head: const OpusHead(channels: 1, preSkip: 0),
      packets: [big, packet(255, 8), packet(510, 9)],
    ).encode(),);
    expect(read.packets[0], big);
    expect(read.packets[1], hasLength(255));
    expect(read.packets[2], hasLength(510));
  });

  test('a trim keeps the chosen stretch and the pre-roll before it', () {
    // Two seconds of 20 ms packets.
    final stream = OggOpusStream(
      head: const OpusHead(channels: 1, preSkip: 312),
      packets: [for (var i = 0; i < 100; i++) packet(60, i)],
    );
    final cut = stream.trim(
      const Duration(milliseconds: 500),
      const Duration(milliseconds: 1500),
    );
    expect(cut.duration.inMilliseconds, closeTo(1000, 1));
    expect(
      cut.head.preSkip,
      greaterThanOrEqualTo(OggOpus.preRollSamples),
      reason: 'RFC 7845 asks for 80 ms of decoder warm-up ahead of a cut',
    );
    // And it still reads back as the same length.
    expect(
      OggOpusStream.decode(cut.encode()).duration.inMilliseconds,
      closeTo(1000, 1),
    );
  });

  test('a trim from the very start keeps the original pre-skip', () {
    final stream = OggOpusStream(
      head: const OpusHead(channels: 1, preSkip: 312),
      packets: [for (var i = 0; i < 50; i++) packet(60, i)],
    );
    final cut = stream.trim(Duration.zero, const Duration(milliseconds: 400));
    expect(cut.head.preSkip, 312);
    expect(cut.duration.inMilliseconds, closeTo(400, 1));
  });

  test('a garbled file is refused, not half-read', () {
    expect(
      () => OggOpusStream.decode(Uint8List.fromList([1, 2, 3, 4, 5])),
      throwsFormatException,
    );
    final good = OggOpusStream(
      head: const OpusHead(channels: 1, preSkip: 312),
      packets: [packet(60)],
    ).encode();
    expect(
      () => OggOpusStream.decode(Uint8List.sublistView(good, 0, 40)),
      throwsFormatException,
    );
  });

  test('WAV header says 48 kHz mono PCM16', () {
    final wav = wavFromPcm16(Int16List.fromList([1, -1, 300, -300]));
    final d = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(d.getUint16(20, Endian.little), 1);
    expect(d.getUint16(22, Endian.little), 1);
    expect(d.getUint32(24, Endian.little), 48000);
    expect(d.getUint16(34, Endian.little), 16);
    expect(d.getUint32(40, Endian.little), 8);
    expect(d.getInt16(44 + 4, Endian.little), 300);
  });
}
