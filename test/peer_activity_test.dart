// What the other phone is doing, on one byte of a frame that already existed.
//
// Typing has always travelled as `InnerPayloadType.typing` with a single-byte
// body: 0x01 for typing, anything else for stopped. Recording a voice message
// and recording a circle are the same shape of fact arriving on the same
// frame, so they are values of that byte rather than payload types of their
// own — and that choice is what decides, for free, what a build that predates
// them does with one.
import 'package:cubechat/features/peers/data/peer_activity.dart';
import 'package:cubechat/features/peers/data/typing_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('each activity keeps its byte', () {
    // Pinned, not derived. These are on the wire between two phones that may
    // be running different builds, so reordering the enum must not silently
    // turn one activity into another.
    expect(PeerActivity.typing.wireByte, 0x01);
    expect(PeerActivity.recordingVoice.wireByte, 0x02);
    expect(PeerActivity.recordingCircle.wireByte, 0x03);
  });

  test('0x01 is still typing, so an older sender is understood', () {
    expect(PeerActivity.fromWire(0x01), PeerActivity.typing);
  });

  test('a stop, and anything unknown, reads as no activity', () {
    // The old decoder is `body[0] != 0x01 -> clear`, so a build that predates
    // this takes the indicator *down* for 0x02 and 0x03. Nothing wrong appears
    // under somebody's name there; it simply says nothing. This side answers a
    // byte from the future the same way, which is why the check is a lookup
    // and not "anything non-zero is typing".
    expect(PeerActivity.fromWire(0x00), isNull);
    expect(PeerActivity.fromWire(0x04), isNull);
    expect(PeerActivity.fromWire(0xFF), isNull);
  });

  group('the controller carries the kind, not just the moment', () {
    late ProviderContainer container;
    setUp(() => container = ProviderContainer());
    tearDown(() => container.dispose());

    test('a recording notice reports as recording', () {
      final typing = container.read(typingControllerProvider.notifier);
      typing.record('abc', kind: PeerActivity.recordingCircle);
      expect(typing.activityOf('abc'), PeerActivity.recordingCircle);
      expect(typing.isTyping('abc'), isTrue,
          reason: 'the header shows one line for all of them, so "is anything '
              'happening" still has to answer yes');
    });

    test('a later notice of another kind replaces the one showing', () {
      // Somebody who was typing and then held the microphone is recording, not
      // both — there is one line and it says the latest thing.
      final typing = container.read(typingControllerProvider.notifier);
      typing.record('abc');
      typing.record('abc', kind: PeerActivity.recordingVoice);
      expect(typing.activityOf('abc'), PeerActivity.recordingVoice);
    });

    test('a notice older than the window is not believed', () {
      // A frame held in a relay backlog comes out looking new. Presence
      // filters that; this has to as well, or a seven-minute-old keystroke
      // lights the line for its full eight seconds.
      final typing = container.read(typingControllerProvider.notifier);
      typing.record(
        'abc',
        at: DateTime.now().subtract(TypingController.ttl * 2),
        kind: PeerActivity.recordingVoice,
      );
      expect(typing.activityOf('abc'), isNull);
    });

    test('a stop clears it whatever kind it was', () {
      final typing = container.read(typingControllerProvider.notifier);
      typing.record('abc', kind: PeerActivity.recordingCircle);
      typing.clear('abc');
      expect(typing.activityOf('abc'), isNull);
    });
  });
}
