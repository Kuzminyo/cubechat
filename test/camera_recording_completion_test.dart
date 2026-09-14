import 'package:flutter_test/flutter_test.dart';
import '../third_party/camera_android_camerax/lib/src/recording_completion.dart';

void main() {
  test('native finalize before start releases failed initialization', () async {
    final recording = RecordingCompletion();
    recording.finish();
    expect(await recording.started, isFalse);
    await recording.finished;
  });
  test('late events from cancelled recording cannot start the next one',
      () async {
    final first = RecordingCompletion();
    final second = RecordingCompletion();
    var secondStarted = false;
    second.started.then((_) => secondStarted = true);
    first.finish();
    first.start();
    await Future<void>.delayed(Duration.zero);
    expect(secondStarted, isFalse);
    second.start();
    expect(await second.started, isTrue);
    first.finish();
    second.finish();
    await second.finished;
  });
}
