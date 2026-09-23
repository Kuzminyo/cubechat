import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Width of a transfer id and of each file's media id — the width of every
/// other id on the wire, so a log line reads the same.
const int nearbyIdLen = 16;

/// Version byte at the head of both bodies.
const int nearbyVersion = 0x01;

/// Offer flag: "I can send these over the local network" (part 2).
const int nearbyFlagWifi = 0x01;

/// Answer version that carries a [NearbyWifiEndpoint]. Only ever sent in
/// reply to an offer with [nearbyFlagWifi], which a part-1 build never sets —
/// so no phone that cannot read it is ever sent one.
const int nearbyAnswerVersionWifi = 0x02;

/// Most files one offer may carry.
const int nearbyMaxFiles = 50;

/// A name or a mime is prefixed by one length byte.
const int nearbyMaxFieldBytes = 255;

/// Largest size a Dart int holds exactly on every platform the app builds for
/// (web included), so a size read here means the same number everywhere.
const int _maxSize = 0x1FFFFFFFFFFFFF;

/// Longest textual IP address: a full IPv6 with an embedded IPv4.
const int _maxAddressBytes = 45;

String nearbyHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List nearbyUnhex(String hex) {
  if (hex.length.isOdd) throw FormatException('odd hex length: $hex');
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) throw FormatException('not hex: $hex');
    out[i] = byte;
  }
  return out;
}

/// Where the receiver is listening, and the key the stream is sealed with.
class NearbyWifiEndpoint {
  NearbyWifiEndpoint({
    required this.address,
    required this.port,
    required this.key,
  }) {
    if (address.length > _maxAddressBytes ||
        InternetAddress.tryParse(address) == null) {
      throw ArgumentError.value(address, 'address');
    }
    if (port < 1 || port > 0xFFFF) throw ArgumentError.value(port, 'port');
    if (key.length != keyLen) throw ArgumentError.value(key.length, 'key');
  }

  static const int keyLen = 32;

  final String address;
  final int port;
  final Uint8List key;
}

/// One file named in an offer. The sender picks [mediaId] before sending the
/// offer, and the file later travels under exactly that id.
class NearbyOfferFile {
  NearbyOfferFile({
    required this.mediaId,
    required this.size,
    required this.name,
    required this.mime,
  }) {
    if (mediaId.length != nearbyIdLen) {
      throw ArgumentError.value(mediaId.length, 'mediaId', 'not $nearbyIdLen');
    }
    if (size < 0 || size > _maxSize) throw ArgumentError.value(size, 'size');
  }

  final Uint8List mediaId;
  final int size;
  final String name;
  final String mime;
}

/// "I would like to send you these."
///
/// ```
///   [version:1][transferId:16][flags:1][count:1]
///   count × [mediaId:16][size:8 BE][nameLen:1][name:utf8][mimeLen:1][mime:ascii]
/// ```
///
/// [flags] bit 0 ([nearbyFlagWifi]) says the sender can take the files over the local network; an older build leaves it 0 and never reads it.
/// Every length is checked on the way in: a decoder that trusts its
/// input is a crash anybody in Bluetooth range can cause.
class NearbyOffer {
  NearbyOffer({required this.transferId, required this.files, this.flags = 0}) {
    if (transferId.length != nearbyIdLen) {
      throw ArgumentError.value(transferId.length, 'transferId');
    }
  }

  final Uint8List transferId;
  final int flags;
  final List<NearbyOfferFile> files;

  int get totalBytes => files.fold(0, (sum, f) => sum + f.size);

  Uint8List encode() {
    if (files.isEmpty || files.length > nearbyMaxFiles) {
      throw ArgumentError.value(files.length, 'files', '1..$nearbyMaxFiles');
    }
    final out = BytesBuilder(copy: false)
      ..addByte(nearbyVersion)
      ..add(transferId)
      ..addByte(flags & 0xFF)
      ..addByte(files.length);
    for (final f in files) {
      final name = _fitUtf8(f.name, nearbyMaxFieldBytes);
      final mime = ascii.encode(f.mime);
      if (mime.length > nearbyMaxFieldBytes) {
        throw ArgumentError.value(f.mime, 'mime', 'longer than 255 bytes');
      }
      out
        ..add(f.mediaId)
        ..add(_u64(f.size))
        ..addByte(name.length)
        ..add(name)
        ..addByte(mime.length)
        ..add(mime);
    }
    return out.toBytes();
  }

  static NearbyOffer decode(Uint8List body) {
    final r = _Reader(body);
    if (r.byte() != nearbyVersion) {
      throw const FormatException('nearby offer: unknown version');
    }
    final transferId = r.bytes(nearbyIdLen);
    final flags = r.byte();
    final count = r.byte();
    if (count < 1 || count > nearbyMaxFiles) {
      throw FormatException('nearby offer: $count files');
    }
    final files = <NearbyOfferFile>[];
    final ids = <String>{};
    for (var i = 0; i < count; i++) {
      final mediaId = r.bytes(nearbyIdLen);
      final size = r.u64();
      final name = utf8.decode(r.bytes(r.byte()));
      final mime = ascii.decode(r.bytes(r.byte()));
      if (!ids.add(nearbyHex(mediaId))) {
        throw const FormatException('nearby offer: a media id twice');
      }
      files.add(
        NearbyOfferFile(mediaId: mediaId, size: size, name: name, mime: mime),
      );
    }
    if (!r.done) throw const FormatException('nearby offer: trailing bytes');
    return NearbyOffer(transferId: transferId, flags: flags, files: files);
  }
}

enum NearbyAnswerKind {
  seen(0x01),
  accepted(0x02),
  declined(0x03),
  cancelled(0x04);

  const NearbyAnswerKind(this.tag);
  final int tag;

  static NearbyAnswerKind? fromByte(int b) {
    for (final v in values) {
      if (v.tag == b) return v;
    }
    return null;
  }
}

enum NearbyDeclineReason {
  user(0x00),
  noSpace(0x01),
  contactsOnly(0x02),
  busy(0x03),
  timeout(0x04);

  const NearbyDeclineReason(this.tag);
  final int tag;

  /// Unknown reasons read as the person saying no — see [NearbyAnswer].
  static NearbyDeclineReason fromByte(int b) {
    for (final v in values) {
      if (v.tag == b) return v;
    }
    return user;
  }
}

/// Version 1: `[version:1][transferId:16][kind:1][reason:1]` — nineteen bytes.
///
/// Version 2, an acceptance with a Wi-Fi endpoint:
/// `… [addrLen:1][addr:ascii][port:2 BE][key:32]`.
class NearbyAnswer {
  NearbyAnswer({
    required this.transferId,
    required this.kind,
    this.reason = NearbyDeclineReason.user,
    this.wifi,
  }) {
    if (transferId.length != nearbyIdLen) {
      throw ArgumentError.value(transferId.length, 'transferId');
    }
    if (wifi != null && kind != NearbyAnswerKind.accepted) {
      throw ArgumentError.value(kind, 'kind', 'only an acceptance has wifi');
    }
  }

  static const int length = 1 + nearbyIdLen + 2;

  final Uint8List transferId;
  final NearbyAnswerKind kind;
  final NearbyDeclineReason reason;
  final NearbyWifiEndpoint? wifi;

  Uint8List encode() {
    final w = wifi;
    final out = BytesBuilder(copy: false)
      ..addByte(w == null ? nearbyVersion : nearbyAnswerVersionWifi)
      ..add(transferId)
      ..addByte(kind.tag)
      ..addByte(reason.tag);
    if (w != null) {
      final addr = ascii.encode(w.address);
      out
        ..addByte(addr.length)
        ..add(addr)
        ..addByte(w.port >> 8)
        ..addByte(w.port & 0xFF)
        ..add(w.key);
    }
    return out.toBytes();
  }

  static NearbyAnswer decode(Uint8List body) {
    if (body.isEmpty) throw const FormatException('nearby answer: empty');
    final version = body[0];
    if (version == nearbyVersion) {
      if (body.length != length) {
        throw FormatException('nearby answer: ${body.length} bytes');
      }
    } else if (version != nearbyAnswerVersionWifi) {
      throw const FormatException('nearby answer: unknown version');
    }
    final r = _Reader(body)..byte();
    final transferId = r.bytes(nearbyIdLen);
    final kind = NearbyAnswerKind.fromByte(r.byte());
    if (kind == null) throw const FormatException('nearby answer: kind');
    final reason = NearbyDeclineReason.fromByte(r.byte());
    NearbyWifiEndpoint? wifi;
    if (version == nearbyAnswerVersionWifi) {
      if (kind != NearbyAnswerKind.accepted) {
        throw const FormatException('nearby answer: wifi on a non-acceptance');
      }
      final addrLen = r.byte();
      if (addrLen == 0 || addrLen > _maxAddressBytes) {
        throw FormatException('nearby answer: address of $addrLen bytes');
      }
      final address = ascii.decode(r.bytes(addrLen), allowInvalid: false);
      final port = (r.byte() << 8) | r.byte();
      final key = r.bytes(NearbyWifiEndpoint.keyLen);
      if (!r.done) throw const FormatException('nearby answer: trailing bytes');
      try {
        wifi = NearbyWifiEndpoint(address: address, port: port, key: key);
      } on ArgumentError catch (e) {
        throw FormatException('nearby answer: $e');
      }
    }
    return NearbyAnswer(
      transferId: transferId,
      kind: kind,
      reason: reason,
      wifi: wifi,
    );
  }
}

/// "I felt your phone against mine" — the bump gesture, sent over the direct
/// link only.
///
/// ```
///   [version:1][bumpId:16][flags:1][cardLen:2 BE][card:cardLen]
/// ```
///
/// [flags] bit 0 says the sender has files queued to send once the bump is
/// matched, so the receiving side can offer to jump straight into AirDrop.
/// [card] is opaque to the wire — whatever the bump feature puts in it (a
/// name, an avatar digest, ...) is its business; this class only bounds it
/// and moves it. An old build drops the whole frame, so the gesture simply
/// does not fire against it.
class NearbyBump {
  NearbyBump({
    required this.bumpId,
    required this.hasFiles,
    required this.card,
  }) {
    if (bumpId.length != nearbyIdLen) {
      throw ArgumentError.value(bumpId.length, 'bumpId', 'not $nearbyIdLen');
    }
    // Symmetric with decode, which refuses a cardLen of 0 as malformed — an
    // encoder that built one would produce bytes its own decoder rejects.
    if (card.isEmpty) {
      throw ArgumentError.value(card.length, 'card', 'must not be empty');
    }
    if (card.length > maxCard) {
      throw ArgumentError.value(card.length, 'card', 'longer than $maxCard');
    }
  }

  /// A bump card is metadata, not a file transfer — this bounds it well short
  /// of anything that needs chunking.
  static const int maxCard = 2048;

  final Uint8List bumpId;
  final bool hasFiles;
  final Uint8List card;

  Uint8List encode() {
    final out = BytesBuilder(copy: false)
      ..addByte(nearbyVersion)
      ..add(bumpId)
      ..addByte(hasFiles ? 0x01 : 0x00)
      ..addByte(card.length >> 8)
      ..addByte(card.length & 0xFF)
      ..add(card);
    return out.toBytes();
  }

  static NearbyBump decode(Uint8List body) {
    final r = _Reader(body);
    if (r.byte() != nearbyVersion) {
      throw const FormatException('nearby bump: unknown version');
    }
    final bumpId = r.bytes(nearbyIdLen);
    final flags = r.byte();
    final cardLen = (r.byte() << 8) | r.byte();
    if (cardLen == 0 || cardLen > maxCard) {
      throw FormatException('nearby bump: card of $cardLen bytes');
    }
    final card = r.bytes(cardLen);
    if (!r.done) throw const FormatException('nearby bump: trailing bytes');
    return NearbyBump(bumpId: bumpId, hasFiles: flags & 0x01 != 0, card: card);
  }
}

/// One AirDrop frame as the transport hands it on: who sent it, whether it
/// came straight from their phone, and what it said.
class NearbyInbound {
  const NearbyInbound({
    required this.peerHex,
    required this.direct,
    this.offer,
    this.answer,
    this.bump,
  });

  final String peerHex;
  final bool direct;
  final NearbyOffer? offer;
  final NearbyAnswer? answer;
  final NearbyBump? bump;
}

/// What the transport should do with a file manifest — asked of AirDrop,
/// because only AirDrop knows which media ids it offered or accepted.
enum NearbyFileVerdict {
  /// Not an AirDrop id: an ordinary file for the chat.
  notNearby,

  /// Part of an accepted offer from this sender over a direct link.
  keep,

  /// An AirDrop id without an accepted offer, from somebody else, or not over
  /// a direct link. Dropped and logged.
  refuse,
}

abstract interface class NearbyFileSink {
  NearbyFileVerdict judge({
    required String mediaIdHex,
    required String senderHex,
    required bool direct,
  });

  /// A kept file has arrived whole and its hash matched. Move it to where
  /// AirDrop keeps files and say where; null when the transfer has ended and
  /// the file is no longer wanted.
  Future<String?> keep({
    required String mediaIdHex,
    required String senderHex,
    required File file,
    required String name,
  });
}

Uint8List _fitUtf8(String s, int max) {
  final whole = utf8.encode(s);
  if (whole.length <= max) return Uint8List.fromList(whole);
  final out = BytesBuilder(copy: false);
  for (final rune in s.runes) {
    final bytes = utf8.encode(String.fromCharCode(rune));
    if (out.length + bytes.length > max) break;
    out.add(bytes);
  }
  return out.toBytes();
}

Uint8List _u64(int v) {
  final b = ByteData(8)
    ..setUint32(0, v ~/ 0x100000000)
    ..setUint32(4, v % 0x100000000);
  return b.buffer.asUint8List();
}

class _Reader {
  _Reader(this._b);

  final Uint8List _b;
  int _at = 0;

  bool get done => _at == _b.length;

  void _need(int n) {
    if (_at + n > _b.length) throw const FormatException('nearby: truncated');
  }

  int byte() {
    _need(1);
    return _b[_at++];
  }

  Uint8List bytes(int n) {
    _need(n);
    final out = Uint8List.fromList(_b.sublist(_at, _at + n));
    _at += n;
    return out;
  }

  int u64() {
    _need(8);
    final d = ByteData.sublistView(_b, _at, _at + 8);
    _at += 8;
    final hi = d.getUint32(0);
    if (hi > 0x1FFFFF) throw const FormatException('nearby: size too large');
    return hi * 0x100000000 + d.getUint32(4);
  }
}
