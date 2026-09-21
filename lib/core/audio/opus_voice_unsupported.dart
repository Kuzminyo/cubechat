import 'dart:typed_data';

import 'ogg_opus.dart';
export 'opus_format.dart';

/// Where there is no `dart:ffi` — the web build used for interface work —
/// there is no libopus either. Every way in says so, and every caller already
/// has a way round it: the recorder falls back to AAC, and a note that cannot
/// be decoded is handed to the player as it is.
class OpusNoteWriter {
  OpusNoteWriter() {
    throw UnsupportedError('Opus needs dart:ffi');
  }

  Duration get duration => Duration.zero;
  List<double> get levels => const <double>[];
  void Function(double level)? onLevel;
  void add(Uint8List bytes) {}
  OggOpusStream finish() => throw UnsupportedError('Opus needs dart:ffi');
  void discard() {}
}

Future<Uint8List> decodeOggOpusToWav(Uint8List ogg) async =>
    throw UnsupportedError('Opus needs dart:ffi');
