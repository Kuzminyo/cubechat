import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../../core/transport/call_signal.dart';
import 'call_rules.dart';

/// Where a call is, from the point of view of the person holding the phone.
enum CallPhase { idle, dialing, ringing, incoming, connecting, talking, ended }

/// How a call finished, in the words the history will use.
enum CallEndCause {
  hungUp,
  declined,
  busy,
  noAnswer,
  unavailable,
  failed,
  glareLost,
}

/// What a finished call leaves behind.
@immutable
class CallOutcome {
  const CallOutcome({
    required this.callId,
    required this.outgoing,
    required this.cause,
    required this.talkedFor,
  });

  final Uint8List callId;
  final bool outgoing;
  final CallEndCause cause;

  /// Time actually spent talking, which is zero for everything that never
  /// connected. The ringing is not part of it.
  final Duration talkedFor;
}

/// The whole life of one call, with no media, no platform and no transport in
/// it.
///
/// Everything this needs from the outside arrives through the constructor:
/// [send] puts one frame on the wire, [onOutcome] is called exactly once when
/// the call is over, and [now] is the clock. Keeping the three injected is
/// what lets `fake_async` drive a forty-five second ring in a millisecond,
/// and it is the only reason the hard parts of a call are testable at all on
/// a machine with no phone attached.
class CallStateMachine extends ChangeNotifier {
  CallStateMachine({
    required this.send,
    required this.onOutcome,
    required this.now,
  });

  final Future<void> Function(CallSignal signal) send;
  final void Function(CallOutcome outcome) onOutcome;
  final DateTime Function() now;

  CallPhase _phase = CallPhase.idle;
  Uint8List? _callId;
  bool _outgoing = false;
  DateTime? _talkingSince;
  Timer? _deadline;

  CallPhase get phase => _phase;
  Uint8List? get callId => _callId;

  /// Whether [signal] belongs to the call this machine is running.
  bool _isOurs(CallSignal signal) {
    final mine = _callId;
    if (mine == null) return false;
    for (var i = 0; i < callIdLen; i++) {
      if (mine[i] != signal.callId[i]) return false;
    }
    return true;
  }

  void startOutgoing({required Uint8List callId, required String sdp}) {
    if (_phase != CallPhase.idle) return;
    _callId = callId;
    _outgoing = true;
    _move(CallPhase.dialing);
    unawaited(send(CallSignal.invite(
      callId: callId,
      sdp: sdp,
      sentAtMs: now().millisecondsSinceEpoch,
    )));
    // The acknowledgement, not the invite, is what turns a dial into a ring.
    _arm(CallTimings.ringingAck, () => _end(CallEndCause.unavailable));
  }

  void handleSignal(CallSignal signal) {
    if (!_isOurs(signal)) return;
    switch (signal.kind) {
      case CallSignalKind.ringing:
        if (_phase != CallPhase.dialing) return;
        _move(CallPhase.ringing);
        _arm(CallTimings.noAnswer, () {
          _sendHangup(CallEndReason.noAnswer);
          _end(CallEndCause.noAnswer);
        });
      case CallSignalKind.accept:
        if (_phase != CallPhase.ringing) return;
        _disarm();
        _move(CallPhase.connecting);
      case CallSignalKind.decline:
        // The other end has already stopped. Telling it to stop is noise.
        _end(CallEndCause.declined);
      case CallSignalKind.busy:
        _end(CallEndCause.busy);
      case CallSignalKind.hangup:
        _end(CallEndCause.hungUp);
      case CallSignalKind.invite:
        // Incoming calls arrive in the next task; an invite for a call we are
        // already running is a repeat delivery and changes nothing.
        return;
    }
  }

  void accept({required String sdp}) {
    if (_phase != CallPhase.incoming) return;
    _disarm();
    unawaited(send(CallSignal.accept(callId: _callId!, sdp: sdp)));
    _move(CallPhase.connecting);
  }

  void decline() {
    if (_phase != CallPhase.incoming) return;
    unawaited(send(CallSignal.decline(
      callId: _callId!,
      reason: CallEndReason.declined,
    )));
    _end(CallEndCause.declined);
  }

  void hangUp() {
    if (_phase == CallPhase.idle || _phase == CallPhase.ended) return;
    _sendHangup(CallEndReason.hungUp);
    _end(CallEndCause.hungUp);
  }

  void mediaConnected() {
    if (_phase != CallPhase.connecting) return;
    _talkingSince = now();
    _move(CallPhase.talking);
  }

  void mediaFailed() {
    if (_phase == CallPhase.idle || _phase == CallPhase.ended) return;
    _sendHangup(CallEndReason.failed);
    _end(CallEndCause.failed);
  }

  void _sendHangup(CallEndReason reason) {
    final id = _callId;
    if (id == null) return;
    unawaited(send(CallSignal.hangup(callId: id, reason: reason)));
  }

  void _move(CallPhase next) {
    _phase = next;
    notifyListeners();
  }

  void _arm(Duration after, void Function() fire) {
    _disarm();
    _deadline = Timer(after, fire);
  }

  void _disarm() {
    _deadline?.cancel();
    _deadline = null;
  }

  /// Exactly one outcome per call, whatever arrives afterwards.
  ///
  /// Late frames are normal rather than exceptional: a hangup crossing our own
  /// hangup in flight is one round trip, and a media failure reported after
  /// the user already hung up is one frame. Both used to be able to write a
  /// second line into the history for the same call.
  void _end(CallEndCause cause) {
    if (_phase == CallPhase.ended || _phase == CallPhase.idle) return;
    _disarm();
    final since = _talkingSince;
    final outcome = CallOutcome(
      callId: _callId!,
      outgoing: _outgoing,
      cause: cause,
      talkedFor: since == null ? Duration.zero : now().difference(since),
    );
    _move(CallPhase.ended);
    onOutcome(outcome);
  }

  @override
  void dispose() {
    _disarm();
    super.dispose();
  }
}
