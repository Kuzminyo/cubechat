import 'package:cubechat/core/routing/app_shell.dart';
import 'package:cubechat/core/widgets/floating_glass.dart';
import 'package:cubechat/features/airdrop/data/airdrop_controller.dart';
import 'package:cubechat/features/airdrop/domain/airdrop_transfer.dart';
import 'package:cubechat/features/airdrop/presentation/airdrop_banner.dart';
import 'package:cubechat/features/airdrop/presentation/airdrop_navigation.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAirDrop extends AirDropController {
  _FakeAirDrop(this.initial);

  final AirDropState initial;
  final accepted = <String>[];

  @override
  AirDropState build() => initial;

  @override
  Future<void> accept(String id) async => accepted.add(id);
}

final _request = AirDropTransfer(
  id: 'aa' * 16,
  peerHex: 'bb' * 32,
  peerName: 'Жека',
  direction: AirDropDirection.incoming,
  phase: AirDropPhase.waiting,
  createdAt: DateTime(2026, 9, 22),
  files: const [
    AirDropFile(mediaIdHex: 'f0', name: 'a.jpg', size: 10, mime: 'image/jpeg'),
  ],
);

void main() {
  Future<_FakeAirDrop> pump(
    WidgetTester tester, {
    bool onAirDropPage = false,
  }) async {
    final airdrop = _FakeAirDrop(AirDropState(transfers: [_request]));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          airdropControllerProvider.overrideWith(() => airdrop),
          airdropPageOnScreenProvider.overrideWith((ref) => onAirDropPage),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('uk'),
          home: Scaffold(body: AirDropRequestBanner(onOpen: () {})),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return airdrop;
  }

  testWidgets('a request shows over whatever is open and can be accepted',
      (tester) async {
    final airdrop = await pump(tester);
    expect(find.textContaining('Жека', findRichText: true), findsOneWidget);
    await tester.tap(find.text('Прийняти'));
    expect(airdrop.accepted, [_request.id]);
  });

  group('on a phone, the card floats', () {
    // 1080x2340 at 2.75 — a 392x851 logical screen with a 24 px gesture bar.
    Future<Rect> place(WidgetTester tester, {double keyboard = 0}) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      tester.view.padding = const FakeViewPadding(bottom: 66);
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard * 2.75);
      addTearDown(tester.view.reset);
      final airdrop = _FakeAirDrop(AirDropState(transfers: [_request]));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [airdropControllerProvider.overrideWith(() => airdrop)],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('uk'),
            home: Scaffold(
              resizeToAvoidBottomInset: false,
              body: Stack(
                fit: StackFit.expand,
                children: [
                  const Positioned(top: 72, left: 20, child: Text('Поблизу')),
                  AirDropRequestOverlay(onOpen: () {}),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester.getRect(find.byType(FloatingGlass));
    }

    testWidgets('above the tab bar, clear of the page title', (tester) async {
      final card = await place(tester);
      final context = tester.element(find.byType(AirDropRequestOverlay));
      // widget_test.dart pins barTop to the capsule's real top edge.
      final barTop = 2340 / 2.75 - AppShell.barTop(context);
      expect(card.bottom, lessThanOrEqualTo(barTop - 4));
      final title = tester.getRect(find.text('Поблизу'));
      expect(card.top, greaterThan(title.bottom));
    });

    testWidgets('above the keyboard and a single-line composer on it',
        (tester) async {
      const keyboard = 300.0;
      final card = await place(tester, keyboard: keyboard);
      // The chat composer's resting height (chat_screen.dart's
      // _initialComposerGuess).
      expect(card.bottom, lessThanOrEqualTo(2340 / 2.75 - keyboard - 76));
      expect(card.top, greaterThan(0));
    });
  });

  testWidgets('not over the AirDrop page, which already shows it',
      (tester) async {
    await pump(tester, onAirDropPage: true);
    expect(find.text('Прийняти'), findsNothing);
  });
}
