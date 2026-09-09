import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:cubechat/features/chat/data/voice_playback_controller.dart';
import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';

class FakeVideo extends VideoPlayerController {
  FakeVideo() : super.file(File('unused'));
  bool disposed = false;
  int plays = 0;
  Completer<void>? opening;
  @override
  Future<void> initialize() async {
    await opening?.future;
    if (!disposed) {
      value = value.copyWith(
        isInitialized: true,
        duration: const Duration(seconds: 10),
        size: const Size(720, 1280),
      );
    }
  }

  @override
  Future<void> play() async {
    plays++;
    value = value.copyWith(isPlaying: true);
  }

  @override
  Future<void> pause() async {
    value = value.copyWith(isPlaying: false);
  }

  @override
  Future<void> setLooping(bool looping) async {}
  @override
  Future<void> seekTo(Duration position) async {
    value = value.copyWith(position: position);
  }

  @override
  Future<void> setPlaybackSpeed(double speed) async {
    value = value.copyWith(playbackSpeed: speed);
  }

  @override
  // No native player was created by this fake.
  // ignore: must_call_super
  Future<void> dispose() async {
    disposed = true;
  }
}

class Playback extends VoicePlaybackController {
  final made = <FakeVideo>[];
  Completer<void>? opening;
  @override
  VideoPlayerController createVideo(String path) {
    final video = FakeVideo()..opening = opening;
    made.add(video);
    return video;
  }
}

class Messages extends MessagesController {
  final heard = <String>[];
  @override
  Map<String, List<Message>> build() => {};
  @override
  void markVoicePlayed(String peerId, String messageId) => heard.add(messageId);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late File file;
  late ProviderContainer container;
  late Playback controller;
  Future<void> start(String id) => controller.toggleCircle(
        messageId: id,
        path: file.path,
        chatId: 'peer',
        chatTitle: 'Name',
      );
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global'),
      (_) async => null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global/events'),
      (_) async => null,
    );
    dir = Directory.systemTemp.createTempSync('circle_playback');
    file = File('${dir.path}/video.mp4')..writeAsBytesSync([0]);
    container = ProviderContainer(
      overrides: [
        voicePlaybackControllerProvider.overrideWith(Playback.new),
        messagesControllerProvider.overrideWith(Messages.new),
      ],
    );
    controller =
        container.read(voicePlaybackControllerProvider.notifier) as Playback;
  });
  tearDown(() async {
    await controller.stop();
    container.dispose();
    dir.deleteSync(recursive: true);
  });
  test('circle uses island controls for pause, seek and speed and marks heard',
      () async {
    await start('one');
    expect(container.read(voicePlaybackControllerProvider).isCircle, true);
    expect(container.read(voicePlaybackControllerProvider).playing, true);
    expect(
      (container.read(messagesControllerProvider.notifier) as Messages).heard,
      ['one'],
    );
    await controller.togglePlayPause();
    expect(controller.video!.value.isPlaying, false);
    await controller.seekFraction(.5);
    expect(controller.video!.value.position, const Duration(seconds: 5));
    await controller.cycleSpeed();
    expect(controller.video!.value.playbackSpeed, 1.5);
    await controller.togglePlayPause();
    expect(controller.video!.value.isPlaying, true);
  });
  test(
      'switching circles releases the previous decoder and completion closes island',
      () async {
    await start('one');
    final first = controller.made.single;
    await start('two');
    expect(first.disposed, true);
    final second = controller.made.last;
    second.value = second.value.copyWith(isCompleted: true);
    expect(container.read(voicePlaybackControllerProvider).isActive, false);
    expect(second.disposed, true);
  });
  test('dismissal during initialization cannot start ghost playback', () async {
    controller.opening = Completer<void>();
    final pending = start('one');
    await Future<void>.delayed(Duration.zero);
    expect(controller.made, hasLength(1));
    await controller.stop();
    controller.opening!.complete();
    await pending;
    expect(controller.made.single.plays, 0);
    expect(controller.made.single.disposed, true);
    expect(container.read(voicePlaybackControllerProvider).isActive, false);
  });
}
