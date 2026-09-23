import 'package:cubechat/core/routing/branch_pager.dart';
import 'package:cubechat/core/widgets/section_switch.dart';
import 'package:cubechat/features/airdrop/data/airdrop_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_history_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_lane_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_receive_controller.dart';
import 'package:cubechat/features/airdrop/presentation/airdrop_navigation.dart';
import 'package:cubechat/features/files/data/file_transfer_controller.dart';
import 'package:cubechat/features/peers/presentation/nearby_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The three controllers AirDropPage and _FilesPage reach for, stood in with
/// no Hive/messaging underneath — this file is about the shell's layout, not
/// about AirDrop or file-transfer behaviour, which have their own tests.
class _EmptyAirDrop extends AirDropController {
  @override
  AirDropState build() => const AirDropState();
}

class _EmptyHistory extends AirDropHistoryController {
  @override
  List<AirDropHistoryEntry> build() => const [];

  @override
  Future<void> save(List<AirDropHistoryEntry> entries) async {}
}

class _DefaultReceive extends AirDropReceiveController {
  @override
  AirDropReceive build() => const AirDropReceive();
}

class _DefaultLane extends AirDropLaneController {
  @override
  AirDropLane build() => AirDropLane.auto;
}

class _EmptyTransfers extends FileTransferController {
  @override
  Map<String, FileTransferTask> build() => const {};
}

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

  // The real three pages, for the layout question the stand-ins above can't
  // answer: whether a page still draws its own display title next to the
  // shell's.
  Future<void> pumpReal(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          airdropControllerProvider.overrideWith(_EmptyAirDrop.new),
          airdropHistoryProvider.overrideWith(_EmptyHistory.new),
          airdropReceiveProvider.overrideWith(_DefaultReceive.new),
          airdropLaneProvider.overrideWith(_DefaultLane.new),
          fileTransferControllerProvider.overrideWith(_EmptyTransfers.new),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('uk'),
          home: Scaffold(body: NearbyScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
      'the section header sits above the switch, once, the way Contacts does '
      'it', (tester) async {
    await pumpReal(tester);

    // Exactly one title and one subtitle — keyed, because the switch below
    // reuses "Поблизу" as its own first label.
    expect(find.byKey(const Key('nearby-section-title')), findsOneWidget);
    expect(find.byKey(const Key('nearby-section-subtitle')), findsOneWidget);
    final titleTop =
        tester.getTopLeft(find.byKey(const Key('nearby-section-title'))).dy;
    final switchTop = tester.getTopLeft(find.byType(SectionSwitch)).dy;
    expect(titleTop, lessThan(switchTop));
  });

  testWidgets(
      'switching to AirDrop or Files keeps the one header and adds no second '
      'display title', (tester) async {
    await pumpReal(tester);

    // All three pages are already mounted offstage (see NearbyScreen's
    // Offstage stack), so a page that still drew its own title would show up
    // here even before it is the visible one.
    expect(find.text('AirDrop'), findsOneWidget, reason: 'switch label only');
    expect(find.text('Файли'), findsOneWidget, reason: 'switch label only');

    await tester.tap(find.text('AirDrop'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('nearby-section-title')), findsOneWidget);
    expect(find.text('AirDrop'), findsOneWidget);

    await tester.tap(find.text('Файли'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('nearby-section-title')), findsOneWidget);
    expect(find.text('Файли'), findsOneWidget);
  });

  testWidgets('the island shows the three parts and switches between them',
      (tester) async {
    final c = await pump(tester);
    // Two: the shell's own section title above the switch, plus the switch's
    // first label, which reuses the same word — see the header/switch test
    // above for the one that tells those two apart.
    expect(find.text('Поблизу'), findsNWidgets(2));
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
