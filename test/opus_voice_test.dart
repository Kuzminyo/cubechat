import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cubechat/core/audio/ogg_opus.dart';
import 'package:cubechat/core/audio/opus_voice.dart';
import 'package:flutter_test/flutter_test.dart';

/// The real codec, not a stand-in: opus_flutter ships the same libopus for
/// Windows, so the encoder and decoder that go to the phones are exercised
/// here. Skipped where that build is not on disk.
void main() {
  OpusLibrary? lib;

  setUpAll(() {
    final local = Platform.environment['LOCALAPPDATA'];
    if (!Platform.isWindows || local == null) return;
    final pub = Directory('$local/Pub/Cache/hosted/pub.dev');
    if (!pub.existsSync()) return;
    final plugin = pub
        .listSync()
        .whereType<Directory>()
        .where((d) => d.path.contains('opus_flutter_windows-'))
        .toList();
    if (plugin.isEmpty) return;
    final blob = File('${plugin.last.path}/assets/libopus_x64.dll.blob');
    if (!blob.existsSync()) return;
    final dll = File('${Directory.systemTemp.path}/cubechat_libopus_x64.dll');
    if (!dll.existsSync() || dll.lengthSync() != blob.lengthSync()) {
      blob.copySync(dll.path);
    }
    lib = OpusLibrary(DynamicLibrary.open(dll.path));
  });

  Uint8List pcmBytes(Int16List samples) =>
      samples.buffer.asUint8List(samples.offsetInBytes, samples.length * 2);

  Int16List sine(double seconds, {double dbfs = -12, double hz = 440}) {
    final n = (seconds * 48000).round();
    final amp = 32767 * math.pow(10, dbfs / 20);
    return Int16List.fromList([
      for (var i = 0; i < n; i++)
        (amp * math.sin(2 * math.pi * hz * i / 48000)).round(),
    ]);
  }

  double rmsDb(Int16List s) {
    var sum = 0.0;
    for (final v in s) {
      sum += v * v;
    }
    final rms = math.sqrt(sum / s.length) / 32768;
    return 20 * math.log(rms) / math.ln10;
  }

  Int16List wavSamples(Uint8List wav) =>
      Int16List.sublistView(Uint8List.fromList(wav.sublist(44)));

  test('a second of voice goes in and a second comes out', () async {
    if (lib == null) return markTestSkipped('libopus for Windows not found');
    final writer = OpusNoteWriter(library: lib);
    final input = sine(1.0);
    // Fed in the odd-sized pieces a microphone stream arrives in, including
    // ones that split a sample in two.
    final bytes = pcmBytes(input);
    for (var at = 0; at < bytes.length; at += 1023) {
      writer.add(Uint8List.sublistView(
          bytes, at, math.min(at + 1023, bytes.length),),);
    }
    expect(writer.duration.inMilliseconds, 1000);

    final file = writer.finish().encode();
    final wav = await decodeOggOpusToWav(file, library: lib);
    final out = wavSamples(wav);

    expect(out.length, 48000, reason: 'pre-skip dropped, padding cut off');
    // Loudness comes through: the codec is not where the level goes.
    expect(rmsDb(out), closeTo(rmsDb(input), 1.5));
  });

  test('32 kbps: half the size of the AAC it replaced', () async {
    if (lib == null) return markTestSkipped('libopus for Windows not found');
    final writer = OpusNoteWriter(library: lib);
    // Something busier than a sine, so the variable rate has work to do.
    final rng = math.Random(1);
    final tone = sine(1, hz: 220);
    final speechy = Int16List.fromList([
      for (var i = 0; i < 5 * 48000; i++)
        ((tone[i % 48000] * 0.6) + (rng.nextDouble() - 0.5) * 4000)
            .round()
            .clamp(-32768, 32767),
    ]);
    writer.add(pcmBytes(speechy));
    final stream = writer.finish();
    final bytesPerSecond =
        stream.packets.fold<int>(0, (n, p) => n + p.length) / 5;
    expect(bytesPerSecond, lessThan(OpusVoice.bitRate / 8 * 1.25));
    expect(bytesPerSecond, lessThan(64000 / 8 / 1.5),
        reason: 'the point of the switch is less airtime, not more',);
  });

  test('a quiet voice is still there after the codec', () async {
    // "Иногда микрофон вообще не улавливает тихий звук." Whatever the phone's
    // microphone does, the codec must not be what drops a quiet voice: -40
    // dBFS goes in and comes out at -40 dBFS, not gated to silence.
    if (lib == null) return markTestSkipped('libopus for Windows not found');
    final writer = OpusNoteWriter(library: lib);
    final quiet = sine(1.0, dbfs: -40, hz: 300);
    writer.add(pcmBytes(quiet));
    final out = wavSamples(
      await decodeOggOpusToWav(writer.finish().encode(), library: lib),
    );
    expect(rmsDb(out), closeTo(-43, 3.5)); // a sine's RMS sits 3 dB under peak
  });

  test('the waveform is measured off the samples, every 90 ms', () {
    if (lib == null) return markTestSkipped('libopus for Windows not found');
    final writer = OpusNoteWriter(library: lib);
    final heard = <double>[];
    writer.onLevel = heard.add;
    writer.add(pcmBytes(sine(1.0, dbfs: -6)));
    writer.add(pcmBytes(Int16List(48000))); // then a second of silence
    expect(heard, hasLength(22)); // 96000 / 4320
    expect(heard.first, greaterThan(0.7));
    expect(heard.last, 0.06, reason: 'silence sits on the floor');
    writer.discard();
  });

  test('a trimmed note decodes to the length it was cut to', () async {
    if (lib == null) return markTestSkipped('libopus for Windows not found');
    final writer = OpusNoteWriter(library: lib);
    writer.add(pcmBytes(sine(3.0)));
    final cut = writer.finish().trim(
          const Duration(milliseconds: 700),
          const Duration(milliseconds: 2200),
        );
    final out = wavSamples(
      await decodeOggOpusToWav(cut.encode(), library: lib),
    );
    expect(out.length / 48, closeTo(1500, 1));
  });

  test('the encoder reports its own delay as the pre-skip', () {
    if (lib == null) return markTestSkipped('libopus for Windows not found');
    final encoder = OpusVoiceEncoder(lib);
    expect(encoder.lookahead, inInclusiveRange(120, 960));
    encoder.dispose();
    expect(OggOpus.granuleRate, OpusVoice.sampleRate);
  });
}
