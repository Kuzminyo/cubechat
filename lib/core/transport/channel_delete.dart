import 'dart:convert';
import 'dart:typed_data';

/// The owner closing a room, for everybody in it.
///
/// **What this can and cannot do.** There is no server and the room's key is
/// derived from its name, so nothing stops anyone who remembers the name from
/// typing it again and being back in an empty room. This is not a lock. What
/// it is: a signed instruction that every member's app honours by forgetting
/// the room — its key, its messages, its roster, its picture and its topic —
/// so the room leaves every phone it was on. That is what people mean when
/// they delete a group, and it is achievable here; "nobody can ever rejoin" is
/// not, and is not claimed.
///
/// **Why it carries the name.** The frame is signed over this body, so the
/// name is covered by the signature — which means a delete taken from one room
/// and replayed into another cannot wipe that one. For an irreversible
/// instruction that is worth the two bytes. Every receiver checks the name
/// against the room the frame actually arrived in and drops the mismatch.
///
/// Wire layout:
///
/// ```
///   [ver     : 1 byte = 0x01]
///   [nameLen : 1 byte]
///   [name    : nameLen bytes, UTF-8, the room this is about]
/// ```
///
/// An older build has no case for this payload type, drops it, and keeps the
/// room. That is the right failure and it is worth stating plainly: the room
/// goes from every phone that understands the message and stays on the ones
/// that do not, which their owner will see as the group still being there.
class ChannelDelete {
  const ChannelDelete({required this.channelName});

  final String channelName;

  static const int version = 0x01;

  /// One length byte, so this is the format ceiling. A room name is far
  /// shorter; a peer padding one out only spends their own airtime.
  static const int maxNameBytes = 255;

  Uint8List encode() {
    final name = utf8.encode(channelName);
    if (name.isEmpty) {
      throw const FormatException('channel delete needs a room name');
    }
    if (name.length > maxNameBytes) {
      throw const FormatException('channel name too long to encode');
    }
    final out = Uint8List(2 + name.length)
      ..[0] = version
      ..[1] = name.length;
    out.setRange(2, 2 + name.length, name);
    return out;
  }

  // Explicit throws rather than asserts: this runs over bytes an attacker
  // chose, and asserts are stripped from a release build.
  static ChannelDelete decode(Uint8List bytes) {
    if (bytes.length < 3) {
      throw const FormatException('channel delete too short');
    }
    if (bytes[0] != version) {
      throw FormatException(
        'unknown channel delete version 0x${bytes[0].toRadixString(16)}',
      );
    }
    final len = bytes[1];
    if (len == 0) {
      throw const FormatException('channel delete names no room');
    }
    // Exact, not "at least": trailing bytes are refused everywhere in this
    // protocol, and that check is what stops a relay padding a frame.
    if (bytes.length != 2 + len) {
      throw const FormatException('channel delete length mismatch');
    }
    final String name;
    try {
      name = utf8.decode(bytes.sublist(2, 2 + len));
    } on FormatException {
      throw const FormatException('channel delete name is not UTF-8');
    }
    if (name.trim().isEmpty) {
      throw const FormatException('channel delete names no room');
    }
    return ChannelDelete(channelName: name);
  }
}
