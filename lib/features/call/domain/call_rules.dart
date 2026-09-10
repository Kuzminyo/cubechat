import 'dart:typed_data';

import '../../../core/transport/call_signal.dart';

export '../../../core/transport/call_signal.dart' show callIdLen;

/// How long each part of a call is allowed to take.
///
/// Three numbers, and the order between them is the point: an invite outlives
/// the ringing it starts, so a call that is still being answered is never
/// thrown away as stale, while yesterday's invite still is.
abstract final class CallTimings {
  /// How long the caller waits for the callee's acknowledgement before saying
  /// the person is unavailable.
  ///
  /// An older build drops an unknown inner type silently, so silence here is
  /// the only signal that the other end cannot take calls at all. Ringing on
  /// against a phone that heard nothing is the failure this replaces.
  static const Duration ringingAck = Duration(seconds: 8);

  /// How long a call rings before it becomes a missed call.
  static const Duration noAnswer = Duration(seconds: 45);

  /// How old an invite may be and still ring a phone.
  static const Duration inviteFreshness = Duration(seconds: 60);

  /// How far ahead of us a sender's clock may be before the timestamp is
  /// nonsense rather than drift.
  static const Duration clockSkew = Duration(seconds: 30);
}

/// Whether an invite stamped [sentAtMs] should ring a phone at [now].
bool inviteIsFresh({required int sentAtMs, required DateTime now}) {
  final age = now.millisecondsSinceEpoch - sentAtMs;
  if (age < 0) return -age <= CallTimings.clockSkew.inMilliseconds;
  return age <= CallTimings.inviteFreshness.inMilliseconds;
}

/// Whether our own call wins when both sides dialled at once.
///
/// Byte-for-byte, lower wins. Both sides run the same comparison over the same
/// two ids and reach the same answer, so no negotiation is needed and there is
/// no round trip in which the two could disagree.
bool winsGlare({required Uint8List mine, required Uint8List theirs}) {
  for (var i = 0; i < callIdLen; i++) {
    if (mine[i] != theirs[i]) return mine[i] < theirs[i];
  }
  // Identical ids cannot happen with sixteen random bytes, and if they did,
  // both sides claiming victory would leave two half-calls. Both lose instead.
  return false;
}
