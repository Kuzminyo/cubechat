import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cubechat/features/chat/data/video_frames.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('poster work is serialized, deduplicated and memory stays bounded',
      () async {
    final dir = Directory.systemTemp.createTempSync('poster-budget');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => dir.path);
    var active = 0;
    var peak = 0;
    var calls = 0;
    final gate = Completer<void>();
    messenger.setMockMethodCallHandler(
        const MethodChannel('cubechat/video_frame'), (call) async {
      calls++;
      active++;
      if (active > peak) peak = active;
      await gate.future;
      active--;
      return {'frame': true, 'durationMs': 1000, 'width': 100, 'height': 100};
    });
    final files = [
      for (var i = 0; i < 110; i++)
        File('${dir.path}/$i.mp4')..writeAsBytesSync([0])
    ];
    final first = VideoFrames.of(files.first.path);
    expect(identical(first, VideoFrames.of(files.first.path)), isTrue);
    final all = [first, for (final f in files.skip(1)) VideoFrames.of(f.path)];
    gate.complete();
    await Future.wait(all);
    expect(peak, 1);
    expect(calls, files.length);
    expect(VideoFrames.peek(files.first.path), isNull);
    expect(VideoFrames.peek(files.last.path), isNotNull);
    await VideoFrames.of(files.last.path);
    expect(calls, files.length);
    messenger.setMockMethodCallHandler(
        const MethodChannel('cubechat/video_frame'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), null);
    dir.deleteSync(recursive: true);
  });
}
