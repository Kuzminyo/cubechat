import 'dart:typed_data';

/// Cubechat wire protocol.
///
/// Every BLE write or notification carries exactly one [Frame]:
///
/// ```
///   [type: 1 byte] [payload: 0..N bytes]
/// ```
///
/// All higher-level meaning lives in the type byte. Handshake frames carry
/// raw Noise XX messages; transport frames carry Noise-encrypted application
/// payload. The application payload itself is currently just UTF-8 text;
/// when we add images/files (M5) we'll prepend an inner type byte after
/// decryption.
enum FrameType {
  /// Initiator → Responder: first Noise XX message (raw `e`).
  noiseHandshake1(0x01),

  /// Responder → Initiator: second Noise XX message (`e, ee, s, es`).
  noiseHandshake2(0x02),

  /// Initiator → Responder: third Noise XX message (`s, se`) — completes the
  /// handshake; may carry the first encrypted application payload.
  noiseHandshake3(0x03),

  /// Either direction after handshake: encrypted application payload.
  transport(0x10),

  /// Unencrypted broadcast announcement carrying (pubkey, nickname). Wrapped
  /// in a [TransportEnvelope] so the same dedup + relay machinery applies as
  /// for transport frames. See [PeerAnnouncement].
  peerAnnouncement(0x20),

  /// Either direction: explicit "session aborted / reset, drop your state".
  /// Useful when one side restarts and the other still has a stale session.
  reset(0xFE);

  const FrameType(this.value);
  final int value;

  static FrameType? fromByte(int b) {
    for (final t in FrameType.values) {
      if (t.value == b) return t;
    }
    return null;
  }
}

/// Encoded form of a single message on the wire.
class Frame {
  Frame({required this.type, required this.payload});

  final FrameType type;
  final Uint8List payload;

  /// Pack `[type | payload]` into a single byte buffer ready for BLE write.
  Uint8List encode() {
    final out = Uint8List(1 + payload.length);
    out[0] = type.value;
    out.setRange(1, out.length, payload);
    return out;
  }

  static Frame decode(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const FrameDecodeException('empty frame');
    }
    final type = FrameType.fromByte(bytes[0]);
    if (type == null) {
      throw FrameDecodeException('unknown frame type 0x${bytes[0].toRadixString(16)}');
    }
    return Frame(type: type, payload: Uint8List.fromList(bytes.sublist(1)));
  }

  @override
  String toString() => 'Frame($type, ${payload.length}B)';
}

class FrameDecodeException implements Exception {
  const FrameDecodeException(this.message);
  final String message;
  @override
  String toString() => 'FrameDecodeException: $message';
}
