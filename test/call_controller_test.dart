import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show AppLifecycleState;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cubechat/core/transport/call_signal.dart';
import 'package:cubechat/core/transport/control_delivery.dart';
import 'package:cubechat/features/call/data/call_controller.dart';
import 'package:cubechat/features/call/data/call_media.dart';
import 'package:cubechat/features/call/data/call_tones.dart';
import 'package:cubechat/features/call/data/incoming_call_surface.dart';
import 'package:cubechat/features/call/data/turn_credentials_controller.dart';
import 'package:cubechat/features/call/domain/call_rules.dart';
import 'package:cubechat/features/call/domain/call_state_machine.dart';

class FakeMedia implements CallMedia {
  final controller = StreamController<CallMediaEvent>.broadcast(sync: true);
  bool closed = false;
  bool earlyConnect = false;

  /// When false, applying the answer does not connect on its own, so a test
  /// can hold a call in `connecting`.
  bool connectOnAccept = true;
  Map<String, dynamic>? config;
  @override
  Stream<CallMediaEvent> get events => controller.stream;
  @override
  Future<String> offer(Map<String, dynamic> configuration) async {
    config = configuration;
    return 'offer';
  }

  @override
  Future<String> answer(
      Map<String, dynamic> configuration, String remoteSdp) async {
    config = configuration;
    if (earlyConnect) controller.add(CallMediaEvent.connected);
    return 'answer';
  }

  @override
  Future<void> accept(String remoteSdp) async {
    if (connectOnAccept) controller.add(CallMediaEvent.connected);
  }

  @override
  Future<void> setMuted(bool muted) async {}
  @override
  Future<void> setSpeaker(bool speaker) async {}
  @override
  Future<void> close() async {
    closed = true;
    await controller.close();
  }
}

/// Writes what it was asked to do into the same list the microphone writes
/// into, so a test can check the order the two happened in.
class FakeTones implements CallTones {
  FakeTones(this.log);
  final List<String> log;
  @override
  Future<void> play(CallTone tone) async => log.add('ring ${tone.name}');
  @override
  Future<void> stop() async => log.add('ring stop');
}

/// The phone's own incoming-call screen, writing into the same list.
class FakeSurface implements IncomingCallSurface {
  FakeSurface(this.log);
  final List<String> log;
  final pressed = StreamController<IncomingCallAction>.broadcast(sync: true);
  @override
  Stream<IncomingCallAction> get actions => pressed.stream;
  @override
  Future<void> show({required String key, required String name}) async =>
      log.add('screen show $name');
  @override
  Future<void> dismiss(String? key) async => log.add('screen dismiss');
}

const confirmed =
    ControlDelivery(links: 1, certainty: DeliveryCertainty.confirmed);

/// Seven relays written, none answered in two seconds — the 9ba4922a receipt.
const unconfirmed =
    ControlDelivery(links: 0, certainty: DeliveryCertainty.unconfirmed);

void main() {
  late StreamController<ReceivedCallSignal> signals;
  late FakeMedia media;
  late CallController call;
  late List<CallSignal> sent;
  late List<String> events;
  late List<CallOutcome> outcomes;
  Future<bool> Function() permission = () async => true;
  late Future<TurnAccess> Function() turn;
  late bool direct;
  late bool disposedByTest;
  late bool onScreen;
  late FakeSurface surface;

  /// What each send reports. A completer here holds that kind of signal in
  /// flight until the test settles it, which is how a publish still waiting
  /// for relay `OK`s is modelled.
  late Map<CallSignalKind, Future<ControlDelivery> Function()> deliveries;

  CallController build() => CallController(
        signals: signals.stream,
        send: (peer, signal) {
          sent.add(signal);
          final deliver = deliveries[signal.kind];
          return deliver == null ? Future.value(confirmed) : deliver();
        },
        obtainTurn: () => turn(),
        microphone: () {
          events.add('microphone');
          return permission();
        },
        createMedia: () => media,
        record: (peer, outcome) => outcomes.add(outcome),
        peerName: (peer) => peer,
        allowed: (_) => true,
        allowDirect: () => direct,
        prepareAudio: () async {},
        tones: FakeTones(events),
        surface: surface,
        foreground: () => onScreen,
      );

  setUp(() {
    signals = StreamController<ReceivedCallSignal>(sync: true);
    media = FakeMedia();
    sent = [];
    events = [];
    outcomes = [];
    deliveries = {};
    permission = () async => true;
    direct = false;
    disposedByTest = false;
    onScreen = true;
    surface = FakeSurface(events);
    turn = () async => TurnAccess(
        urls: ['turn:test'],
        username: 'u',
        password: 'p',
        expiresAt: DateTime.now().add(const Duration(minutes: 10)));
    call = build();
  });
  tearDown(() async {
    if (!disposedByTest) call.dispose();
    await signals.close();
    await Future<void>.delayed(Duration.zero);
  });

  Uint8List id(int seed) =>
      Uint8List.fromList(List.generate(callIdLen, (i) => (i + seed) & 0xff));

  void receive(CallSignal signal) =>
      signals.add((chatId: 'peer', signal: signal));

  CallSignal inviteFor(Uint8List callId) => CallSignal.invite(
        callId: callId,
        sdp: 'offer',
        sentAtMs: DateTime.now().millisecondsSinceEpoch,
      );

  Uint8List dialledId() =>
      sent.firstWhere((s) => s.kind == CallSignalKind.invite).callId;

  test('accept before ringing connects, ends once, releases microphone',
      () async {
    await call.dial('peer');
    expect(media.config!['iceTransportPolicy'], 'relay');
    receive(CallSignal.accept(callId: sent.first.callId, sdp: 'answer'));
    await Future<void>.delayed(Duration.zero);
    expect(call.phase, CallPhase.talking);
    call.hangUp();
    call.hangUp();
    await Future<void>.delayed(Duration.zero);
    expect(outcomes, hasLength(1));
    expect(outcomes.single.source, CallEndSource.button);
    expect(media.closed, isTrue);
  });
  test('cancel while permission is pending never sends an invite', () async {
    final grant = Completer<bool>();
    permission = () => grant.future;
    final pending = call.dial('peer');
    await Future<void>.delayed(Duration.zero);
    call.hangUp();
    grant.complete(true);
    await pending;
    expect(sent, isEmpty);
    expect(call.active, isFalse);
  });
  test('denied microphone does not send an invite', () async {
    permission = () async => false;
    await call.dial('peer');
    expect(call.error, 'microphone');
    expect(sent, isEmpty);
  });
  // The one place the design refuses service instead of finding a way round.
  // Falling back to a direct connection when our relay is down would hand the
  // other person this phone's IP address, which is exactly what the person
  // holding it chose not to do.
  test('an unreachable relay ends the call before any invite leaves', () async {
    turn = () async => throw const TurnUnavailable('unreachable');
    await call.dial('peer');
    expect(sent, isEmpty, reason: 'nobody is rung for a call that cannot connect');
    expect(call.error, 'turn');
    expect(call.active, isFalse);
    expect(media.config, isNull,
        reason: 'no connection was attempted without the relay, not even a direct one');
  });

  test('the direct-connection setting reaches the connection, and only it does',
      () async {
    direct = true;
    await call.dial('peer');
    expect(media.config!['iceTransportPolicy'], 'all');
    call.hangUp();
  });

  test('connection reported during answer is retained', () async {
    media.earlyConnect = true;
    receive(inviteFor(Uint8List(16)));
    await call.answer();
    expect(call.phase, CallPhase.talking);
    call.hangUp();
  });

  group('delivery that is not confirmed is not delivery that failed', () {
    // callId 9ba4922a, 2026-09-14: the invite reached the other phone in 290 ms
    // and it rang; the caller heard no relay OK within two seconds, filed the
    // call unavailable, and hung up on it. The ringing arrived a second later.
    test('an invite no relay confirmed keeps dialing, and rings when they do',
        () async {
      deliveries[CallSignalKind.invite] = () async => unconfirmed;
      await call.dial('peer');
      await Future<void>.delayed(Duration.zero);
      expect(call.phase, CallPhase.dialing);
      expect(call.active, isTrue);
      expect(sent.map((s) => s.kind), isNot(contains(CallSignalKind.hangup)));

      receive(CallSignal.ringing(dialledId()));
      expect(call.phase, CallPhase.ringing);
      receive(CallSignal.accept(callId: dialledId(), sdp: 'answer'));
      await Future<void>.delayed(Duration.zero);
      expect(call.phase, CallPhase.talking);
      expect(outcomes, isEmpty);
    });

    test('ringing that lands while the invite is still publishing survives '
        'the publish finishing unconfirmed', () async {
      final publish = Completer<ControlDelivery>();
      deliveries[CallSignalKind.invite] = () => publish.future;
      await call.dial('peer');
      receive(CallSignal.ringing(dialledId()));
      expect(call.phase, CallPhase.ringing);

      publish.complete(unconfirmed);
      await Future<void>.delayed(Duration.zero);
      expect(call.phase, CallPhase.ringing);
      expect(outcomes, isEmpty);
    });

    test('an accept that lands while the invite is still publishing survives '
        'the publish then failing outright', () async {
      final publish = Completer<ControlDelivery>();
      deliveries[CallSignalKind.invite] = () => publish.future;
      await call.dial('peer');
      receive(CallSignal.accept(callId: dialledId(), sdp: 'answer'));
      await Future<void>.delayed(Duration.zero);
      expect(call.phase, CallPhase.talking);

      publish.complete(ControlDelivery.notSent);
      await Future<void>.delayed(Duration.zero);
      expect(call.phase, CallPhase.talking,
          reason: 'a verdict on the invite is two seconds old by the time it '
              'arrives; the call has moved on');
      expect(outcomes, isEmpty);
    });

    test('a publish that throws after the call is talking ends nothing',
        () async {
      final publish = Completer<ControlDelivery>();
      deliveries[CallSignalKind.invite] = () => publish.future;
      await call.dial('peer');
      receive(CallSignal.ringing(dialledId()));
      receive(CallSignal.accept(callId: dialledId(), sdp: 'answer'));
      await Future<void>.delayed(Duration.zero);
      expect(call.phase, CallPhase.talking);

      publish.completeError(StateError('every relay write failed'));
      await Future<void>.delayed(Duration.zero);
      expect(call.phase, CallPhase.talking);
      expect(outcomes, isEmpty);
    });

    test('a late verdict on the previous call does not touch the next one',
        () async {
      final publish = Completer<ControlDelivery>();
      deliveries[CallSignalKind.invite] = () => publish.future;
      await call.dial('peer');
      call.hangUp();
      await Future<void>.delayed(Duration.zero);
      deliveries.remove(CallSignalKind.invite);
      await call.dial('peer');
      expect(call.phase, CallPhase.dialing);

      publish.complete(ControlDelivery.notSent);
      await Future<void>.delayed(Duration.zero);
      expect(call.phase, CallPhase.dialing);
      expect(outcomes, hasLength(1), reason: 'only the cancelled first call');
    });
  });

  group('the accept has the same race', () {
    test('an accept still publishing when the media connects survives the '
        'publish failing', () async {
      final publish = Completer<ControlDelivery>();
      deliveries[CallSignalKind.accept] = () => publish.future;
      receive(inviteFor(id(3)));
      await call.answer();
      expect(call.phase, CallPhase.connecting);
      media.controller.add(CallMediaEvent.connected);
      expect(call.phase, CallPhase.talking);

      publish.complete(ControlDelivery.notSent);
      await Future<void>.delayed(Duration.zero);
      expect(call.phase, CallPhase.talking);
      expect(outcomes, isEmpty);
    });

    test('an unconfirmed accept waits inside the connecting deadline', () async {
      deliveries[CallSignalKind.accept] = () async => unconfirmed;
      receive(inviteFor(id(3)));
      await call.answer();
      await Future<void>.delayed(Duration.zero);
      expect(call.phase, CallPhase.connecting);
      expect(outcomes, isEmpty);
    });

    test('an accept that left nothing ends the call instead of thirty seconds '
        'of connecting to nobody', () async {
      deliveries[CallSignalKind.accept] = () async => ControlDelivery.notSent;
      receive(inviteFor(id(3)));
      await call.answer();
      await Future<void>.delayed(Duration.zero);
      expect(call.active, isFalse);
      expect(outcomes.single.cause, CallEndCause.unavailable);
      expect(outcomes.single.source, CallEndSource.transport);
    });
  });

  group('a phone that really cannot be reached is still told so', () {
    test('an invite that left nothing fails now, not eight seconds from now',
        () async {
      deliveries[CallSignalKind.invite] = () async => ControlDelivery.notSent;
      await call.dial('peer');
      await Future<void>.delayed(Duration.zero);
      expect(call.active, isFalse);
      expect(call.error, 'unavailable');
      expect(outcomes.single.cause, CallEndCause.unavailable);
      expect(outcomes.single.source, CallEndSource.transport);
    });

    test('an invite whose send throws fails now', () async {
      deliveries[CallSignalKind.invite] =
          () async => throw StateError('no relay connected');
      await call.dial('peer');
      await Future<void>.delayed(Duration.zero);
      expect(call.active, isFalse);
      expect(call.error, 'unavailable');
    });

    test('an unconfirmed invite nobody acknowledges ends at the eight-second '
        'deadline, and the other phone is told to stop', () {
      fakeAsync((async) {
        // Built inside the fake zone: a future made outside it completes on
        // the real microtask queue, which flushMicrotasks never runs.
        call.dispose();
        unawaited(signals.close());
        signals = StreamController<ReceivedCallSignal>(sync: true);
        call = build();
        deliveries[CallSignalKind.invite] = () async => unconfirmed;
        unawaited(call.dial('peer'));
        async.flushMicrotasks();
        expect(call.phase, CallPhase.dialing);

        async.elapse(CallTimings.ringingAck - const Duration(milliseconds: 1));
        expect(call.phase, CallPhase.dialing);
        async.elapse(const Duration(milliseconds: 2));
        expect(call.active, isFalse);
        expect(outcomes.single.cause, CallEndCause.unavailable);
        expect(outcomes.single.source, CallEndSource.timer);
        expect(sent.last.kind, CallSignalKind.hangup);
        expect(sent.last.reason, CallEndReason.noAnswer);
        call.dispose();
        disposedByTest = true;
        async.flushMicrotasks();
      });
    });

    test('ringing nobody answers becomes no answer at forty-five seconds', () {
      fakeAsync((async) {
        // Built inside the fake zone: a future made outside it completes on
        // the real microtask queue, which flushMicrotasks never runs.
        call.dispose();
        unawaited(signals.close());
        signals = StreamController<ReceivedCallSignal>(sync: true);
        call = build();
        deliveries[CallSignalKind.invite] = () async => unconfirmed;
        unawaited(call.dial('peer'));
        async.flushMicrotasks();
        receive(CallSignal.ringing(dialledId()));
        async.elapse(CallTimings.noAnswer + const Duration(milliseconds: 1));
        expect(outcomes.single.cause, CallEndCause.noAnswer);
        expect(outcomes.single.source, CallEndSource.timer);
        call.dispose();
        disposedByTest = true;
        async.flushMicrotasks();
      });
    });
  });

  group('a cancelled call cannot come back as a ghost', () {
    test('a hangup that arrives before its own invite stops the invite ringing',
        () async {
      // A relay replays stored events newest first on reconnect.
      receive(CallSignal.hangup(callId: id(5), reason: CallEndReason.hungUp));
      receive(inviteFor(id(5)));
      expect(call.phase, isNot(CallPhase.incoming));
      expect(call.active, isFalse);
      expect(sent, isEmpty, reason: 'no ringing, and no busy either');
    });

    test('an invite delivered again after its call ended does not ring again',
        () async {
      receive(inviteFor(id(6)));
      expect(call.phase, CallPhase.incoming);
      receive(CallSignal.hangup(callId: id(6), reason: CallEndReason.hungUp));
      expect(call.phase, CallPhase.ended);
      call.dismiss();
      sent.clear();

      receive(inviteFor(id(6)));
      expect(call.active, isFalse);
      expect(sent, isEmpty);
    });

    test('cancelling while the invite is publishing, then their ringing and '
        'accept arriving, tells them to stop once and starts nothing', () async {
      final publish = Completer<ControlDelivery>();
      deliveries[CallSignalKind.invite] = () => publish.future;
      await call.dial('peer');
      final callId = dialledId();
      call.hangUp();
      await Future<void>.delayed(Duration.zero);
      publish.complete(unconfirmed);
      await Future<void>.delayed(Duration.zero);
      sent.clear();

      receive(CallSignal.ringing(callId));
      receive(CallSignal.accept(callId: callId, sdp: 'answer'));
      await Future<void>.delayed(Duration.zero);
      expect(call.active, isFalse);
      expect(sent.map((s) => s.kind), [CallSignalKind.hangup],
          reason: 'our first hangup may have been lost; one more, not two');
      expect(outcomes, hasLength(1));
    });
  });

  group('every ending says what ended it', () {
    test('a hangup from the other phone keeps the reason it carried', () async {
      receive(inviteFor(id(7)));
      receive(CallSignal.hangup(callId: id(7), reason: CallEndReason.failed));
      expect(outcomes.single.cause, CallEndCause.failed);
      expect(outcomes.single.source, CallEndSource.remote);
      expect(outcomes.single.remoteReason, CallEndReason.failed);
    });

    test('the button', () async {
      receive(inviteFor(id(8)));
      call.decline();
      expect(outcomes.single.source, CallEndSource.button);
    });

    test('the app closing hangs up and tells the other phone', () async {
      await call.dial('peer');
      call.noteLifecycle(AppLifecycleState.paused);
      expect(call.phase, CallPhase.dialing, reason: 'backgrounded is not closed');
      call.noteLifecycle(AppLifecycleState.detached);
      expect(outcomes.single.source, CallEndSource.lifecycle);
      expect(sent.last.kind, CallSignalKind.hangup);
    });

    test('the controller going away hangs up instead of vanishing', () async {
      await call.dial('peer');
      call.dispose();
      disposedByTest = true;
      expect(outcomes.single.source, CallEndSource.dispose);
      expect(sent.last.kind, CallSignalKind.hangup);
    });
  });

  group('the ringtone', () {
    test('rings while being called and stops before the microphone is asked',
        () async {
      receive(inviteFor(id(9)));
      await Future<void>.delayed(Duration.zero);
      expect(events, ['ring incoming']);
      await call.answer();
      expect(events.take(3), ['ring incoming', 'ring stop', 'microphone']);
      call.hangUp();
    });

    test('stops when the caller gives up', () async {
      receive(inviteFor(id(10)));
      receive(CallSignal.hangup(callId: id(10), reason: CallEndReason.noAnswer));
      await Future<void>.delayed(Duration.zero);
      expect(events, ['ring incoming', 'ring stop']);
    });

    test('never rings for our own outgoing call', () async {
      await call.dial('peer');
      receive(CallSignal.ringing(dialledId()));
      await Future<void>.delayed(Duration.zero);
      expect(events.where((e) => e.startsWith('ring')), isEmpty);
      call.hangUp();
    });
  });

  group('with the app off screen, the phone shows the call', () {
    String keyOf(Uint8List callId) =>
        callId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    test("a ringing call goes to the phone's screen, not the app's tone",
        () async {
      onScreen = false;
      receive(inviteFor(id(20)));
      await Future<void>.delayed(Duration.zero);
      expect(events, ['screen show peer']);
      call.decline();
    });

    test('the caller giving up takes it down', () async {
      onScreen = false;
      receive(inviteFor(id(21)));
      receive(CallSignal.hangup(callId: id(21), reason: CallEndReason.noAnswer));
      await Future<void>.delayed(Duration.zero);
      expect(events, ['screen show peer', 'screen dismiss']);
    });

    test('Answer there answers, and the screen is gone before the microphone '
        'opens', () async {
      onScreen = false;
      media.connectOnAccept = false;
      receive(inviteFor(id(22)));
      await Future<void>.delayed(Duration.zero);
      surface.pressed.add((kind: IncomingCallActionKind.answer, key: keyOf(id(22))));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(call.phase, CallPhase.connecting);
      expect(sent.last.kind, CallSignalKind.accept);
      expect(events.take(3), ['screen show peer', 'screen dismiss', 'microphone']);
      call.hangUp();
    });

    test('Decline there declines and tells the caller', () async {
      onScreen = false;
      receive(inviteFor(id(23)));
      await Future<void>.delayed(Duration.zero);
      surface.pressed.add((kind: IncomingCallActionKind.decline, key: keyOf(id(23))));
      expect(outcomes.single.cause, CallEndCause.declined);
      expect(sent.last.kind, CallSignalKind.decline);
    });

    test('a button for a call that already stopped ringing does nothing', () async {
      onScreen = false;
      receive(inviteFor(id(24)));
      receive(CallSignal.hangup(callId: id(24), reason: CallEndReason.hungUp));
      sent.clear();
      surface.pressed.add((kind: IncomingCallActionKind.answer, key: keyOf(id(24))));
      await Future<void>.delayed(Duration.zero);
      expect(sent, isEmpty);
      expect(events, isNot(contains('microphone')));
    });

    test('opening the app while it rings moves the ring into the app, and '
        'leaving moves it back', () async {
      onScreen = false;
      receive(inviteFor(id(25)));
      await Future<void>.delayed(Duration.zero);
      onScreen = true;
      call.noteLifecycle(AppLifecycleState.resumed);
      onScreen = false;
      call.noteLifecycle(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(events, [
        'screen show peer',
        'ring incoming',
        'screen dismiss',
        'ring stop',
        'screen show peer',
      ]);
      call.decline();
    });

    test("an outgoing call never puts anything on the phone's screen",
        () async {
      onScreen = false;
      await call.dial('peer');
      receive(CallSignal.ringing(dialledId()));
      await Future<void>.delayed(Duration.zero);
      expect(events.where((e) => e.startsWith('screen')), isEmpty);
      call.hangUp();
    });
  });
}
