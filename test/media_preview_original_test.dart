import 'dart:typed_data';

import 'package:cubechat/features/chat/presentation/media_preview_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The way out of the photo encoder.
///
/// The ordinary path downscales and re-encodes to fit a picture through
/// Bluetooth, which is the right trade for a snapshot and the wrong one for a
/// document photographed to be read. The preview carries the choice back to the
/// caller, which is what decides whether the asset's own file goes out.
///
/// A 1x1 PNG stands in for the photo: this screen only has to display it.
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
  Future<MediaPreviewResult?> open(
    WidgetTester tester, {
    required Future<void> Function(WidgetTester tester) act,
    String? initialCaption,
  }) async {
    MediaPreviewResult? result;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push<MediaPreviewResult>(
                MaterialPageRoute<MediaPreviewResult>(
                  builder: (_) => MediaPreviewScreen(
                    items: [_png],
                    initialCaption: initialCaption,
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await act(tester);
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('sending normally keeps the photo path', (tester) async {
    final result = await open(tester, act: (tester) async {
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    });

    expect(result, isNotNull);
    expect(result!.asFile, isFalse);
    expect(result.bytes, hasLength(1));
  });

  testWidgets('Original sends the file instead, and puts the brush away',
      (tester) async {
    final result = await open(tester, act: (tester) async {
      expect(find.byIcon(Icons.brush_rounded), findsOneWidget);
      await tester.tap(find.text('Original'));
      await tester.pumpAndSettle();
      expect(
        find.byIcon(Icons.brush_rounded),
        findsNothing,
        reason: 'editing a photo you are about to send untouched is a '
            'contradiction — the edit is the one thing that would be re-encoded',
      );
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    });

    expect(result!.asFile, isTrue);
  });
  testWidgets('keeps the caption composed in the picker', (tester) async {
    final result = await open(
      tester,
      initialCaption: 'Ready to send',
      act: (tester) async {
        await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      },
    );

    expect(result!.caption, 'Ready to send');
  });
}
