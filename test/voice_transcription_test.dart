import 'dart:async';
import 'package:cubechat/features/chat/data/transcription_language.dart';
import 'package:cubechat/features/chat/data/voice_transcription_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A language already chosen, with no settings box behind it.
class _Language extends TranscriptionLanguageController {
  _Language(this.choice);
  final TranscriptionLanguage choice;
  @override
  TranscriptionLanguage build() => choice;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  final calls = <MethodCall>[];

  void answerWith(Object? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      VoiceTranscriptionController.channel,
      (call) async {
        calls.add(call);
        return handler(call);
      },
    );
  }

  setUp(() {
    calls.clear();
    // One chosen language, so what reaches the platform does not depend on
    // the machine the test runs on (see transcription_language_test).
    container = ProviderContainer(overrides: [
      transcriptionLanguageProvider.overrideWith(
        () => _Language(TranscriptionLanguage.ukrainian),
      ),
    ]);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(VoiceTranscriptionController.channel, null);
    container.dispose();
  });

  test('a transcript comes back and is remembered', () async {
    answerWith((_) => 'meet me at six');
    final controller = container.read(voiceTranscriptionProvider.notifier);

    final text = await controller.transcribe(
      messageId: 'm1',
      audioPath: '/tmp/a.m4a',
      localeId: 'uk-UA',
    );

    expect(text, 'meet me at six');
    expect(container.read(voiceTranscriptionProvider)['m1'], 'meet me at six');
    expect(calls.single.method, 'transcribe');
    expect(calls.single.arguments, {
      'path': '/tmp/a.m4a',
      'locale': 'uk-UA',
    });
  });

  test('asking twice does not run it twice', () async {
    // The work costs seconds and a wakeful CPU, and the answer cannot change.
    answerWith((_) => 'once');
    final controller = container.read(voiceTranscriptionProvider.notifier);

    await controller.transcribe(messageId: 'm1', audioPath: '/tmp/a.m4a');
    await controller.transcribe(messageId: 'm1', audioPath: '/tmp/a.m4a');

    expect(calls.length, 1);
  });

  test('a platform that cannot do it loses the transcript, not the note',
      () async {
    answerWith((_) => throw PlatformException(code: 'unavailable'));
    final controller = container.read(voiceTranscriptionProvider.notifier);

    expect(
      await controller.transcribe(messageId: 'm1', audioPath: '/tmp/a.m4a'),
      isNull,
    );
    expect(container.read(voiceTranscriptionProvider), isEmpty);
  });

  test('silence transcribes to nothing rather than to an empty bubble',
      () async {
    answerWith((_) => '   ');
    final controller = container.read(voiceTranscriptionProvider.notifier);

    expect(
      await controller.transcribe(messageId: 'm1', audioPath: '/tmp/a.m4a'),
      isNull,
    );
    expect(container.read(voiceTranscriptionProvider), isEmpty);
  });

  test('a deleted message takes its transcript with it', () async {
    answerWith((_) => 'gone soon');
    final controller = container.read(voiceTranscriptionProvider.notifier);
    await controller.transcribe(messageId: 'm1', audioPath: '/tmp/a.m4a');

    controller.forget('m1');

    expect(container.read(voiceTranscriptionProvider), isEmpty);
  });

  test('no plugin at all is the same quiet failure', () async {
    // Windows and web builds run the interface with no recogniser behind it.
    answerWith((_) => throw MissingPluginException());
    final controller = container.read(voiceTranscriptionProvider.notifier);

    expect(
      await controller.transcribe(messageId: 'm1', audioPath: '/tmp/a.m4a'),
      isNull,
    );
  });

  test('simultaneous taps share the same native transcription', () async {
    final pending = Completer<String>();
    answerWith((_) => pending.future);
    final controller = container.read(voiceTranscriptionProvider.notifier);
    final first =
        controller.transcribe(messageId: 'm1', audioPath: '/tmp/a.m4a');
    final second =
        controller.transcribe(messageId: 'm1', audioPath: '/tmp/a.m4a');
    expect(controller.isRunning('m1'), isTrue);
    pending.complete('one result');
    expect(await first, 'one result');
    expect(await second, 'one result');
    expect(calls, hasLength(1));
    expect(controller.isRunning('m1'), isFalse);
  });

  test('deleting during transcription cannot restore its private text',
      () async {
    final pending = Completer<String>();
    answerWith((_) => pending.future);
    final controller = container.read(voiceTranscriptionProvider.notifier);
    final result =
        controller.transcribe(messageId: 'm1', audioPath: '/tmp/a.m4a');
    controller.forget('m1');
    pending.complete('deleted');
    expect(await result, isNull);
    expect(container.read(voiceTranscriptionProvider), isEmpty);
  });
}
