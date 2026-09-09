import 'package:flutter/foundation.dart';

/// What a peer is doing in a conversation right now.
///
/// **One byte on the wire, not a new payload type.** This rides in the body of
/// [InnerPayloadType.typing], which was already a single byte: `0x01` for
/// typing and anything else for "stopped". Adding values there rather than a
/// payload of their own is the pattern this tree already uses for a fact this
/// small, and it decides what an older build does with one for free — its
/// decoder reads `!= 0x01` and takes the indicator *down*, so a phone that
/// predates this shows nothing rather than showing the wrong thing.
///
/// Nothing is persisted. A notice about this second is worth nothing after a
/// restart, and keeping a record of who was talking to whom and when is
/// precisely the metadata this app exists not to hold.
enum PeerActivity {
  typing(0x01),
  recordingVoice(0x02),
  recordingCircle(0x03);

  const PeerActivity(this.wireByte);

  /// The value carried in the typing payload's single byte.
  final int wireByte;

  /// The activity a byte names, or null for a stop and for anything a later
  /// build might send that this one does not know.
  ///
  /// Unknown reads as a stop on purpose. The alternative — treating anything
  /// non-zero as "typing" — would put the wrong words under somebody's name,
  /// and a blank line is a better wrong answer than a confident one.
  static PeerActivity? fromWire(int byte) {
    for (final activity in values) {
      if (activity.wireByte == byte) return activity;
    }
    return null;
  }
}

/// One activity notice and when its sender said it.
///
/// The timestamp is the sender's claim, clamped to now before it is believed —
/// a notice held in a relay backlog comes out of it looking new, which is how
/// "typing…" once appeared under a conversation nobody had touched in seven
/// minutes.
@immutable
class PeerActivityNotice {
  const PeerActivityNotice({required this.kind, required this.at});

  final PeerActivity kind;
  final DateTime at;

  @override
  bool operator ==(Object other) =>
      other is PeerActivityNotice && other.kind == kind && other.at == at;

  @override
  int get hashCode => Object.hash(kind, at);
}
