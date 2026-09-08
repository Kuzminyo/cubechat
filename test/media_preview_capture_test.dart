import 'dart:typed_data';

import 'package:cubechat/core/widgets/view_once_icon.dart';
import 'package:cubechat/features/chat/presentation/media_preview_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A picture of the send screen, so a layout change is looked at rather than
/// reasoned about.
///
/// The top row lost both its words — two chips each carrying one left
/// "Оригінал" running off the edge of a 360-point screen, which reads as a bug
/// rather than as a label — and gained the brush, which was down in the caption
/// island. This capture is what says whether the result is balanced.
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

void main() {
  testWidgets('the top row holds three round controls and no words',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaPreviewScreen(items: [_png], allowViewOnce: true),
      ),
    );
    await tester.pumpAndSettle();

    // Brush, view-once, original — the three that change the picture or what
    // the recipient gets.
    expect(find.byIcon(Icons.brush_rounded), findsOneWidget);
    // Drawn rather than an icon-font glyph: nothing in the sets is both a bomb
    // and a numeral, and view-once has to say both.
    expect(find.byType(ViewOnceIcon), findsOneWidget);
    expect(find.byIcon(Icons.file_copy_rounded), findsOneWidget);

    // And the words are gone from the row itself.
    final t = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(t.mediaSendOriginal), findsNothing,
        reason: 'the label lives in a tooltip now; on the row it was cropped');
    expect(find.text(t.viewOnceSendLabel), findsNothing);
  });

  testWidgets('every control clears the right edge', (tester) async {
    // 360 points is the screen the label was being cut off on.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaPreviewScreen(items: [_png], allowViewOnce: true),
      ),
    );
    await tester.pumpAndSettle();

    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    final marks = <Finder>[
      find.byIcon(Icons.brush_rounded),
      find.byType(ViewOnceIcon),
      find.byIcon(Icons.file_copy_rounded),
    ];
    for (final mark in marks) {
      final r = tester.getRect(mark);
      expect(r.right, lessThan(width),
          reason: 'a chip pressed against the edge reads as cropped');
      expect(r.left, greaterThan(0));
    }
  });
}
