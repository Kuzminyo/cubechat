import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'ogg_opus.dart';
import 'opus_format.dart';

export 'opus_format.dart';

/// libopus, bound directly — the codec Telegram carries for the same reason.
///
/// The binaries come from `opus_flutter`: built from source by the NDK on
/// Android, an xcframework linked into the app on iOS. Its Dart wrapper,
/// `opus_dart`, was tried first and dropped: it has no `opus_encoder_ctl`, so
/// the bit rate could not be set, and the bit rate is the point. Seven
/// functions is a small enough surface to own.
class OpusLibrary {
  OpusLibrary(DynamicLibrary lib)
      : _encoderCreate = lib.lookupFunction<
            Pointer<Void> Function(Int32, Int32, Int32, Pointer<Int32>),
            Pointer<Void> Function(int, int, int, Pointer<Int32>)>(
          'opus_encoder_create',
        ),
        _encode = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Int16>, Int32, Pointer<Uint8>,
                Int32,),
            int Function(
                Pointer<Void>, Pointer<Int16>, int, Pointer<Uint8>, int,)>(
          'opus_encode',
        ),
        _encoderCtlInt = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Int32, VarArgs<(Int32,)>),
            int Function(Pointer<Void>, int, int)>(
          'opus_encoder_ctl',
        ),
        _encoderCtlOut = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Int32, VarArgs<(Pointer<Int32>,)>),
            int Function(Pointer<Void>, int, Pointer<Int32>)>(
          'opus_encoder_ctl',
        ),
        _encoderDestroy = lib.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('opus_encoder_destroy'),
        _decoderCreate = lib.lookupFunction<
            Pointer<Void> Function(Int32, Int32, Pointer<Int32>),
            Pointer<Void> Function(int, int, Pointer<Int32>)>(
          'opus_decoder_create',
        ),
        _decode = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32, Pointer<Int16>,
                Int32, Int32,),
            int Function(
                Pointer<Void>, Pointer<Uint8>, int, Pointer<Int16>, int, int,)>(
          'opus_decode',
        ),
        _decoderDestroy = lib.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('opus_decoder_destroy');

  /// The library as the app ships it. Opened once and kept: loading it is a
  /// dlopen, and a voice note is recorded or played many times a day.
  static OpusLibrary get instance => _instance ??= OpusLibrary(_open());
  static OpusLibrary? _instance;

  /// For tests, which load the Windows build of the same library by path.
  static set instanceForTest(OpusLibrary? lib) => _instance = lib;

  static DynamicLibrary _open() {
    // A shared object on Android, built from source by opus_flutter's NDK
    // step. On iOS its xcframework is a *dynamic* framework, embedded in the
    // app: opened by name, the way Flutter documents for one, with the
    // process's own symbol table — opus_flutter's loader — behind it.
    if (Platform.isAndroid) return DynamicLibrary.open('libopus.so');
    if (Platform.isIOS) {
      try {
        return DynamicLibrary.open('opus.framework/opus');
      } catch (_) {
        return DynamicLibrary.process();
      }
    }
    throw UnsupportedError('Opus voice notes ship on Android and iOS only');
  }

  final Pointer<Void> Function(int, int, int, Pointer<Int32>) _encoderCreate;
  final int Function(Pointer<Void>, Pointer<Int16>, int, Pointer<Uint8>, int)
      _encode;
  final int Function(Pointer<Void>, int, int) _encoderCtlInt;
  final int Function(Pointer<Void>, int, Pointer<Int32>) _encoderCtlOut;
  final void Function(Pointer<Void>) _encoderDestroy;
  final Pointer<Void> Function(int, int, Pointer<Int32>) _decoderCreate;
  final int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Int16>, int,
      int,) _decode;
  final void Function(Pointer<Void>) _decoderDestroy;
}

/// libopus's constants, from `opus_defines.h`.
abstract final class _Opus {
  static const ok = 0;
  static const applicationVoip = 2048;
  static const setBitrate = 4002;
  static const setVbr = 4006;
  static const setComplexity = 4010;
  static const setSignal = 4024;
  static const getLookahead = 4027;
  static const signalVoice = 3001;
}

class OpusException implements Exception {
  const OpusException(this.what, this.code);
  final String what;
  final int code;
  @override
  String toString() => 'OpusException: $what failed ($code)';
}

/// PCM16 in, 20 ms Opus packets out.
class OpusVoiceEncoder {
  OpusVoiceEncoder([OpusLibrary? library])
      : _lib = library ?? OpusLibrary.instance {
    final error = calloc<Int32>();
    try {
      _state = _lib._encoderCreate(
        OpusVoice.sampleRate,
        OpusVoice.channels,
        _Opus.applicationVoip,
        error,
      );
      if (error.value != _Opus.ok || _state == nullptr) {
        throw OpusException('opus_encoder_create', error.value);
      }
      _ctl(_Opus.setBitrate, OpusVoice.bitRate);
      _ctl(_Opus.setVbr, 1);
      _ctl(_Opus.setComplexity, 10);
      _ctl(_Opus.setSignal, _Opus.signalVoice);
      final out = calloc<Int32>();
      try {
        final r = _lib._encoderCtlOut(_state, _Opus.getLookahead, out);
        lookahead = r == _Opus.ok ? out.value : 312;
      } finally {
        calloc.free(out);
      }
    } finally {
      calloc.free(error);
    }
    _pcm = calloc<Int16>(OpusVoice.frameSamples);
    _packet = calloc<Uint8>(OpusVoice.maxPacketBytes);
  }

  final OpusLibrary _lib;
  late final Pointer<Void> _state;
  late final Pointer<Int16> _pcm;
  late final Pointer<Uint8> _packet;
  bool _disposed = false;

  /// Samples the decoder must drop from the start: this encoder's delay.
  late final int lookahead;

  void _ctl(int request, int value) {
    final r = _lib._encoderCtlInt(_state, request, value);
    if (r != _Opus.ok) throw OpusException('opus_encoder_ctl($request)', r);
  }

  /// One 20 ms frame, [OpusVoice.frameSamples] samples long.
  Uint8List encode(Int16List frame) {
    if (_disposed) throw StateError('encoder disposed');
    if (frame.length != OpusVoice.frameSamples) {
      throw ArgumentError.value(frame.length, 'frame', 'not one 20 ms frame');
    }
    _pcm.asTypedList(OpusVoice.frameSamples).setAll(0, frame);
    final n = _lib._encode(
      _state,
      _pcm,
      OpusVoice.frameSamples,
      _packet,
      OpusVoice.maxPacketBytes,
    );
    if (n < 0) throw OpusException('opus_encode', n);
    return Uint8List.fromList(_packet.asTypedList(n));
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _lib._encoderDestroy(_state);
    calloc.free(_pcm);
    calloc.free(_packet);
  }
}

/// Opus packets in, PCM16 out.
class OpusVoiceDecoder {
  OpusVoiceDecoder({int channels = OpusVoice.channels, OpusLibrary? library})
      : _lib = library ?? OpusLibrary.instance,
        _channels = channels {
    final error = calloc<Int32>();
    try {
      _state = _lib._decoderCreate(OpusVoice.sampleRate, channels, error);
      if (error.value != _Opus.ok || _state == nullptr) {
        throw OpusException('opus_decoder_create', error.value);
      }
    } finally {
      calloc.free(error);
    }
    _pcm = calloc<Int16>(OpusVoice.maxFrameSamples * channels);
    _packet = calloc<Uint8>(OpusVoice.maxPacketBytes);
  }

  final OpusLibrary _lib;
  final int _channels;
  late final Pointer<Void> _state;
  late final Pointer<Int16> _pcm;
  late final Pointer<Uint8> _packet;
  bool _disposed = false;

  Int16List decode(Uint8List packet) {
    if (_disposed) throw StateError('decoder disposed');
    if (packet.length > OpusVoice.maxPacketBytes) {
      throw const FormatException('Opus packet larger than any frame');
    }
    _packet.asTypedList(packet.length).setAll(0, packet);
    final n = _lib._decode(
      _state,
      _packet,
      packet.length,
      _pcm,
      OpusVoice.maxFrameSamples,
      0,
    );
    if (n < 0) throw OpusException('opus_decode', n);
    return Int16List.fromList(_pcm.asTypedList(n * _channels));
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _lib._decoderDestroy(_state);
    calloc.free(_pcm);
    calloc.free(_packet);
  }
}

/// A voice note being recorded: raw microphone bytes in, a finished Ogg Opus
/// file out, and the loudness envelope measured on the way.
///
/// The envelope used to come from the recorder's amplitude callback; reading it
/// off the samples being encoded is the same measurement without a second
/// round trip through the plugin, and it cannot drift from the audio.
class OpusNoteWriter {
  OpusNoteWriter({OpusLibrary? library})
      : _encoder = OpusVoiceEncoder(library);

  final OpusVoiceEncoder _encoder;
  final List<Uint8List> _packets = <Uint8List>[];
  final Int16List _frame = Int16List(OpusVoice.frameSamples);
  int _filled = 0;
  int _samples = 0;

  /// A carried byte when a chunk from the microphone splits a sample in two.
  int? _oddByte;

  /// Loudness windows of [levelWindowSamples], newest last, 0..1.
  final List<double> _levels = <double>[];
  double _windowSquares = 0;
  int _windowCount = 0;

  /// 90 ms — the cadence the waveform was drawn at when it came from the
  /// recorder's amplitude callback, so the bubble's bars keep their width.
  static const int levelWindowSamples = 4320;

  /// Audio recorded so far.
  Duration get duration => Duration(
        microseconds: _samples * 1000000 ~/ OpusVoice.sampleRate,
      );

  List<double> get levels => List<double>.unmodifiable(_levels);

  /// Called with each new loudness value as it is measured.
  void Function(double level)? onLevel;

  /// Little-endian PCM16 mono at 48 kHz, as the recorder streams it.
  void add(Uint8List bytes) {
    var i = 0;
    if (_oddByte != null && bytes.isNotEmpty) {
      _push((bytes[0] << 8 | _oddByte!).toSigned(16));
      _oddByte = null;
      i = 1;
    }
    for (; i + 1 < bytes.length; i += 2) {
      _push((bytes[i + 1] << 8 | bytes[i]).toSigned(16));
    }
    if (i < bytes.length) _oddByte = bytes[i];
  }

  void _push(int sample) {
    _frame[_filled++] = sample;
    _samples++;
    _windowSquares += sample * sample;
    if (++_windowCount == levelWindowSamples) {
      final rms = math.sqrt(_windowSquares / _windowCount) / 32768;
      // The same mapping the amplitude callback had: -45 dBFS and quieter is
      // the floor, 0 dBFS the top, with a sliver kept so silence still draws.
      final db = rms <= 0 ? -120.0 : 20 * math.log(rms) / math.ln10;
      final level = ((db + 45) / 45).clamp(0.06, 1.0).toDouble();
      _levels.add(level);
      onLevel?.call(level);
      _windowSquares = 0;
      _windowCount = 0;
    }
    if (_filled == OpusVoice.frameSamples) {
      _packets.add(_encoder.encode(_frame));
      _filled = 0;
    }
  }

  /// Pad the last frame out with silence, flush the encoder, and hand back the
  /// file.
  ///
  /// The flush is not optional. The encoder runs [OpusVoiceEncoder.lookahead]
  /// samples behind its input, so the final few milliseconds of a note are
  /// still inside it when the microphone stops; without more frames pushed
  /// through, the decoded note came out exactly that much short — 47688
  /// samples for a 48000-sample second, measured against the real library.
  /// Telegram's encoder pads the same way.
  OggOpusStream finish() {
    final audible = _samples;
    final preSkip = _encoder.lookahead;
    var encoded = _packets.length * OpusVoice.frameSamples;
    if (_filled > 0) {
      _frame.fillRange(_filled, OpusVoice.frameSamples, 0);
      _packets.add(_encoder.encode(_frame));
      encoded += OpusVoice.frameSamples;
      _filled = 0;
    }
    _frame.fillRange(0, OpusVoice.frameSamples, 0);
    while (encoded < preSkip + audible) {
      _packets.add(_encoder.encode(_frame));
      encoded += OpusVoice.frameSamples;
    }
    _encoder.dispose();
    final stream = OggOpusStream(
      head: OpusHead(channels: OpusVoice.channels, preSkip: preSkip),
      packets: List<Uint8List>.of(_packets),
    );
    // The padding at the end is silence nobody recorded: the last granule
    // says where the audio really stopped.
    final end = preSkip + audible;
    return OggOpusStream(
      head: stream.head,
      packets: stream.packets,
      endGranule: end < stream.totalSamples ? end : null,
    );
  }

  /// Give the encoder back without producing anything — a cancelled note.
  void discard() => _encoder.dispose();
}

/// An Ogg Opus note as a WAV file both platforms' players open.
///
/// Decoded in slices with a turn of the event loop between them: a minute is
/// three thousand packets, and done in one go on the UI isolate that is a
/// frame or two nobody would miss on a fast phone and a visible hitch on a
/// slow one.
Future<Uint8List> decodeOggOpusToWav(
  Uint8List ogg, {
  OpusLibrary? library,
}) async {
  final stream = OggOpusStream.decode(ogg);
  final decoder =
      OpusVoiceDecoder(channels: stream.head.channels, library: library);
  try {
    final total = stream.totalSamples * stream.head.channels;
    final pcm = Int16List(total);
    var at = 0;
    for (var i = 0; i < stream.packets.length; i++) {
      final out = decoder.decode(stream.packets[i]);
      final room = math.min(out.length, pcm.length - at);
      pcm.setRange(at, at + room, out);
      at += room;
      if (i % 200 == 199) await Future<void>.delayed(Duration.zero);
    }
    final ch = stream.head.channels;
    final start = math.min(stream.head.preSkip * ch, at);
    final end = math.min((stream.head.preSkip + stream.audibleSamples) * ch, at);
    return wavFromPcm16(
      Int16List.sublistView(pcm, start, math.max(start, end)),
      channels: ch,
    );
  } finally {
    decoder.dispose();
  }
}
