import 'dart:typed_data';

/// Opus in Ogg (RFC 7845), written and read in Dart.
///
/// Voice notes are Opus because that is what makes Telegram's sound the way
/// they do at the rate they do: Telegram's own `audio.c` encodes 48 kHz mono
/// with `OPUS_APPLICATION_VOIP` in 20 ms frames and writes Ogg. Neither
/// platform will do that for us on every phone this app runs on — Android's
/// MediaCodec encodes Opus only from Android 10, iOS writes it into CAF, which
/// Android cannot open, and iOS will not play Ogg — so the codec is carried
/// here (libopus, see `opus_voice.dart`) and the container is this file.
///
/// Ogg is small enough to own. A page is a 27-byte header, a lacing table and
/// the packet bytes; the only subtle parts are the CRC, which is not the zip
/// one, and the granule position, which counts 48 kHz samples *including* the
/// encoder's pre-skip.
class OggOpus {
  const OggOpus._();

  /// Every Opus stream is timed in 48 kHz samples, whatever it was recorded at.
  static const int granuleRate = 48000;

  /// RFC 7845 §4.6: at least 80 ms of audio ahead of a cut, so a decoder that
  /// starts mid-stream has converged by the time anybody hears it.
  static const int preRollSamples = 3840;
}

/// The identification header, `OpusHead`.
class OpusHead {
  const OpusHead({
    required this.channels,
    required this.preSkip,
    this.inputSampleRate = OggOpus.granuleRate,
    this.outputGainQ8 = 0,
  });

  final int channels;

  /// Samples at 48 kHz the decoder must drop from the start: the encoder's
  /// look-ahead, plus any pre-roll a trim kept.
  final int preSkip;

  /// Informational only — what the microphone ran at.
  final int inputSampleRate;

  /// Q7.8 dB applied on decode. Zero here: loudness is left to the recording.
  final int outputGainQ8;

  Uint8List encode() {
    final b = BytesBuilder();
    b.add('OpusHead'.codeUnits);
    b.addByte(1); // version
    b.addByte(channels);
    b.add(_le16(preSkip));
    b.add(_le32(inputSampleRate));
    b.add(_le16(outputGainQ8 & 0xFFFF));
    b.addByte(0); // channel mapping family 0: mono or stereo, no table
    return b.toBytes();
  }

  static OpusHead decode(Uint8List p) {
    if (p.length < 19 || String.fromCharCodes(p.sublist(0, 8)) != 'OpusHead') {
      throw const FormatException('not an OpusHead packet');
    }
    final d = ByteData.sublistView(p);
    final channels = p[9];
    if (channels < 1 || channels > 2) {
      throw FormatException('unsupported channel count $channels');
    }
    return OpusHead(
      channels: channels,
      preSkip: d.getUint16(10, Endian.little),
      inputSampleRate: d.getUint32(12, Endian.little),
      outputGainQ8: d.getInt16(16, Endian.little),
    );
  }
}

/// How many 48 kHz samples one Opus packet decodes to, read from its TOC byte
/// (RFC 6716 §3.1) — so a stream's length is known without decoding it.
int opusPacketSamples(Uint8List packet) {
  if (packet.isEmpty) throw const FormatException('empty Opus packet');
  final toc = packet[0];
  final config = toc >> 3;
  // Frame length in tenths of a millisecond, by configuration.
  final int tenthsMs;
  if (config < 12) {
    // SILK-only: 10, 20, 40, 60 ms for each of NB, MB, WB.
    tenthsMs = const [100, 200, 400, 600][config % 4];
  } else if (config < 16) {
    // Hybrid: 10, 20 ms for SWB and FB.
    tenthsMs = const [100, 200][config % 2];
  } else {
    // CELT-only: 2.5, 5, 10, 20 ms for NB, WB, SWB, FB.
    tenthsMs = const [25, 50, 100, 200][config % 4];
  }
  final int frames;
  switch (toc & 0x03) {
    case 0:
      frames = 1;
    case 1:
    case 2:
      frames = 2;
    default:
      if (packet.length < 2) {
        throw const FormatException('code-3 packet without a frame count');
      }
      frames = packet[1] & 0x3F;
  }
  return frames * tenthsMs * OggOpus.granuleRate ~/ 10000;
}

/// A whole Ogg Opus file in memory: the header and every audio packet.
///
/// Voice notes are small — a minute at 32 kbps is 240 KB — so holding one
/// entire is simpler than streaming pages, and it is what makes a trim a
/// matter of picking packets.
class OggOpusStream {
  OggOpusStream({
    required this.head,
    required this.packets,
    this.endGranule,
    this.vendor = 'cubechat',
  });

  final OpusHead head;
  final List<Uint8List> packets;

  /// Granule position of the last page, when it cuts the final packet short.
  /// Null means every sample of every packet is audio.
  final int? endGranule;

  final String vendor;

  /// 48 kHz samples the packets decode to, before pre-skip is dropped.
  int get totalSamples =>
      packets.fold<int>(0, (sum, p) => sum + opusPacketSamples(p));

  /// Audible samples: after pre-skip, and up to the end granule.
  int get audibleSamples {
    final end = endGranule ?? totalSamples;
    final audible = end - head.preSkip;
    return audible < 0 ? 0 : audible;
  }

  Duration get duration => Duration(
        microseconds: audibleSamples * 1000000 ~/ OggOpus.granuleRate,
      );

  /// Keep [start, end) of the audio, cut at packet boundaries, with the
  /// pre-roll RFC 7845 asks for so the first kept sound is not the decoder
  /// warming up.
  OggOpusStream trim(Duration start, Duration end) {
    int toSamples(Duration d) =>
        d.inMicroseconds * OggOpus.granuleRate ~/ 1000000;
    // Positions in the packet timeline, which includes pre-skip.
    final from = head.preSkip + toSamples(start);
    final to = head.preSkip + toSamples(end);

    // The packet that contains `from`, and how far into it `from` is.
    var cursor = 0;
    var first = 0;
    while (first < packets.length &&
        cursor + opusPacketSamples(packets[first]) <= from) {
      cursor += opusPacketSamples(packets[first]);
      first++;
    }
    if (first >= packets.length) {
      return OggOpusStream(head: head, packets: const [], vendor: vendor);
    }
    final intoFirst = from - cursor;

    // Walk back far enough for the pre-roll.
    var rollStart = first;
    var roll = 0;
    while (rollStart > 0 && roll < OggOpus.preRollSamples) {
      rollStart--;
      roll += opusPacketSamples(packets[rollStart]);
    }

    final kept = <Uint8List>[];
    var keptSamples = 0;
    final keepUntil = to - cursor + roll;
    for (var i = rollStart; i < packets.length; i++) {
      if (keptSamples >= keepUntil) break;
      kept.add(packets[i]);
      keptSamples += opusPacketSamples(packets[i]);
    }
    final preSkip = roll + intoFirst;
    final audible = to - from;
    return OggOpusStream(
      head: OpusHead(
        channels: head.channels,
        preSkip: preSkip,
        inputSampleRate: head.inputSampleRate,
        outputGainQ8: head.outputGainQ8,
      ),
      packets: kept,
      endGranule:
          preSkip + audible < keptSamples ? preSkip + audible : null,
      vendor: vendor,
    );
  }

  /// The file: OpusHead on the first page, OpusTags on the second, audio on
  /// the rest, the last page marked end-of-stream.
  Uint8List encode({int serial = 0x63756265}) {
    final out = BytesBuilder(copy: false);
    var seq = 0;
    out.add(_page(
      packets: [head.encode()],
      granule: 0,
      serial: serial,
      sequence: seq++,
      flags: _bos,
    ),);
    out.add(_page(
      packets: [_tags(vendor)],
      granule: 0,
      serial: serial,
      sequence: seq++,
    ),);

    // A page per second or so — fifty 20 ms packets — and never more than the
    // 255 lacing values a page can carry.
    var granule = 0;
    final pending = <Uint8List>[];
    var laces = 0;
    void flush({required bool last}) {
      var g = granule;
      if (last && endGranule != null && endGranule! < g) g = endGranule!;
      out.add(_page(
        packets: pending,
        granule: g,
        serial: serial,
        sequence: seq++,
        flags: last ? _eos : 0,
      ),);
      pending.clear();
      laces = 0;
    }

    for (var i = 0; i < packets.length; i++) {
      final p = packets[i];
      final need = p.length ~/ 255 + 1;
      if (pending.isNotEmpty && (laces + need > 255 || pending.length >= 50)) {
        flush(last: false);
      }
      pending.add(p);
      laces += need;
      granule += opusPacketSamples(p);
    }
    if (pending.isNotEmpty || packets.isEmpty) flush(last: true);
    return out.toBytes();
  }

  /// Read a file this or any conforming encoder wrote.
  static OggOpusStream decode(Uint8List bytes) {
    final packets = <Uint8List>[];
    final partial = BytesBuilder(copy: false);
    var offset = 0;
    int? lastGranule;
    while (offset + 27 <= bytes.length) {
      if (bytes[offset] != 0x4F ||
          bytes[offset + 1] != 0x67 ||
          bytes[offset + 2] != 0x67 ||
          bytes[offset + 3] != 0x53) {
        throw FormatException('no Ogg page at byte $offset');
      }
      final d = ByteData.sublistView(bytes, offset);
      final granule = d.getInt64(6, Endian.little);
      final segments = bytes[offset + 26];
      final tableEnd = offset + 27 + segments;
      if (tableEnd > bytes.length) {
        throw const FormatException('truncated Ogg segment table');
      }
      var body = tableEnd;
      for (var s = 0; s < segments; s++) {
        final lace = bytes[offset + 27 + s];
        if (body + lace > bytes.length) {
          throw const FormatException('truncated Ogg page');
        }
        partial.add(Uint8List.sublistView(bytes, body, body + lace));
        body += lace;
        if (lace < 255) packets.add(partial.takeBytes());
      }
      if (granule >= 0) lastGranule = granule;
      offset = body;
    }
    if (packets.length < 2) {
      throw const FormatException('no Opus headers');
    }
    final head = OpusHead.decode(packets[0]);
    if (String.fromCharCodes(packets[1].take(8)) != 'OpusTags') {
      throw const FormatException('no OpusTags packet');
    }
    final audio = packets.sublist(2);
    final stream = OggOpusStream(head: head, packets: audio);
    final total = stream.totalSamples;
    return OggOpusStream(
      head: head,
      packets: audio,
      endGranule:
          lastGranule != null && lastGranule < total ? lastGranule : null,
    );
  }

  static const int _bos = 0x02;
  static const int _eos = 0x04;

  static Uint8List _tags(String vendor) {
    final b = BytesBuilder();
    b.add('OpusTags'.codeUnits);
    b.add(_le32(vendor.length));
    b.add(vendor.codeUnits);
    b.add(_le32(0)); // no user comments
    return b.toBytes();
  }

  static Uint8List _page({
    required List<Uint8List> packets,
    required int granule,
    required int serial,
    required int sequence,
    int flags = 0,
  }) {
    final lacing = <int>[];
    for (final p in packets) {
      var left = p.length;
      while (left >= 255) {
        lacing.add(255);
        left -= 255;
      }
      lacing.add(left);
    }
    final bodyLength = packets.fold<int>(0, (n, p) => n + p.length);
    final page = Uint8List(27 + lacing.length + bodyLength);
    final d = ByteData.sublistView(page);
    page.setAll(0, const [0x4F, 0x67, 0x67, 0x53]);
    page[4] = 0;
    page[5] = flags;
    d.setInt64(6, granule, Endian.little);
    d.setUint32(14, serial, Endian.little);
    d.setUint32(18, sequence, Endian.little);
    // 22..25: CRC, zero while it is computed.
    page[26] = lacing.length;
    page.setAll(27, lacing);
    var at = 27 + lacing.length;
    for (final p in packets) {
      page.setAll(at, p);
      at += p.length;
    }
    d.setUint32(22, oggCrc(page), Endian.little);
    return page;
  }
}

/// Ogg's CRC-32: polynomial 0x04C11DB7, not reflected, initial value 0 —
/// which is not the zip CRC, and a page with the zip one is silently skipped
/// by every player there is.
int oggCrc(Uint8List data) {
  var crc = 0;
  for (final byte in data) {
    crc = ((crc << 8) & 0xFFFFFFFF) ^ _crcTable[((crc >> 24) ^ byte) & 0xFF];
  }
  return crc;
}

final List<int> _crcTable = List<int>.generate(256, (i) {
  var r = i << 24;
  for (var k = 0; k < 8; k++) {
    r = (r & 0x80000000) != 0
        ? ((r << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
        : (r << 1) & 0xFFFFFFFF;
  }
  return r;
}, growable: false,);

/// PCM16 mono or stereo wrapped as a WAV file — what every player on both
/// platforms opens, which is why a decoded note is handed over as one.
Uint8List wavFromPcm16(
  Int16List samples, {
  int sampleRate = OggOpus.granuleRate,
  int channels = 1,
}) {
  final dataBytes = samples.length * 2;
  final out = Uint8List(44 + dataBytes);
  final d = ByteData.sublistView(out);
  out.setAll(0, 'RIFF'.codeUnits);
  d.setUint32(4, 36 + dataBytes, Endian.little);
  out.setAll(8, 'WAVE'.codeUnits);
  out.setAll(12, 'fmt '.codeUnits);
  d.setUint32(16, 16, Endian.little);
  d.setUint16(20, 1, Endian.little); // PCM
  d.setUint16(22, channels, Endian.little);
  d.setUint32(24, sampleRate, Endian.little);
  d.setUint32(28, sampleRate * channels * 2, Endian.little);
  d.setUint16(32, channels * 2, Endian.little);
  d.setUint16(34, 16, Endian.little);
  out.setAll(36, 'data'.codeUnits);
  d.setUint32(40, dataBytes, Endian.little);
  out.buffer
      .asUint8List(44, dataBytes)
      .setAll(0, samples.buffer.asUint8List(
        samples.offsetInBytes,
        dataBytes,
      ),);
  return out;
}

Uint8List _le16(int v) =>
    Uint8List(2)..buffer.asByteData().setUint16(0, v & 0xFFFF, Endian.little);

Uint8List _le32(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
