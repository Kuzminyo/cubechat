import 'dart:io';

import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chat/presentation/widgets/message_bubble.dart';
import 'package:cubechat/features/chat/presentation/widgets/video_bubble.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A clip is drawn the way a picture is.
///
/// Reported off a screenshot of a conversation holding both: the photo ran to
/// the rounded corners of its bubble and the clip sat in fourteen points of
/// tinted glass on every side, inside a second radius of its own — two column
/// widths in one chat, and a sliver of bubble showing in each corner of the
/// clip. The photo bubble removed exactly that frame a release ago; this locks
/// the same answer for the other medium.
///
/// Measured rather than captured. A golden answers "these pixels moved"; the
/// questions here are "is the clip as wide as the photo", "is there anything
/// drawn between it and the corner", and "can a portrait clip grow taller than
/// a portrait photo is allowed to".
Message _clip({required String name, bool mine = true}) => Message(
      id: 'clip',
      chatId: 'peer',
      text: 'video/mp4',
      sentAt: DateTime(2026, 9, 10, 10, 11),
      isMine: mine,
      kind: MessageKind.file,
      fileName: name,
      filePath: _path,
      fileBytes: 4,
    );

late String _path;

/// The width a photo would be drawn at on the screen the test is running on.
///
/// Read out of the same helper the picture reads, from a context under the same
/// MediaQuery — so this is the number the photo bubble uses, not a copy of the
/// arithmetic that could drift away from it.
late double _photoWidth;

/// Offstage keeps the platform video decoder out of a decoration-only check:
/// nothing here taps, and the player is opened on tap.
Future<void> _pump(WidgetTester tester, Message message) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              _photoWidth = photoBubbleWidth(context);
              return Offstage(
                child: MessageBubble(message: message, chatId: 'peer'),
              );
            },
          ),
        ),
      ),
    ),
  );
}

/// The one box in the bubble that carries the fill, the border and the inset.
Container _surface(WidgetTester tester, Finder of) {
  final boxes = tester.widgetList<Container>(
    find.ancestor(of: of, matching: find.byType(Container, skipOffstage: false)),
  );
  return boxes.firstWhere((box) => box.decoration is BoxDecoration);
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cubechat_clip_layout_');
    _path = '${dir.path}${Platform.pathSeparator}clip.mp4';
    File(_path).writeAsBytesSync(<int>[0, 1, 2, 3]);
  });

  tearDown(() async {
    await Future<void>.delayed(Duration.zero);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  testWidgets('a clip has no inset and no frame around it', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await _pump(tester, _clip(name: 'clip.mp4'));
    final surface = _surface(
      tester,
      find.byType(VideoBubble, skipOffstage: false),
    );
    final decoration = surface.decoration! as BoxDecoration;

    expect(
      surface.padding,
      EdgeInsets.zero,
      reason: 'fourteen points of glass on every side is the frame a photo '
          'stopped drawing, and it made the bubble 28 points wider than the '
          'clip inside it',
    );
    expect(
      decoration.border,
      isNull,
      reason: 'a border paints inside the container and is then clipped at the '
          'outer radius, so it comes apart in every corner — the same reason '
          'the photo bubble dropped its own',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a clip and a photo are one column, not two', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await _pump(tester, _clip(name: 'clip.mp4'));
    final clip = tester.getRect(find.byType(VideoBubble, skipOffstage: false));

    expect(clip.width, closeTo(_photoWidth, 0.5));
    expect(
      _bubbleWidth(tester, find.byType(VideoBubble, skipOffstage: false)),
      closeTo(_photoWidth, 0.5),
      reason: 'the bubble is the width of the media, the way a photo bubble '
          'is; a clip used to be the media plus two insets',
    );
    expect(
      clip.height,
      lessThanOrEqualTo(_photoWidth * 1.25 + 0.5),
      reason: 'a portrait clip at the 300-point ceiling was 533 points tall — '
          'a bubble that fills a screen and has to be scrolled past. A photo '
          'has been capped at 1.25x its width since the panorama report',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the clock rides on the clip, not on a strip below it',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await _pump(tester, _clip(name: 'clip.mp4'));
    final clip = tester.getRect(find.byType(VideoBubble, skipOffstage: false));
    final clock = tester.getRect(find.text('10:11', skipOffstage: false));

    expect(
      clip.contains(clock.center),
      isTrue,
      reason: 'a strip of bubble under the clip carrying four characters is '
          'the frame this design removed, put back one edge at a time',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a circle keeps its own shape and its own footer',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await _pump(tester, _clip(name: VideoBubble.circleFileName));
    final circle = tester.getRect(
      find.byType(VideoBubble, skipOffstage: false),
    );
    final clock = tester.getRect(find.text('10:11', skipOffstage: false));

    expect(circle.width, VideoBubble.circleIdle);
    expect(
      circle.contains(clock.center),
      isFalse,
      reason: 'a rectangular pill in the corner of a round bubble hangs off '
          'the shape; the circle draws its own countdown instead',
    );

    await tester.pumpWidget(const SizedBox());
  });
}

/// How wide the painted bubble is around a piece of media.
double _bubbleWidth(WidgetTester tester, Finder media) => tester
    .getRect(
      find
          .ancestor(
            of: media,
            matching: find.byType(ClipRRect, skipOffstage: false),
          )
          .last,
    )
    .width;
