import 'dart:typed_data';

import 'package:cubechat/core/transport/call_signal.dart';
import 'package:cubechat/features/call/domain/call_rules.dart';
import 'package:cubechat/features/call/domain/call_state_machine.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List id(int seed) =>
      Uint8List.fromList(List.generate(callIdLen, (i) => (i + seed) & 0xff));

  ({
    CallStateMachine machine,
    List<CallSignal> sent,
    List<CallOutcome> outcomes,
    DateTime Function() clock,
  }) build(FakeAsync async) {
    final sent = <CallSignal>[];
    final outcomes = <CallOutcome>[];
    // Start the clock well away from zero so an invite can be stamped in the
    // past without the arithmetic going negative.
    DateTime clock() => DateTime.utc(2026, 9, 10, 12).add(async.elapsed);
    final machine = CallStateMachine(
      send: (signal) async => sent.add(signal),
      onOutcome: outcomes.add,
      now: clock,
    );
    return (machine: machine, sent: sent, outcomes: outcomes, clock: clock);
  }

  CallSignal inviteAt(Uint8List callId, DateTime at) => CallSignal.invite(
        callId: callId,
        sdp: 'offer',
        sentAtMs: at.millisecondsSinceEpoch,
      );

  test('handleInvite guards against a frame that is not an invite', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.handleInvite(CallSignal.ringing(id(1)));
      async.flushMicrotasks();
      expect(t.machine.phase, CallPhase.idle);
      expect(t.sent, isEmpty);
      expect(t.outcomes, isEmpty);
      t.machine.dispose();
    });
  });

  test('a fresh invite rings and acknowledges immediately', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.handleInvite(inviteAt(id(1), t.clock()));
      async.flushMicrotasks();
      expect(t.machine.phase, CallPhase.incoming);
      expect(t.sent.single.kind, CallSignalKind.ringing);
      expect(t.sent.single.callId, equals(id(1)));
      t.machine.dispose();
    });
  });

  test('an invite from an hour ago rings nothing and answers nothing', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.handleInvite(
        inviteAt(id(1), t.clock().subtract(const Duration(hours: 1))),
      );
      async.flushMicrotasks();
      expect(t.machine.phase, CallPhase.idle);
      expect(t.sent, isEmpty,
          reason: 'answering a stale invite would ring the caller back for a '
              'call they gave up on an hour ago');
      expect(t.outcomes, isEmpty);
      t.machine.dispose();
    });
  });

  test('the same invite delivered twice rings once', () {
    fakeAsync((async) {
      final t = build(async);
      final invite = inviteAt(id(1), t.clock());
      t.machine.handleInvite(invite);
      t.machine.handleInvite(invite);
      async.flushMicrotasks();
      expect(t.sent, hasLength(1));
      t.machine.dispose();
    });
  });

  test('an invite arriving mid-conversation answers busy and changes nothing',
      () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.handleInvite(inviteAt(id(1), t.clock()));
      t.machine.accept(sdp: 'answer');
      t.machine.mediaConnected();
      t.machine.handleInvite(inviteAt(id(2), t.clock()));
      async.flushMicrotasks();
      expect(t.machine.phase, CallPhase.talking);
      expect(t.machine.callId, equals(id(1)));
      final busy = t.sent.where((s) => s.kind == CallSignalKind.busy);
      expect(busy.single.callId, equals(id(2)));
      t.machine.dispose();
    });
  });

  test('accepting sends the answer and connects', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.handleInvite(inviteAt(id(1), t.clock()));
      t.machine.accept(sdp: 'answer');
      async.flushMicrotasks();
      expect(t.machine.phase, CallPhase.connecting);
      expect(t.sent.last.kind, CallSignalKind.accept);
      expect(t.sent.last.sdp, 'answer');
      t.machine.mediaConnected();
      expect(t.machine.phase, CallPhase.talking);
      t.machine.dispose();
    });
  });

  test('declining tells the caller and records a declined call', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.handleInvite(inviteAt(id(1), t.clock()));
      t.machine.decline();
      async.flushMicrotasks();
      expect(t.sent.last.kind, CallSignalKind.decline);
      expect(t.machine.phase, CallPhase.ended);
      expect(t.outcomes.single.cause, CallEndCause.declined);
      expect(t.outcomes.single.outgoing, isFalse);
      t.machine.dispose();
    });
  });

  test('an unanswered incoming call becomes a missed call on its own', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.handleInvite(inviteAt(id(1), t.clock()));
      async.elapse(CallTimings.noAnswer + const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(t.machine.phase, CallPhase.ended);
      expect(t.outcomes.single.cause, CallEndCause.noAnswer);
      expect(t.outcomes.single.outgoing, isFalse);
      t.machine.dispose();
    });
  });

  test('the caller hanging up stops the ringing', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.handleInvite(inviteAt(id(1), t.clock()));
      t.machine.handleSignal(
        CallSignal.hangup(callId: id(1), reason: CallEndReason.hungUp),
      );
      async.flushMicrotasks();
      expect(t.machine.phase, CallPhase.ended);
      expect(t.outcomes.single.cause, CallEndCause.hungUp);
      t.machine.dispose();
    });
  });

  group('both dialled at once', () {
    test('the smaller id wins and its own call carries on', () {
      fakeAsync((async) {
        final t = build(async);
        t.machine.startOutgoing(callId: id(1), sdp: 'offer');
        t.machine.handleInvite(inviteAt(id(2), t.clock()));
        async.flushMicrotasks();
        expect(t.machine.phase, CallPhase.dialing);
        expect(t.machine.callId, equals(id(1)));
        expect(t.outcomes, isEmpty);
        final busy = t.sent.where((s) => s.kind == CallSignalKind.busy);
        expect(busy.single.callId, equals(id(2)),
            reason: 'the loser is told, or it rings until it times out');
        t.machine.dispose();
      });
    });

    test('the larger id gives way and takes the incoming call', () {
      fakeAsync((async) {
        final t = build(async);
        t.machine.startOutgoing(callId: id(9), sdp: 'offer');
        t.machine.handleInvite(inviteAt(id(1), t.clock()));
        async.flushMicrotasks();
        expect(t.machine.phase, CallPhase.incoming);
        expect(t.machine.callId, equals(id(1)));
        expect(t.outcomes.single.cause, CallEndCause.glareLost);
        expect(t.outcomes.single.outgoing, isTrue);
        expect(t.sent.last.kind, CallSignalKind.ringing);
        t.machine.dispose();
      });
    });

    test('a stale invite never wins a contest it should not be in', () {
      fakeAsync((async) {
        final t = build(async);
        t.machine.startOutgoing(callId: id(9), sdp: 'offer');
        t.machine.handleInvite(
          inviteAt(id(1), t.clock().subtract(const Duration(hours: 1))),
        );
        async.flushMicrotasks();
        expect(t.machine.phase, CallPhase.dialing);
        expect(t.machine.callId, equals(id(9)));
        t.machine.dispose();
      });
    });
  });
}
