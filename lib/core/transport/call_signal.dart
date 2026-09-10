import 'dart:convert';
import 'dart:typed_data';

/// Width of the identifier every frame of one call carries.
///
/// Sixteen random bytes, the same width as the transport `msgId`, so a log
/// line showing one is read the same way as a log line showing the other.
const int callIdLen = 16;

/// Version byte at the head of a [CallSignal] body.
const int callSignalVersion = 0x01;

/// Which step of a call one frame is.
enum CallSignalKind {
  invite(0x01),
  ringing(0x02),
  accept(0x03),
  decline(0x04),
  busy(0x05),
  hangup(0x06);

  const CallSignalKind(this.tag);
  final int tag;

  static CallSignalKind? fromByte(int b) {
    for (final v in CallSignalKind.values) {
      if (v.tag == b) return v;
    }
    return null;
  }
}

/// Why a call stopped, in one byte.
enum CallEndReason {
  hungUp(0x00),
  noAnswer(0x01),
  declined(0x02),
  busy(0x03),
  failed(0x04);

  const CallEndReason(this.tag);
  final int tag;

  /// Unknown reasons fall back rather than throw: a newer build inventing a
  /// reason should still be able to hang up on an older one. Losing the label
  /// costs a wrong word in the history; refusing the frame would leave the
  /// call ringing forever.
  static CallEndReason fromByte(int b) {
    for (final v in CallEndReason.values) {
      if (v.tag == b) return v;
    }
    return CallEndReason.hungUp;
  }
}

/// One frame of call signalling, carried inside the same envelope as text.
///
/// ```
///   [version:1][kind:1][callId:16][len:2][body:len]
/// ```
///
/// `len` is big-endian, matching the padded-text body next door. Bodies:
/// invite `[sentAtMs:8][sdp]`, accept `[sdp]`, decline and hangup
/// `[reason:1]`, ringing and busy empty.
///
/// **There is no payload type for ICE candidates and that is deliberate.**
/// Media is relayed through our own TURN by default, so exactly one candidate
/// exists and it is already inside the SDP. Trickling candidates one at a time
/// over a store-and-forward relay would be the expensive way to send
/// information that fits in the frame already being sent.
class CallSignal {
  const CallSignal._({
    required this.kind,
    required this.callId,
    this.sdp,
    this.sentAtMs,
    this.reason,
  });

  factory CallSignal.invite({
    required Uint8List callId,
    required String sdp,
    required int sentAtMs,
  }) {
    if (sdp.isEmpty) {
      throw const FormatException('an invite must carry an sdp');
    }
    return CallSignal._(
      kind: CallSignalKind.invite,
      callId: callId,
      sdp: sdp,
      sentAtMs: sentAtMs,
    );
  }

  factory CallSignal.ringing(Uint8List callId) =>
      CallSignal._(kind: CallSignalKind.ringing, callId: callId);

  factory CallSignal.accept({
    required Uint8List callId,
    required String sdp,
  }) {
    if (sdp.isEmpty) {
      throw const FormatException('an accept must carry an sdp');
    }
    return CallSignal._(
      kind: CallSignalKind.accept,
      callId: callId,
      sdp: sdp,
    );
  }

  factory CallSignal.decline({
    required Uint8List callId,
    required CallEndReason reason,
  }) =>
      CallSignal._(
        kind: CallSignalKind.decline,
        callId: callId,
        reason: reason,
      );

  factory CallSignal.busy(Uint8List callId) =>
      CallSignal._(kind: CallSignalKind.busy, callId: callId);

  factory CallSignal.hangup({
    required Uint8List callId,
    required CallEndReason reason,
  }) =>
      CallSignal._(
        kind: CallSignalKind.hangup,
        callId: callId,
        reason: reason,
      );

  final CallSignalKind kind;
  final Uint8List callId;
  final String? sdp;
  final int? sentAtMs;
  final CallEndReason? reason;

  static const int _headerLen = 4 + callIdLen;

  Uint8List encode() {
    if (callId.length != callIdLen) {
      throw const FormatException('call id must be 16 bytes');
    }
    final body = _body();
    if (body.length > 0xffff) {
      throw const FormatException('call signal body too long');
    }
    final out = Uint8List(_headerLen + body.length);
    out[0] = callSignalVersion;
    out[1] = kind.tag;
    out.setRange(2, 2 + callIdLen, callId);
    out[2 + callIdLen] = (body.length >> 8) & 0xff;
    out[3 + callIdLen] = body.length & 0xff;
    out.setRange(_headerLen, out.length, body);
    return out;
  }

  Uint8List _body() {
    switch (kind) {
      case CallSignalKind.invite:
        final sdpBytes = utf8.encode(sdp!);
        final out = Uint8List(8 + sdpBytes.length);
        // Split arithmetically, not with `>> 32`. Milliseconds since the epoch
        // need 41 bits; on the web build an int is a double and a shift is
        // 32-bit, so a shift silently loses the top of the number there.
        final view = ByteData.sublistView(out);
        view.setUint32(0, sentAtMs! ~/ 0x100000000);
        view.setUint32(4, sentAtMs! % 0x100000000);
        out.setRange(8, out.length, sdpBytes);
        return out;
      case CallSignalKind.accept:
        return Uint8List.fromList(utf8.encode(sdp!));
      case CallSignalKind.decline:
      case CallSignalKind.hangup:
        return Uint8List.fromList([reason!.tag]);
      case CallSignalKind.ringing:
      case CallSignalKind.busy:
        return Uint8List(0);
    }
  }

  static CallSignal decode(Uint8List bytes) {
    if (bytes.length < _headerLen) {
      throw const FormatException('call signal truncated');
    }
    if (bytes[0] != callSignalVersion) {
      throw FormatException('unknown call signal version ${bytes[0]}');
    }
    final kind = CallSignalKind.fromByte(bytes[1]);
    if (kind == null) {
      throw FormatException(
          'unknown call signal kind 0x${bytes[1].toRadixString(16)}');
    }
    final callId = Uint8List.fromList(bytes.sublist(2, 2 + callIdLen));
    final len = (bytes[2 + callIdLen] << 8) | bytes[3 + callIdLen];
    if (bytes.length < _headerLen + len) {
      throw const FormatException('call signal body truncated');
    }
    final body = Uint8List.sublistView(bytes, _headerLen, _headerLen + len);
    switch (kind) {
      case CallSignalKind.invite:
        if (body.length <= 8) {
          throw const FormatException('an invite must carry an sdp');
        }
        final view = ByteData.sublistView(body);
        final at = view.getUint32(0) * 0x100000000 + view.getUint32(4);
        return CallSignal.invite(
          callId: callId,
          sdp: utf8.decode(body.sublist(8)),
          sentAtMs: at,
        );
      case CallSignalKind.accept:
        if (body.isEmpty) {
          throw const FormatException('an accept must carry an sdp');
        }
        return CallSignal.accept(callId: callId, sdp: utf8.decode(body));
      case CallSignalKind.decline:
        if (body.isEmpty) {
          throw const FormatException('a decline must carry a reason');
        }
        return CallSignal.decline(
          callId: callId,
          reason: CallEndReason.fromByte(body[0]),
        );
      case CallSignalKind.hangup:
        if (body.isEmpty) {
          throw const FormatException('a hangup must carry a reason');
        }
        return CallSignal.hangup(
          callId: callId,
          reason: CallEndReason.fromByte(body[0]),
        );
      case CallSignalKind.ringing:
        return CallSignal.ringing(callId);
      case CallSignalKind.busy:
        return CallSignal.busy(callId);
    }
  }
}
