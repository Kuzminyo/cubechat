import 'package:cubechat/features/chat/data/circle_recorder.dart';
import 'package:cubechat/features/chat/presentation/widgets/circle_recorder_preview.dart';
import 'package:cubechat/features/chat/presentation/widgets/chat_input.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Recorder extends CircleRecorder {
  int flips = 0;
  @override
  Future<void> flipLens() async {
    flips++;
    notifyListeners();
  }
}

Widget host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('cancel, send and flip remain tappable above the keyboard',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final recorder = _Recorder();
    var cancelled = 0;
    var sent = 0;
    await tester.pumpWidget(
      host(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            viewInsets: EdgeInsets.only(bottom: 300),
          ),
          child: CircleRecorderPreview(
            recorder: recorder,
            locked: false,
            hint: 'Відпустіть для надсилання',
            cancelLabel: 'Скасувати',
            onSend: () => sent++,
            onCancel: () => cancelled++,
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.flip_camera_ios_rounded));
    await tester.tap(find.text('СКАСУВАТИ'));
    await tester.tap(find.byKey(const ValueKey('circle-send')));
    expect(recorder.flips, 1);
    expect(cancelled, 1);
    expect(sent, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    recorder.dispose();
  });

  testWidgets('slide cancel consumes the hold so release cannot send',
      (tester) async {
    var starts = 0;
    var cancels = 0;
    var sends = 0;
    await tester.pumpWidget(
      host(
        ChatInput(
          hint: 'Message',
          sendTooltip: 'Send',
          onSend: (_) {},
          recording: false,
          onRecordStart: () => starts++,
          onRecordStop: () => sends++,
          onRecordCancel: () => cancels++,
          onRecordLock: () {},
        ),
      ),
    );
    final gesture = await tester
        .startGesture(tester.getCenter(find.byIcon(Icons.mic_rounded)));
    await tester.pump(const Duration(milliseconds: 120));
    await gesture.moveBy(const Offset(-100, 0));
    await gesture.moveBy(const Offset(-10, 0));
    await gesture.up();
    expect(starts, 1);
    expect(cancels, 1);
    expect(sends, 0);
  });
  testWidgets('locking a held recording consumes release but next tap sends',
      (tester) async {
    var locked = false;
    var locks = 0;
    var sends = 0;
    var cancels = 0;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, setState) => ChatInput(
            hint: 'Message',
            sendTooltip: 'Send',
            onSend: (_) {},
            recordLocked: locked,
            onRecordStart: () {},
            onRecordStop: () => sends++,
            onRecordCancel: () => cancels++,
            onRecordLock: () {
              locks++;
              setState(() => locked = true);
            },
          ),
        ),
      ),
    );
    final gesture = await tester
        .startGesture(tester.getCenter(find.byIcon(Icons.mic_rounded)));
    await tester.pump(const Duration(milliseconds: 120));
    await gesture.moveBy(const Offset(0, -70));
    await tester.pump();
    await gesture.up();
    expect(locks, 1);
    expect(sends, 0);
    expect(cancels, 0);
    await tester.tap(find.byIcon(Icons.send_rounded));
    expect(sends, 1);
  });
  testWidgets('recording controls preserve keyboard focus and shrink above it',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final recorder = _Recorder();
    final focus = FocusNode();
    var overlay = false;
    var keyboard = 0.0;
    late StateSetter update;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return MediaQuery(
              data: MediaQueryData(
                size: const Size(390, 844),
                viewInsets: EdgeInsets.only(bottom: keyboard),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: TextField(focusNode: focus),
                  ),
                  if (overlay)
                    CircleRecorderPreview(
                      recorder: recorder,
                      locked: true,
                      hint: 'Hold',
                      cancelLabel: 'Cancel',
                      onSend: () {},
                      onCancel: () {},
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
    await tester.showKeyboard(find.byType(TextField));
    update(() => overlay = true);
    await tester.pump();
    final large =
        tester.getRect(find.byKey(const ValueKey('circle-camera-preview')));
    update(() => keyboard = 300);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    final compact =
        tester.getRect(find.byKey(const ValueKey('circle-camera-preview')));
    expect(compact.width, lessThan(large.width));
    expect(compact.center.dx, closeTo(195, .01));
    await tester.tap(find.byIcon(Icons.flip_camera_ios_rounded));
    await tester.pump();
    expect(recorder.flips, 1);
    expect(focus.hasFocus, true);
    expect(tester.testTextInput.isVisible, true);
    expect(
      tester.getRect(find.byKey(const ValueKey('circle-cancel'))).bottom,
      lessThan(544),
    );
    await tester.pumpWidget(const SizedBox());
    recorder.dispose();
    focus.dispose();
  });
}
