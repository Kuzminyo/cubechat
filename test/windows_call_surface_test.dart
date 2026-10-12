import 'dart:async';

import 'package:cubechat/features/call/data/call_tones.dart';
import 'package:cubechat/features/call/data/incoming_call_surface.dart';
import 'package:flutter_test/flutter_test.dart';

class _Tones implements CallTones {
  final log = <String>[];
  @override
  Future<void> play(CallTone tone) async => log.add('play ${tone.name}');
  @override
  Future<void> stop() async => log.add('stop');
}

class _Toast implements DesktopCallToast {
  final log = <String>[];
  final pressed = StreamController<DesktopToastPress>.broadcast(sync: true);
  @override
  Stream<DesktopToastPress> get presses => pressed.stream;
  @override
  Future<void> show({
    required String key,
    required String title,
    required String body,
    required String answer,
    required String decline,
  }) async =>
      log.add('show $key $title $body [$answer|$decline]');
  @override
  Future<void> close(String key) async => log.add('close $key');
}

/// The incoming call on a Windows computer, where there is no CallKit and no
/// full-screen notification: a Windows toast with Answer and Decline, and the
/// ringtone, while CubeChat is running (2026-10-12).
void main() {
  late _Tones tones;
  late _Toast toast;
  late WindowsIncomingCallSurface surface;

  setUp(() {
    tones = _Tones();
    toast = _Toast();
    surface = WindowsIncomingCallSurface(
      labels: () => (
        title: 'Incoming call',
        answer: 'Answer',
        decline: 'Decline',
        ongoing: 'Voice call',
        hangUp: 'End',
        speaker: 'Speaker',
        microphone: 'Microphone',
      ),
      tones: tones,
      toast: toast,
    );
  });

  test('it rings itself, so the app does not ring as well', () {
    expect(surface.ringsInForeground, isTrue);
  });

  test('a call rings and raises a toast with the caller', () async {
    await surface.show(key: 'k1', name: 'Ann');
    expect(tones.log, ['play incoming']);
    expect(toast.log, ['show k1 Incoming call Ann [Answer|Decline]']);
  });

  test('answering or dismissing stops the ring and takes the toast down',
      () async {
    await surface.show(key: 'k1', name: 'Ann');
    await surface.answered('k1');
    expect(tones.log.last, 'stop');
    expect(toast.log.last, 'close k1');
    await surface.show(key: 'k2', name: 'Bob');
    await surface.dismiss(null);
    expect(tones.log.last, 'stop');
    expect(toast.log.last, 'close k2', reason: 'null means whatever is up');
  });

  test('the toast\'s buttons are the call\'s Answer and Decline', () async {
    final got = <IncomingCallAction>[];
    surface.actions.listen(got.add);
    await surface.show(key: 'k1', name: 'Ann');
    toast.pressed.add((key: 'k1', button: 0));
    toast.pressed.add((key: 'k1', button: 1));
    await Future<void>.delayed(Duration.zero);
    expect(got, [
      (kind: IncomingCallActionKind.answer, key: 'k1'),
      (kind: IncomingCallActionKind.decline, key: 'k1'),
    ]);
  });
}
