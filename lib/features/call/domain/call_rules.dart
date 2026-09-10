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

/// Whether this frame should wake a sleeping phone at all.
///
/// A ringing acknowledgement and an accept travel to somebody who is by
/// definition awake — they are in a call screen. A hangup and a decline do
/// not: the phone at the other end may be ringing in a pocket, and a phone
/// that missed the hangup goes on ringing after the caller gave up.
bool callWakesPeer(CallSignalKind kind) => switch (kind) {
      CallSignalKind.invite ||
      CallSignalKind.hangup ||
      CallSignalKind.decline =>
        true,
      CallSignalKind.ringing ||
      CallSignalKind.accept ||
      CallSignalKind.busy =>
        false,
    };

/// Whether this frame should be delivered as a VoIP push rather than an
/// ordinary silent wake.
///
/// **Only the invite, and this is not a detail.** iOS terminates an app that
/// accepts a VoIP push without immediately reporting a new incoming call. A
/// hangup has no call to report, so a VoIP push carrying one would kill the
/// app; and it needs none, because the app is awake by then — it reported the
/// incoming call moments earlier and still holds its relay subscription.
bool callIsVoipWake(CallSignalKind kind) => kind == CallSignalKind.invite;
