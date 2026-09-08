import 'dart:typed_data';

import 'package:cubechat/features/chat/presentation/editor/photo_editor_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// A sticker put on a photo stays yours to move and take off.
///
/// It did not: the selection was dropped the moment the brush panel closed, so
/// the only way back to a sticker was to re-open the tab that made it. That is
/// a rule about this program's insides, and the person is looking at a picture
/// with a cat on it.
Uint8List _photo() {
  final image = img.Image(width: 400, height: 600);
  for (var y = 0; y < 600; y++) {
    for (var x = 0; x < 400; x++) {
      image.setPixelRgb(x, y, 60, 120, 90);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image));
}

Future<void> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2280);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: PhotoEditorScreen(source: _photo()),
    ),
  );
  // The source is decoded off the platform thread, so the first frame is a
  // spinner however many times it is pumped.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pumpAndSettle();
}

Future<void> _addSticker(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Draw'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('STICKER'));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byType(Image).first);
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 400)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a sticker is still reachable after the brush is put away',
      (tester) async {
    await _open(tester);
    await _addSticker(tester);

    // Close the brush. The sticker is on the picture and nothing else is open.
    await tester.tap(find.byTooltip('Draw'));
    await tester.pumpAndSettle();

    expect(
      find.byIcon(Icons.delete_rounded),
      findsOneWidget,
      reason: 'the panel slot carries what you can do to the selected layer',
    );
  });

  testWidgets('and can be taken off from there', (tester) async {
    await _open(tester);
    await _addSticker(tester);
    await tester.tap(find.byTooltip('Draw'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_rounded));
    await tester.pumpAndSettle();

    expect(
      find.byIcon(Icons.delete_rounded),
      findsNothing,
      reason: 'nothing is selected any more, so there is nothing to act on',
    );
  });

  testWidgets('an untouched picture offers nothing to act on', (tester) async {
    await _open(tester);
    expect(find.byIcon(Icons.delete_rounded), findsNothing);
  });
}
