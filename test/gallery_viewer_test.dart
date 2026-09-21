import 'package:cubechat/features/chat/presentation/widgets/gallery_viewer.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const photos = MethodChannel('com.fluttercandies/photo_manager');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(photos, (_) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(photos, null);
  });

  testWidgets('viewer counter uses the complete album count', (tester) async {
    final assets = List<AssetEntity>.generate(
      4,
      (index) => AssetEntity(
        id: 'photo-$index',
        typeInt: AssetType.image.index,
        width: 1080,
        height: 1920,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: GalleryViewer(
          assets: assets,
          initialIndex: 3,
          totalCount: 6502,
          isSelected: (_) => false,
          orderOf: (_) => 0,
          onToggle: (_) {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('4/6502'), findsOneWidget);
    expect(find.text('4/4'), findsNothing);
  });
}
