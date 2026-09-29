import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:cubechat/features/chats/domain/stranger_gate.dart';
import 'package:cubechat/features/profile/data/privacy_settings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  StrangerVerdict v(
    StrangerReach reach, {
    bool internet = true,
    bool wrote = false,
    bool accepted = false,
    bool pending = false,
  }) =>
      strangerVerdict(
        reach: reach,
        viaInternet: internet,
        wroteToThem: wrote,
        accepted: accepted,
        alreadyPending: pending,
      );

  test('everyone: always delivered', () {
    expect(v(StrangerReach.all), StrangerVerdict.deliver);
  });

  test('bluetooth neighbours are never gated', () {
    expect(v(StrangerReach.none, internet: false), StrangerVerdict.deliver);
    expect(v(StrangerReach.request, internet: false), StrangerVerdict.deliver);
  });

  test('people I wrote to, or accepted, are contacts', () {
    expect(v(StrangerReach.none, wrote: true), StrangerVerdict.deliver);
    expect(v(StrangerReach.request, accepted: true), StrangerVerdict.deliver);
  });

  test('request folds strangers; nobody drops them', () {
    expect(v(StrangerReach.request), StrangerVerdict.request);
    expect(v(StrangerReach.request, pending: true), StrangerVerdict.request);
    expect(v(StrangerReach.none), StrangerVerdict.drop);
  });

  test('a pending request stays a request even under nobody', () {
    expect(v(StrangerReach.none, pending: true), StrangerVerdict.request);
  });

  test('only message-bearing frames open a request', () {
    expect(opensRequest(InnerPayloadType.text), isTrue);
    expect(opensRequest(InnerPayloadType.callSignal), isTrue);
    expect(opensRequest(InnerPayloadType.mediaManifest), isTrue);
    expect(opensRequest(InnerPayloadType.receipt), isFalse);
    expect(opensRequest(InnerPayloadType.typing), isFalse);
    expect(opensRequest(InnerPayloadType.presence), isFalse);
    expect(opensRequest(InnerPayloadType.reaction), isFalse);
  });

  test('reach survives the wire round trip and defaults to everyone', () {
    for (final r in StrangerReach.values) {
      expect(StrangerReach.fromWire(r.wire), r);
    }
    expect(StrangerReach.fromWire(null), StrangerReach.all);
    expect(StrangerReach.fromWire('maybe'), StrangerReach.all);
  });
}
