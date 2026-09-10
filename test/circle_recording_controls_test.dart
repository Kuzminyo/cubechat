import 'package:cubechat/features/chat/data/circle_recorder.dart';
import 'package:cubechat/features/chat/presentation/widgets/circle_recorder_preview.dart';
import 'package:cubechat/features/chat/presentation/widgets/chat_input.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Recorder extends CircleRecorder {
  int flips = 0;
  bool changing = false;
  @override
  bool get isFlipping => changing;
  void setChanging(bool value) {
    changing = value;
    notifyListeners();
  }

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
  testWidgets(
      'starting a circle keeps the same editable text and input connection',
      (tester) async {
    var recording = false;
    late StateSetter update;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return ChatInput(
              hint: 'Message',
              sendTooltip: 'Send',
              onSend: (_) {},
              onAttach: () {},
              recordMode: RecordMode.circle,
              recording: recording,
              onRecordStart: () {},
              onRecordStop: () {},
              onRecordCancel: () {},
            );
          },
        ),
      ),
    );
    await tester.showKeyboard(find.byType(TextField));
    final before = tester.state<EditableTextState>(find.byType(EditableText));
    expect(tester.testTextInput.isVisible, isTrue);
    update(() => recording = true);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.state<EditableTextState>(find.byType(EditableText)),
      same(before),
    );
    expect(before.widget.focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
  });

  testWidgets('sensor transition turns sideways and settles upright',
      (tester) async {
    final recorder = _Recorder();
    await tester.pumpWidget(
      host(
        CircleRecorderPreview(
          recorder: recorder,
          locked: true,
          hint: '',
          cancelLabel: 'Cancel',
          onSend: () {},
          onCancel: () {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    recorder.setChanging(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final transform = tester
        .widget<Transform>(find.byKey(const ValueKey('circle-flip-transform')))
        .transform;
    expect(transform.entry(0, 0), lessThan(1));
    expect(transform.entry(1, 1), 1);
    recorder.setChanging(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final settled = tester
        .widget<Transform>(find.byKey(const ValueKey('circle-flip-transform')))
        .transform;
    expect(settled.entry(0, 0), 1);
    await tester.pumpWidget(const SizedBox());
    recorder.dispose();
  });

  testWidgets('the disc turns all the way over rather than back the way it came',
      (tester) async {
    // The first version rotated to ninety degrees and reversed, which is a card
    // shown and withdrawn — the picture left and returned on the same face. A
    // flip is one continuous half revolution: the old lens going in, the new
    // one coming out. Past the edge the outer rotation is showing the back of
    // the picture, so the child carries a second half turn to cancel the
    // mirroring; both together is what keeps the face upright and unmirrored.
    final recorder = _Recorder();
    await tester.pumpWidget(
      host(
        CircleRecorderPreview(
          recorder: recorder,
          locked: true,
          hint: '',
          cancelLabel: 'Cancel',
          onSend: () {},
          onCancel: () {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    Matrix4 outer() => tester
        .widget<Transform>(find.byKey(const ValueKey('circle-flip-transform')))
        .transform;

    recorder.setChanging(true);
    await tester.pump();
    // All the way to the edge and held there: the sensor has not come back, and
    // opening on a texture that has not restarted is the thing this waits for.
    await tester.pump(const Duration(milliseconds: 400));
    expect(outer().entry(0, 0), closeTo(0, 0.05),
        reason: 'edge-on is a cosine of zero, and it stays there while the '
            'lens is still changing');

    recorder.setChanging(false);
    // A bare pump first, to deliver the change and let the second half start.
    // A pump with a duration advances the clock and *then* builds, so the time
    // would be spent before the controller had begun.
    await tester.pump();
    // Into the second half, past the edge, where the counter-turn has to be
    // doing its work.
    await tester.pump(const Duration(milliseconds: 120));
    expect(outer().entry(0, 0), lessThan(0),
        reason: 'past ninety degrees the outer rotation is negative, which is '
            'the far side of the turn rather than the way it came in');

    await tester.pump(const Duration(milliseconds: 400));
    expect(outer().entry(0, 0), 1, reason: 'flat again, and upright');
    expect(outer().entry(1, 1), 1, reason: 'never rolled onto its head');

    await tester.pumpWidget(const SizedBox());
    recorder.dispose();
  });

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
