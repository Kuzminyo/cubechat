import 'package:cubechat/features/chat/presentation/widgets/empty_chat_greeting.dart';
import 'package:cubechat/features/stickers/data/sticker_pack.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:cubechat/l10n/app_localizations_en.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// An empty chat greets you the way Telegram's does: a panel with Kubi
/// waving, and a tap on him sends that wave as the first message.
void main() {
  final t = AppLocalizationsEn();

  Future<void> pump(
    WidgetTester tester, {
    VoidCallback? onGreet,
    bool waiting = false,
  }) =>
      tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: EmptyChatGreeting(onGreet: onGreet, waiting: waiting),
          ),
        ),
      );

  String asset(WidgetTester tester) {
    final image = tester.widget<Image>(find.byKey(EmptyChatGreeting.kubiKey));
    final provider = image.image is ResizeImage
        ? (image.image as ResizeImage).imageProvider
        : image.image;
    return (provider as AssetImage).assetName;
  }

  testWidgets('Kubi waves, and a tap on him sends the greeting',
      (tester) async {
    var greeted = 0;
    await pump(tester, onGreet: () => greeted++);
    expect(find.text(t.chatEmptyTitle), findsOneWidget);
    expect(find.text(t.chatEmptyGreetHint), findsOneWidget);
    expect(asset(tester), StickerPack.animation('cat-wave'));
    await tester.tap(find.byKey(EmptyChatGreeting.kubiKey));
    expect(greeted, 1);
  });

  testWidgets('before the channel is ready he sits, and says why',
      (tester) async {
    var greeted = 0;
    await pump(tester, onGreet: () => greeted++, waiting: true);
    expect(find.text(t.chatEmptyHandshaking), findsOneWidget);
    expect(asset(tester), StickerPack.still('cat-wave'));
    await tester.tap(find.byKey(EmptyChatGreeting.kubiKey));
    expect(greeted, 0);
  });
}
