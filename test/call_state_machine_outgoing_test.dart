import 'dart:typed_data';

import 'package:cubechat/core/transport/call_signal.dart';
import 'package:cubechat/features/call/domain/call_rules.dart';
import 'package:cubechat/features/call/domain/call_state_machine.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List id(int seed) =>
      Uint8List.fromList(List.generate(callIdLen, (i) => (i + seed) & 0xff));

  /// A machine plus the two things it says to the outside world.
  ({
    CallStateMachine machine,
    List<CallSignal> sent,
    List<CallOutcome> outcomes,
  }) build(FakeAsync async) {
    final sent = <CallSignal>[];
    final outcomes = <CallOutcome>[];
    final machine = CallStateMachine(
      send: (signal) async => sent.add(signal),
      onOutcome: outcomes.add,
      now: () => DateTime.fromMillisecondsSinceEpoch(
        async.elapsed.inMilliseconds,
        isUtc: true,
      ),
    );
    return (machine: machine, sent: sent, outcomes: outcomes);
  }

  test('dialing sends an invite and is not yet ringing', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      async.flushMicrotasks();
      expect(t.machine.phase, CallPhase.dialing);
      expect(t.sent.single.kind, CallSignalKind.invite);
      expect(t.sent.single.sdp, 'offer');
      expect(t.sent.single.callId, equals(id(1)));
      t.machine.dispose();
    });
  });

  test('the ringback starts only when the other end says it is ringing', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      async.elapse(const Duration(seconds: 2));
      expect(t.machine.phase, CallPhase.dialing);
      t.machine.handleSignal(CallSignal.ringing(id(1)));
      expect(t.machine.phase, CallPhase.ringing);
      t.machine.dispose();
    });
  });

  test('no acknowledgement means unavailable, not an endless ringback', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      async.elapse(CallTimings.ringingAck + const Duration(milliseconds: 1));
      expect(t.machine.phase, CallPhase.ended);
      expect(t.outcomes.single.cause, CallEndCause.unavailable);
      expect(t.outcomes.single.outgoing, isTrue);
      t.machine.dispose();
    });
  });

  test('an accept moves to connecting, and media moves it to talking', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      t.machine.handleSignal(CallSignal.ringing(id(1)));
      t.machine.handleSignal(CallSignal.accept(callId: id(1), sdp: 'answer'));
      expect(t.machine.phase, CallPhase.connecting);
      t.machine.mediaConnected();
      expect(t.machine.phase, CallPhase.talking);
      t.machine.dispose();
    });
  });

  test('forty-five seconds of ringing becomes a missed call and hangs up', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      t.machine.handleSignal(CallSignal.ringing(id(1)));
      async.elapse(CallTimings.noAnswer + const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(t.machine.phase, CallPhase.ended);
      expect(t.outcomes.single.cause, CallEndCause.noAnswer);
      expect(t.sent.last.kind, CallSignalKind.hangup);
      expect(t.sent.last.reason, CallEndReason.noAnswer);
      t.machine.dispose();
    });
  });

  test('a decline ends the call and does not send a hangup back', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      t.machine.handleSignal(CallSignal.ringing(id(1)));
      t.machine.handleSignal(
        CallSignal.decline(callId: id(1), reason: CallEndReason.declined),
      );
      async.flushMicrotasks();
      expect(t.machine.phase, CallPhase.ended);
      expect(t.outcomes.single.cause, CallEndCause.declined);
      expect(
        t.sent.where((s) => s.kind == CallSignalKind.hangup),
        isEmpty,
        reason: 'the other end already stopped; telling it to stop is noise',
      );
      t.machine.dispose();
    });
  });

  test('busy is its own outcome', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      t.machine.handleSignal(CallSignal.busy(id(1)));
      async.flushMicrotasks();
      expect(t.outcomes.single.cause, CallEndCause.busy);
      t.machine.dispose();
    });
  });

  test('hanging up mid-conversation records how long it lasted', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      t.machine.handleSignal(CallSignal.ringing(id(1)));
      t.machine.handleSignal(CallSignal.accept(callId: id(1), sdp: 'answer'));
      t.machine.mediaConnected();
      async.elapse(const Duration(minutes: 2, seconds: 31));
      t.machine.hangUp();
      async.flushMicrotasks();
      expect(t.machine.phase, CallPhase.ended);
      expect(t.outcomes.single.talkedFor,
          const Duration(minutes: 2, seconds: 31));
      expect(t.outcomes.single.cause, CallEndCause.hungUp);
      expect(t.sent.last.kind, CallSignalKind.hangup);
      t.machine.dispose();
    });
  });

  test('a call that never connected lasted no time at all', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      t.machine.handleSignal(CallSignal.ringing(id(1)));
      async.elapse(const Duration(seconds: 10));
      t.machine.hangUp();
      async.flushMicrotasks();
      expect(t.outcomes.single.talkedFor, Duration.zero);
      t.machine.dispose();
    });
  });

  test('media failing ends the call rather than hanging in connecting', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      t.machine.handleSignal(CallSignal.ringing(id(1)));
      t.machine.handleSignal(CallSignal.accept(callId: id(1), sdp: 'answer'));
      t.machine.mediaFailed();
      async.flushMicrotasks();
      expect(t.machine.phase, CallPhase.ended);
      expect(t.outcomes.single.cause, CallEndCause.failed);
      t.machine.dispose();
    });
  });

  test('a signal for some other call is ignored', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      t.machine.handleSignal(CallSignal.ringing(id(9)));
      expect(t.machine.phase, CallPhase.dialing);
      t.machine.dispose();
    });
  });

  test('the same acknowledgement twice does not restart anything', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      t.machine.handleSignal(CallSignal.ringing(id(1)));
      async.elapse(const Duration(seconds: 40));
      t.machine.handleSignal(CallSignal.ringing(id(1)));
      async.elapse(const Duration(seconds: 6));
      async.flushMicrotasks();
      expect(t.outcomes.single.cause, CallEndCause.noAnswer,
          reason: 'a repeat delivery must not buy another forty-five seconds');
      t.machine.dispose();
    });
  });

  test('exactly one outcome per call, no matter what arrives after', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      t.machine.handleSignal(CallSignal.ringing(id(1)));
      t.machine.hangUp();
      t.machine.handleSignal(
        CallSignal.hangup(callId: id(1), reason: CallEndReason.hungUp),
      );
      t.machine.mediaFailed();
      async.flushMicrotasks();
      expect(t.outcomes, hasLength(1));
      t.machine.dispose();
    });
  });

  test('no timer outlives the machine', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      t.machine.dispose();
      async.elapse(const Duration(minutes: 5));
      expect(async.pendingTimers, isEmpty);
    });
  });
}
