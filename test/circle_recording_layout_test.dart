import 'dart:io';
import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:cubechat/features/chat/data/circle_recorder.dart';
import 'package:cubechat/features/chat/presentation/widgets/circle_recorder_preview.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

class _Camera extends CameraController {
  _Camera()
      : super(
            const CameraDescription(
                name: 'fixture',
                lensDirection: CameraLensDirection.front,
                sensorOrientation: 90),
            ResolutionPreset.medium) {
    value =
        value.copyWith(isInitialized: true, previewSize: const Size(640, 480));
  }
  @override
  Widget buildPreview() => const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
              colors: [Color(0xFFB8C5AD), Color(0xFF6C8266)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight),
        ),
        child: Center(
            child: Icon(Icons.person_rounded,
                size: 260, color: Color(0xFF374D3E))),
      );
}

class _Recorder extends CircleRecorder {
  final preview = _Camera();
  @override
  CameraController get camera => preview;
  @override
  bool get isReady => true;
  @override
  Duration get elapsed => const Duration(seconds: 12);
  @override
  double get progress => .2;
}

void main() {
  for (final width in [320.0, 390.0]) {
    testWidgets(
        'recording layout has separate preview and touch targets at $width px',
        (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final recorder = _Recorder();
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('uk'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: RepaintBoundary(
            key: boundary,
            child: Scaffold(
              body: Stack(
                fit: StackFit.expand,
                children: [
                  const DecoratedBox(
                      decoration: BoxDecoration(
                          gradient: LinearGradient(
                              colors: [Color(0xFF183824), Color(0xFF386344)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight))),
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 80, 20, 100),
                      child: Column(
                        children: List.generate(
                          6,
                          (i) => Align(
                            alignment: i.isEven
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                                width: 210,
                                height: 58,
                                margin: const EdgeInsets.only(bottom: 22),
                                decoration: BoxDecoration(
                                    color: i.isEven
                                        ? const Color(0xFF7FAF91)
                                        : const Color(0xFF305B40),
                                    borderRadius: BorderRadius.circular(18))),
                          ),
                        ),
                      ),
                    ),
                  ),
                  CircleRecorderPreview(
                      recorder: recorder,
                      locked: true,
                      hint: 'Відпустіть для надсилання',
                      cancelLabel: 'Скасувати',
                      onSend: () {},
                      onCancel: () {}),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      final disc =
          tester.getRect(find.byKey(const ValueKey('circle-camera-preview')));
      final flip = tester.getRect(find.byKey(const ValueKey('circle-flip')));
      final cancel =
          tester.getRect(find.byKey(const ValueKey('circle-cancel')));
      expect(disc.width, closeTo(width * .78 + 16, .01));
      expect(disc.overlaps(flip), false);
      expect(disc.overlaps(cancel), false);
      expect(cancel.width, greaterThanOrEqualTo(48));
      expect(cancel.height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('CAPTURE_RECORDING') && width == 390) {
        final render = boundary.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await render.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
                  'D:/projects/cubechat/design-previews/circle-recording-fix/preview.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
      recorder.dispose();
    });
  }
}
