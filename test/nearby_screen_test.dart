import 'package:cubechat/core/routing/branch_pager.dart';
import 'package:cubechat/features/airdrop/presentation/airdrop_navigation.dart';
import 'package:cubechat/features/peers/presentation/nearby_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The real pages start the Bluetooth scanner and read Hive; the shell is
  // what is under test, so it gets three labels instead.
  Future<ProviderContainer> pump(WidgetTester tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('uk'),
          home: Scaffold(
            body: NearbyScreen(
              pages: [Text('page 0'), Text('page 1'), Text('page 2')],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('the island shows the three parts and switches between them',
      (tester) async {
    final c = await pump(tester);
    expect(find.text('Поблизу'), findsOneWidget);
    expect(find.text('AirDrop'), findsOneWidget);
    expect(find.text('Файли'), findsOneWidget);
    expect(find.text('page 0').hitTestable(), findsOneWidget);

    await tester.tap(find.text('AirDrop'));
    await tester.pumpAndSettle();
    expect(find.text('page 1').hitTestable(), findsOneWidget);
    expect(find.text('page 0').hitTestable(), findsNothing);
    expect(c.read(branchPagersProvider)[kNearbyBranch]?.index, 1);
    expect(c.read(airdropPageOnScreenProvider), isTrue);
  });

  testWidgets('the tab swipe steps through the pages before the next tab',
      (tester) async {
    final c = await pump(tester);
    final pager = c.read(branchPagersProvider)[kNearbyBranch]!;
    expect(pager.count, 3);
    expect(pager.canStep(-1), isFalse, reason: 'left of Nearby is a tab');
    pager.step(1);
    await tester.pumpAndSettle();
    c.read(branchPagersProvider)[kNearbyBranch]!.step(1);
    await tester.pumpAndSettle();
    expect(find.text('page 2').hitTestable(), findsOneWidget);
    expect(c.read(branchPagersProvider)[kNearbyBranch]!.canStep(1), isFalse);
  });

  testWidgets('a request from elsewhere brings AirDrop to the front',
      (tester) async {
    final c = await pump(tester);
    c.read(nearbyPageRequestProvider.notifier).state = kAirDropPage;
    await tester.pumpAndSettle();
    expect(find.text('page 1').hitTestable(), findsOneWidget);
    expect(c.read(nearbyPageRequestProvider), isNull);
  });

  testWidgets(
      'backgrounding the AirDrop page turns it off, and resuming turns it '
      'back on', (tester) async {
    final c = await pump(tester);
    addTearDown(
      () => tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed),
    );

    await tester.tap(find.text('AirDrop'));
    await tester.pumpAndSettle();
    expect(c.read(airdropPageOnScreenProvider), isTrue);

    // A glance at the notification shade is not leaving — only paused/hidden
    // and resumed are meant to move the flag.
    tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(c.read(airdropPageOnScreenProvider), isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(c.read(airdropPageOnScreenProvider), isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(c.read(airdropPageOnScreenProvider), isTrue);
  });
}
