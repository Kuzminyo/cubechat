import 'dart:async';
import 'dart:io';

import 'package:cubechat/features/chat/data/voice_transcription_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chat/presentation/widgets/message_bubble.dart';
import 'package:cubechat/features/chat/presentation/widgets/transcription_button.dart';
import 'package:cubechat/features/chat/presentation/widgets/video_bubble.dart';
import 'package:cubechat/features/chat/presentation/widgets/voice_bubble.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transcription extends VoiceTranscriptionController {
  final pending = Completer<String?>();
  int calls = 0;
  String? path;

  @override
  Future<String?> transcribe({
    required String messageId,
    required String audioPath,
    String? localeId,
  }) async {
    calls++;
    path = audioPath;
    final text = await pending.future;
    if (text != null) state = {...state, messageId: text};
    return text;
  }
}

void main() {
  late Directory dir;
  late String path;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('transcription_ui_');
    path = '${dir.path}/note.m4a';
    File(path).writeAsBytesSync([0, 1, 2, 3]);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> pump(WidgetTester tester, _Transcription controller,
      {bool circle = false, bool missing = false, bool text = false}) async {
    tester.view.physicalSize = const Size(960, 1920);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [voiceTranscriptionProvider.overrideWith(() => controller)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MessageBubble(
            chatId: 'peer',
            message: Message(
              id: 'note',
              chatId: 'peer',
              text: text
                  ? 'Hello world'
                  : circle
                      ? 'video/mp4'
                      : '',
              sentAt: DateTime(2026, 9, 21),
              isMine: true,
              kind: text
                  ? MessageKind.text
                  : circle
                      ? MessageKind.file
                      : MessageKind.audio,
              audioPath: circle || missing ? null : path,
              audioDurationMs: 1500,
              filePath: circle ? path : null,
              fileName: circle ? Message.circleFileName : null,
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  for (final circle in [false, true]) {
    testWidgets(
        '${circle ? 'circle' : 'audio'} button transcribes once and shows text',
        (tester) async {
      final controller = _Transcription();
      await pump(tester, controller, circle: circle);
      final button = find.byType(TranscriptionButton);
      expect(button, findsOneWidget);
      final rect = tester.getRect(button);
      expect(tester.takeException(), isNull);
      final media =
          tester.getRect(find.byType(circle ? VideoBubble : VoiceBubble));
      expect(rect.right, lessThanOrEqualTo(media.right));
      if (circle) {
        expect(rect.size, const Size(44, 44));
        // Beside the 200-point circle, not on it: ours, so on its left, low
        // down, with six points between.
        expect(media.size, const Size(250, 200));
        expect(rect.left, media.left);
        expect(rect.bottom, media.bottom);
      } else {
        // A slot as tall as the play button, and on its centre line.
        expect(rect.size, const Size(36, 36));
        final play = tester.getRect(find.byIcon(Icons.play_arrow_rounded));
        expect((rect.center.dy - play.center.dy).abs(), lessThan(0.5));
        expect(rect.left, greaterThan(media.center.dx));
      }
      await tester.tap(button);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      if (circle) {
        // Gone: slid out to the left of our circle and faded.
        await tester.pump(const Duration(milliseconds: 500));
        final opacity = tester.widget<AnimatedOpacity>(find.descendant(
          of: button,
          matching: find.byType(AnimatedOpacity),
        ));
        expect(opacity.opacity, 0);
        final drawn = tester.getRect(
          find.descendant(of: button, matching: find.byType(Tooltip)),
        );
        expect(drawn.left, lessThan(rect.left - 40));
      } else {
        await tester.tap(button);
      }
      expect(controller.calls, 1);
      expect(controller.path, path);
      controller.pending.complete('Recognized words');
      await tester.pump();
      await tester.pump();
      expect(find.text('Recognized words'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('with the text there, the button folds it away and back',
      (tester) async {
    final controller = _Transcription();
    await pump(tester, controller);
    await tester.tap(find.byType(TranscriptionButton));
    controller.pending.complete('Recognized words');
    await tester.pump();
    await tester.pump();
    expect(find.text('Recognized words'), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsOneWidget,
        reason: 'the "→A" turns into "↑" once there is text to hide');

    await tester.tap(find.byType(TranscriptionButton));
    await tester.pump();
    expect(find.text('Recognized words'), findsNothing);
    expect(find.text('→A'), findsOneWidget);

    await tester.tap(find.byType(TranscriptionButton));
    await tester.pump();
    expect(find.text('Recognized words'), findsOneWidget);
    expect(controller.calls, 1, reason: 'the same text, not a second run');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failure remains visible and permits retry', (tester) async {
    final controller = _Transcription();
    await pump(tester, controller);
    await tester.tap(find.byType(TranscriptionButton));
    controller.pending.complete(null);
    await tester.pump();
    await tester.pump();
    final context = tester.element(find.byType(TranscriptionButton));
    expect(find.text(AppLocalizations.of(context).chatTranscribeFailed),
        findsOneWidget);
    await tester.tap(find.byType(TranscriptionButton));
    await tester.pump();
    expect(controller.calls, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ordinary text exposes Translate in the long-press menu',
      (tester) async {
    await pump(tester, _Transcription(), text: true);
    final context = tester.element(find.byType(MessageBubble));
    final label = AppLocalizations.of(context).chatTranslateAction;
    await tester.longPress(find.text('Hello world'));
    await tester.pumpAndSettle();
    expect(find.text(label), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('missing audio cannot start recognition', (tester) async {
    final controller = _Transcription();
    await pump(tester, controller, missing: true);
    await tester.tap(find.byType(TranscriptionButton));
    expect(controller.calls, 0);
    await tester.pumpWidget(const SizedBox());
  });
}
