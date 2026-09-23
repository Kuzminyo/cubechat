import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// What one record on the Wi-Fi stream says. The first plaintext byte.
enum WifiRecordKind {
  /// Sender → receiver, first record: the transfer id, proving the key.
  hello(0x01),

  /// `[mediaId:16][size:8 BE]`.
  fileStart(0x02),

  /// Up to [WifiLaneCodec.dataBytes] of the current file.
  data(0x03),

  /// The current file is complete.
  fileEnd(0x04),

  /// Receiver → sender: `[mediaId:16]` was kept where AirDrop keeps files.
  fileKept(0x05),

  /// Receiver → sender: `[mediaId:16]` was not wanted (size wrong, transfer
  /// over). The sender stops.
  fileRefused(0x06);

  const WifiRecordKind(this.tag);
  final int tag;

  static WifiRecordKind? fromByte(int b) {
    for (final v in values) {
      if (v.tag == b) return v;
    }
    return null;
  }
}

class WifiRecord {
  const WifiRecord(this.kind, this.body);
  final WifiRecordKind kind;
  final Uint8List body;
}

/// First nonce byte. One key serves both directions of one transfer; this
/// byte keeps their counters from ever producing the same nonce.
enum WifiDirection {
  toReceiver(0x00),
  toSender(0x01);

  const WifiDirection(this.tag);
  final int tag;
}

abstract final class WifiLaneCodec {
  /// 64 KiB of file per record: a 1 MiB read is sixteen records sealed in one
  /// isolate hop, and the 17-byte overhead is 0.03%.
  static const int dataBytes = 64 * 1024;

  /// Largest sealed record the reader will buffer: kind byte, data, tag, and
  /// slack for the largest control body. Anything longer is an attack or a
  /// bug, and the connection is dropped.
  static const int maxSealed = 1 + dataBytes + 16 + 64;

  static Uint8List frame(Uint8List sealed) {
    final out = Uint8List(4 + sealed.length);
    ByteData.sublistView(out).setUint32(0, sealed.length);
    out.setRange(4, out.length, sealed);
    return out;
  }
}

/// ChaCha20-Poly1305 over one direction of the stream. The nonce is
/// `[direction:1][0:3][counter:8 BE]`: counting records means a replayed,
/// dropped or reordered record fails to open rather than being taken.
///
/// Batches at or over [_offloadBytes] are sealed in [Isolate.run] — the same
/// reasoning and threshold as `MediaFsCipher.offloadBytes`, measured in 1106:
/// crypto on the UI isolate was the heat and the lag of sending a video.
class WifiLaneCipher {
  WifiLaneCipher(Uint8List key, this._direction)
      : _key = Uint8List.fromList(key);

  final Uint8List _key;
  final WifiDirection _direction;
  int _counter = 0;

  static const int _offloadBytes = 16 * 1024;

  Future<List<Uint8List>> seal(List<WifiRecord> records) async {
    final plains = [
      for (final r in records)
        (Uint8List(1 + r.body.length)
          ..[0] = r.kind.tag
          ..setRange(1, 1 + r.body.length, r.body)),
    ];
    final start = _counter;
    _counter += plains.length;
    final size = plains.fold<int>(0, (s, p) => s + p.length);
    final key = _key;
    final dir = _direction.tag;
    return size >= _offloadBytes
        ? Isolate.run(() => _sealAll(key, dir, start, plains))
        : _sealAll(key, dir, start, plains);
  }

  Future<List<WifiRecord>> open(List<Uint8List> sealed) async {
    final start = _counter;
    _counter += sealed.length;
    final size = sealed.fold<int>(0, (s, p) => s + p.length);
    final key = _key;
    final dir = _direction.tag;
    final plains = size >= _offloadBytes
        ? await Isolate.run(() => _openAll(key, dir, start, sealed))
        : await _openAll(key, dir, start, sealed);
    return [
      for (final p in plains)
        WifiRecord(
          WifiRecordKind.fromByte(p[0]) ??
              (throw FormatException('wifi lane: record kind ${p[0]}')),
          Uint8List.sublistView(p, 1),
        ),
    ];
  }

  static List<int> _nonce(int dir, int counter) {
    final n = Uint8List(12)..[0] = dir;
    ByteData.sublistView(n).setUint64(4, counter);
    return n;
  }

  static Future<List<Uint8List>> _sealAll(
    Uint8List key,
    int dir,
    int start,
    List<Uint8List> plains,
  ) async {
    final aead = Chacha20.poly1305Aead();
    final secret = SecretKey(key);
    final out = <Uint8List>[];
    for (var i = 0; i < plains.length; i++) {
      final box = await aead.encrypt(
        plains[i],
        secretKey: secret,
        nonce: _nonce(dir, start + i),
      );
      out.add(
        Uint8List.fromList([...box.cipherText, ...box.mac.bytes]),
      );
    }
    return out;
  }

  static Future<List<Uint8List>> _openAll(
    Uint8List key,
    int dir,
    int start,
    List<Uint8List> sealed,
  ) async {
    final aead = Chacha20.poly1305Aead();
    final secret = SecretKey(key);
    final out = <Uint8List>[];
    for (var i = 0; i < sealed.length; i++) {
      final s = sealed[i];
      if (s.length < 17) throw const FormatException('wifi lane: short record');
      try {
        final plain = await aead.decrypt(
          SecretBox(
            s.sublist(0, s.length - 16),
            nonce: _nonce(dir, start + i),
            mac: Mac(s.sublist(s.length - 16)),
          ),
          secretKey: secret,
        );
        out.add(Uint8List.fromList(plain));
      } on SecretBoxAuthenticationError {
        throw const FormatException('wifi lane: record failed to open');
      }
    }
    return out;
  }
}

/// Cuts a TCP byte stream into sealed records.
class WifiRecordFramer {
  final BytesBuilder _buf = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);

  void add(Uint8List bytes) => _buf.add(bytes);

  List<Uint8List> take() {
    if (_buf.isNotEmpty) {
      _pending = Uint8List.fromList([..._pending, ..._buf.takeBytes()]);
    }
    final out = <Uint8List>[];
    var at = 0;
    while (_pending.length - at >= 4) {
      final len = ByteData.sublistView(_pending, at, at + 4).getUint32(0);
      if (len > WifiLaneCodec.maxSealed || len < 17) {
        throw FormatException('wifi lane: record of $len bytes');
      }
      if (_pending.length - at - 4 < len) break;
      out.add(Uint8List.fromList(_pending.sublist(at + 4, at + 4 + len)));
      at += 4 + len;
    }
    _pending = Uint8List.fromList(_pending.sublist(at));
    return out;
  }
}
