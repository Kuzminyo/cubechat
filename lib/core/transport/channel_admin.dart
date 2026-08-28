import 'dart:typed_data';

/// Administrator role change inside a signed channel frame.
class ChannelAdminChange {
  const ChannelAdminChange({required this.memberId, required this.isAdmin});

  final String memberId;
  final bool isAdmin;

  Uint8List encode() {
    if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(memberId)) {
      throw const FormatException('invalid channel member fingerprint');
    }
    final out = Uint8List(9)..[0] = isAdmin ? 1 : 0;
    for (var index = 0; index < 8; index++) {
      out[index + 1] = int.parse(
        memberId.substring(index * 2, index * 2 + 2),
        radix: 16,
      );
    }
    return out;
  }

  static ChannelAdminChange decode(Uint8List bytes) {
    if (bytes.length != 9 || bytes[0] > 1) {
      throw const FormatException('invalid channel administrator change');
    }
    final id = bytes
        .sublist(1)
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return ChannelAdminChange(memberId: id, isAdmin: bytes[0] == 1);
  }
}


/// What an administrator did to a member.
enum ChannelModerationAction {
  /// Out of the room. Their posts stop being accepted and their roster row
  /// goes; nothing stops them deriving the key again from the name, which is
  /// why this is a removal rather than a ban.
  remove(0x00),

  /// Silenced until a moment. Their posts are dropped on arrival until then,
  /// and they stay in the room and keep reading.
  mute(0x01),

  /// Undo either of the above.
  clear(0x02);

  const ChannelModerationAction(this.tag);
  final int tag;

  static ChannelModerationAction? fromByte(int b) {
    for (final v in ChannelModerationAction.values) {
      if (v.tag == b) return v;
    }
    return null;
  }
}

/// An administrator removing or silencing somebody, inside a signed channel
/// frame.
///
/// Wire layout (14 bytes, fixed):
///
/// ```
///   [action  : 1 byte]
///   [member  : 8 bytes — the first 16 hex characters of their Ed25519 key,
///                        which is all a signed channel frame reveals]
///   [untilS  : 5 bytes big-endian — unix seconds, 0 for "no end"]
/// ```
///
/// Seconds, not millis, and five bytes rather than eight. Millis need 41 bits
/// before this decade is out — five bytes of them ran out in 2004, which is
/// how the first draft of this managed to reject every deadline it was given.
/// Seconds fit with room for thirty thousand years, and a mute is a thing you
/// set for an evening.
///
/// Authorised by the frame's own Ed25519 signature, exactly like
/// [ChannelAdminChange]: the receiver checks the signer against its own roster
/// and drops the whole thing if that signer is not an administrator. Nothing
/// here is enforceable at the sender — the key is shared and anybody holding it
/// can encrypt — so what makes the rule real is every other member declining to
/// accept what a removed member writes.
class ChannelModeration {
  const ChannelModeration({
    required this.memberId,
    required this.action,
    this.until,
  });

  final String memberId;
  final ChannelModerationAction action;

  /// When a mute runs out. Null for a removal, and for a mute with no end.
  final DateTime? until;

  static const int _len = 14;
  static const int _untilLen = 5;

  /// Beyond this a deadline cannot be encoded, and a caller asking for one is
  /// asking for something the field cannot hold.
  static const int maxUntilSeconds = 0xFFFFFFFFFF;

  Uint8List encode() {
    if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(memberId)) {
      throw const FormatException('invalid channel member fingerprint');
    }
    final seconds =
        until == null ? 0 : until!.millisecondsSinceEpoch ~/ 1000;
    if (seconds < 0 || seconds > maxUntilSeconds) {
      throw const FormatException('moderation deadline out of range');
    }
    final out = Uint8List(_len)..[0] = action.tag;
    for (var index = 0; index < 8; index++) {
      out[index + 1] = int.parse(
        memberId.substring(index * 2, index * 2 + 2),
        radix: 16,
      );
    }
    for (var index = 0; index < _untilLen; index++) {
      out[9 + index] = (seconds >> (8 * (_untilLen - 1 - index))) & 0xFF;
    }
    return out;
  }

  static ChannelModeration decode(Uint8List bytes) {
    if (bytes.length != _len) {
      throw const FormatException('invalid channel moderation length');
    }
    final action = ChannelModerationAction.fromByte(bytes[0]);
    if (action == null) {
      throw FormatException('unknown moderation action 0x'
          '${bytes[0].toRadixString(16)}');
    }
    final id = bytes
        .sublist(1, 9)
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    var seconds = 0;
    for (var index = 0; index < _untilLen; index++) {
      seconds = (seconds << 8) | bytes[9 + index];
    }
    return ChannelModeration(
      memberId: id,
      action: action,
      until: seconds == 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
    );
  }
}
