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

  testWidgets('not over the AirDrop page, which already shows it',
      (tester) async {
    await pump(tester, onAirDropPage: true);
    expect(find.text('Прийняти'), findsNothing);
  });
}
