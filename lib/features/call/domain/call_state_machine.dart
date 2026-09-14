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

/// What ended a call — separate from [CallEndCause], which says how it ended.
///
/// callId 22fc7aa8 ended as `hungUp` about ten seconds after the caller heard it
/// ringing, and nothing in either log could say whether a finger did that. A
/// hangup from the button, one from the other phone and one from a closing app
/// all came out as the same word. They are told apart here, and every outcome
/// line in the log names one.
enum CallEndSource {
  /// The person pressed end or decline.
  button,

  /// The app was closing with the call still on.
  lifecycle,

  /// The controller was torn down with the call still on.
  dispose,

  /// A call deadline ran out: no acknowledgement, no answer, no media in time.
  timer,

  /// A signal that had to leave this phone could not leave at all.
  transport,

  /// WebRTC failed, or stayed disconnected past its grace.
  media,

  /// The other phone said so: hangup, decline, busy, or an invite that won.
  remote,
}

/// What a finished call leaves behind.
@immutable
class CallOutcome {
  const CallOutcome({
    required this.callId,
    required this.outgoing,
    required this.cause,
    required this.talkedFor,
    required this.source,
    this.remoteReason,
  });

  final Uint8List callId;
  final bool outgoing;
  final CallEndCause cause;

  /// Time actually spent talking, which is zero for everything that never
  /// connected. The ringing is not part of it.
  final Duration talkedFor;

  final CallEndSource source;

  /// The reason byte the other phone put in its hangup or decline, when that
  /// is what ended the call.
  final CallEndReason? remoteReason;
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

  /// Ids of calls that are over, and when each was filed. See
  /// [CallTimings.endedMemory].
  final Map<String, DateTime> _ended = {};

  /// Bounded so a stream of hangups for made-up ids cannot grow it; far more
  /// than the calls one phone ends inside [CallTimings.endedMemory].
  static const int _endedCapacity = 64;

  CallPhase get phase => _phase;
  Uint8List? get callId => _callId;

  /// Whether a call is running rather than waiting for the next one.
  bool get isLive => _phase != CallPhase.idle && _phase != CallPhase.ended;

  /// Whether [signal] belongs to the call this machine is running.
  bool _isOurs(CallSignal signal) {
    final mine = _callId;
    if (mine == null) return false;
    for (var i = 0; i < callIdLen; i++) {
      if (mine[i] != signal.callId[i]) return false;
    }
    return true;
  }

  static String _key(Uint8List callId) =>
      callId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  void _forgetOld() {
    final cutoff = now().subtract(CallTimings.endedMemory);
    _ended.removeWhere((_, at) => at.isBefore(cutoff));
  }

  /// Whether [callId] is a call already over on this phone, or one the other
  /// phone told us is over before we ever saw it.
  bool hasEnded(Uint8List callId) {
    _forgetOld();
    return _ended.containsKey(_key(callId));
  }

  /// File [callId] as over.
  ///
  /// Called for every call this machine ends, and by the controller for a
  /// hangup, decline or busy that names a call this phone is not running —
  /// the one that arrived ahead of its own invite.
  void rememberEnded(Uint8List callId) {
    _forgetOld();
    final key = _key(callId);
    _ended.remove(key);
    while (_ended.length >= _endedCapacity) {
      _ended.remove(_ended.keys.first);
    }
    _ended[key] = now();
  }

  void startOutgoing({required Uint8List callId, required String sdp}) {
    if (isLive) return;
    _talkingSince = null;
    _callId = callId;
    _outgoing = true;
    _move(CallPhase.dialing);
    unawaited(send(CallSignal.invite(
      callId: callId,
      sdp: sdp,
      sentAtMs: now().millisecondsSinceEpoch,
    )));
    // The acknowledgement, not the invite, is what turns a dial into a ring.
    //
    // A hangup goes out here rather than nothing, because the silence this
    // deadline is built on is not proven: the ack can be lost the same way any
    // relay event can be (measured at 1 in 55, see MessagingService), and if
    // it was the ack that got lost rather than never sent, the callee is still
    // ringing for a call this machine is about to file as unavailable. If they
    // then answer, their accept lands on a machine already in `ended` and is
    // dropped — which would otherwise leave them in `connecting` with no
    // deadline of their own. One extra frame, ignored harmlessly by an older
    // build that never asked for it, buys the callee's phone stopping too.
    //
    // This is also the whole of the wait for an invite no relay confirmed.
    // Silence from the relays is not a reason to end the call early — callId
    // 9ba4922a rang the other phone while the caller filed it unavailable —
    // and it is not a reason to wait longer either: a phone that really cannot
    // be reached is still told so here, eight seconds after dialling.
    _arm(CallTimings.ringingAck, () {
      _sendHangup(CallEndReason.noAnswer);
      _end(CallEndCause.unavailable, CallEndSource.timer);
    });
  }

  void handleSignal(CallSignal signal) {
    if (!_isOurs(signal)) return;
    switch (signal.kind) {
      case CallSignalKind.ringing:
        if (_phase != CallPhase.dialing) return;
        _move(CallPhase.ringing);
        _arm(CallTimings.noAnswer, () {
          _sendHangup(CallEndReason.noAnswer);
          _end(CallEndCause.noAnswer, CallEndSource.timer);
        });
      case CallSignalKind.accept:
        // The ringing acknowledgement is a convenience, not a prerequisite:
        // it can be lost while the answer still reaches us.
        if (_phase != CallPhase.ringing && _phase != CallPhase.dialing) return;
        _disarm();
        _move(CallPhase.connecting);
        _arm(
          CallTimings.connecting,
          () => mediaFailed(source: CallEndSource.timer),
        );
      case CallSignalKind.decline:
        // The other end has already stopped. Telling it to stop is noise.
        _end(
          CallEndCause.declined,
          CallEndSource.remote,
          remoteReason: signal.reason,
        );
      case CallSignalKind.busy:
        _end(CallEndCause.busy, CallEndSource.remote);
      case CallSignalKind.hangup:
        _end(
          causeForRemoteHangup(signal.reason),
          CallEndSource.remote,
          remoteReason: signal.reason,
        );
      case CallSignalKind.invite:
        // A repeat delivery of the invite we are already running.
        return;
    }
  }

  /// What a hangup from the other phone means here.
  ///
  /// Every one used to be filed as `hungUp`, whatever byte it carried, so a
  /// caller whose call had failed and a caller who gave up after forty-five
  /// seconds both read as somebody pressing end. The byte has been on the wire
  /// since the first build that could call; this only stops throwing it away.
  static CallEndCause causeForRemoteHangup(CallEndReason? reason) =>
      switch (reason) {
        CallEndReason.noAnswer => CallEndCause.noAnswer,
        CallEndReason.declined => CallEndCause.declined,
        CallEndReason.busy => CallEndCause.busy,
        CallEndReason.failed => CallEndCause.failed,
        CallEndReason.hungUp || null => CallEndCause.hungUp,
      };

  /// An invite that is not for the call we are already running.
  ///
  /// Kept separate from [handleSignal] because it is the only path that may
  /// legitimately replace the current call, and mixing "answer this frame"
  /// with "abandon what you were doing" in one switch is how a state machine
  /// grows a hole.
  void handleInvite(CallSignal invite) {
    // sentAtMs is only carried by an invite, so any other kind arriving here
    // would be a null dereference below rather than a refusal.
    if (invite.kind != CallSignalKind.invite) return;
    if (_isOurs(invite)) return;
    // Relays hold events and hand them over on connect, so an invite from an
    // hour ago arrives looking new. Answering one rings the caller back for a
    // call they gave up on, which is worse than dropping it.
    if (!inviteIsFresh(sentAtMs: invite.sentAtMs!, now: now())) return;
    // Fresh, and already over: its hangup got here first. See
    // [CallTimings.endedMemory].
    if (hasEnded(invite.callId)) return;

    if (_phase == CallPhase.dialing || _phase == CallPhase.ringing) {
      // Both dialled at once. Both sides run the same comparison over the same
      // two ids, so neither has to ask the other what happened.
      if (winsGlare(mine: _callId!, theirs: invite.callId)) {
        unawaited(send(CallSignal.busy(invite.callId)));
        return;
      }
      _end(CallEndCause.glareLost, CallEndSource.remote);
    } else if (isLive) {
      unawaited(send(CallSignal.busy(invite.callId)));
      return;
    }

    _callId = invite.callId;
    _outgoing = false;
    _talkingSince = null;
    _move(CallPhase.incoming);
    // Acknowledged before anything else: without this the caller cannot tell
    // a phone that is ringing from a build that never understood the frame.
    unawaited(send(CallSignal.ringing(invite.callId)));
    _arm(
      CallTimings.noAnswer,
      () => _end(CallEndCause.noAnswer, CallEndSource.timer),
    );
  }

  void accept({required String sdp}) {
    if (_phase != CallPhase.incoming) return;
    _disarm();
    unawaited(send(CallSignal.accept(callId: _callId!, sdp: sdp)));
    _move(CallPhase.connecting);
    _arm(
      CallTimings.connecting,
      () => mediaFailed(source: CallEndSource.timer),
    );
  }

  void decline({CallEndSource source = CallEndSource.button}) {
    if (_phase != CallPhase.incoming) return;
    unawaited(send(CallSignal.decline(
      callId: _callId!,
      reason: CallEndReason.declined,
    )));
    _end(CallEndCause.declined, source);
  }

  void hangUp({CallEndSource source = CallEndSource.button}) {
    if (!isLive) return;
    _sendHangup(CallEndReason.hungUp);
    _end(CallEndCause.hungUp, source);
  }

  void mediaConnected() {
    if (_phase != CallPhase.connecting) return;
    _disarm();
    _talkingSince = now();
    _move(CallPhase.talking);
  }

  void mediaFailed({CallEndSource source = CallEndSource.media}) {
    if (!isLive) return;
    _sendHangup(CallEndReason.failed);
    _end(CallEndCause.failed, source);
  }

  /// A signal the call depends on could not leave this phone at all.
  ///
  /// Only for *not sent*, never for *not confirmed* — see the note in
  /// [startOutgoing]. The other phone is still told, in case some road the
  /// failed send did not know about is open by now.
  void signallingFailed() {
    if (!isLive) return;
    _sendHangup(CallEndReason.failed);
    _end(CallEndCause.unavailable, CallEndSource.transport);
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
  void _end(
    CallEndCause cause,
    CallEndSource source, {
    CallEndReason? remoteReason,
  }) {
    if (!isLive) return;
    _disarm();
    final since = _talkingSince;
    final outcome = CallOutcome(
      callId: _callId!,
      outgoing: _outgoing,
      cause: cause,
      talkedFor: since == null ? Duration.zero : now().difference(since),
      source: source,
      remoteReason: remoteReason,
    );
    rememberEnded(_callId!);
    _move(CallPhase.ended);
    onOutcome(outcome);
  }

  @override
  void dispose() {
    _disarm();
    super.dispose();
  }
}
