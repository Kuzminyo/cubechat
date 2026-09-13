import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:cubechat/core/transport/call_signal.dart';
import 'package:cubechat/features/call/data/call_controller.dart';
import 'package:cubechat/features/call/data/call_media.dart';
import 'package:cubechat/features/call/data/turn_credentials_controller.dart';
import 'package:cubechat/features/call/domain/call_state_machine.dart';

class FakeMedia implements CallMedia {
  final controller = StreamController<CallMediaEvent>.broadcast(sync: true);
  bool closed = false;
  bool earlyConnect = false;
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
    controller.add(CallMediaEvent.connected);
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

void main() {
  late StreamController<ReceivedCallSignal> signals;
  late FakeMedia media;
  late CallController call;
  late List<CallSignal> sent;
  late List<CallOutcome> outcomes;
  Future<bool> Function() permission = () async => true;
  late Future<TurnAccess> Function() turn;
  late int links;
  late bool direct;
  setUp(() {
    signals = StreamController<ReceivedCallSignal>(sync: true);
    media = FakeMedia();
    sent = [];
    outcomes = [];
    permission = () async => true;
    links = 1;
    direct = false;
    turn = () async => TurnAccess(
        urls: ['turn:test'],
        username: 'u',
        password: 'p',
        expiresAt: DateTime.now().add(const Duration(minutes: 10)));
    call = CallController(
      signals: signals.stream,
      send: (peer, signal) async {
        sent.add(signal);
        return links;
      },
      obtainTurn: () => turn(),
      microphone: () => permission(),
      createMedia: () => media,
      record: (peer, outcome) => outcomes.add(outcome),
      peerName: (peer) => peer,
      allowed: (_) => true,
      allowDirect: () => direct,
      prepareAudio: () async {},
    );
  });
  tearDown(() async {
    call.dispose();
    await signals.close();
    await Future<void>.delayed(Duration.zero);
  });
  test('accept before ringing connects, ends once, releases microphone',
      () async {
    await call.dial('peer');
    expect(media.config!['iceTransportPolicy'], 'relay');
    signals.add((
      chatId: 'peer',
      signal: CallSignal.accept(callId: sent.first.callId, sdp: 'answer')
    ));
    await Future<void>.delayed(Duration.zero);
    expect(call.phase, CallPhase.talking);
    call.hangUp();
    call.hangUp();
    await Future<void>.delayed(Duration.zero);
    expect(outcomes, hasLength(1));
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

  test('an invite that reached nobody fails now, not eight seconds from now',
      () async {
    links = 0;
    await call.dial('peer');
    await Future<void>.delayed(Duration.zero);
    expect(call.active, isFalse);
    expect(call.error, 'unavailable');
  });

  test('connection reported during answer is retained', () async {
    media.earlyConnect = true;
    signals.add((
      chatId: 'peer',
      signal: CallSignal.invite(
          callId: Uint8List(16),
          sdp: 'offer',
          sentAtMs: DateTime.now().millisecondsSinceEpoch)
    ));
    await call.answer();
    expect(call.phase, CallPhase.talking);
    call.hangUp();
  });
}
