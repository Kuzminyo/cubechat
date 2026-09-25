import 'package:cubechat/core/routing/branch_pager.dart';
import 'package:cubechat/core/widgets/glass_card.dart';
import 'package:cubechat/core/widgets/section_switch.dart';
import 'package:cubechat/features/airdrop/data/airdrop_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_history_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_lane_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_receive_controller.dart';
import 'package:cubechat/features/airdrop/presentation/airdrop_navigation.dart';
import 'package:cubechat/features/files/data/file_transfer_controller.dart';
import 'package:cubechat/features/peers/data/peer_discovery_controller.dart';
import 'package:cubechat/features/peers/data/peripheral_controller.dart';
import 'package:cubechat/features/peers/models/discovered_peer.dart';
import 'package:cubechat/features/peers/presentation/nearby_screen.dart';
import 'package:cubechat/features/peers/presentation/peers_screen.dart';
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

class _NearbyPeer extends PeerDiscoveryController {
  @override
  PeerDiscoveryState build() => PeerDiscoveryState(
        status: PeerDiscoveryStatus.scanning,
        peers: [
          DiscoveredPeer(
            id: 'AA:BB:CC:DD:EE:FF',
            advertisedName: 'xoxoxo',
            rssi: -55,
            lastSeen: DateTime(2026, 9, 24),
          ),
        ],
      );

  @override
  Future<void> start() async {}

  @override
  Future<void> retuneScan() async {}
}

/// Not scanning, but still showing the same peer card — status idle with a
/// peer already found (as if the scan had already run once and stopped),
/// so the "not scanning" case doesn't fall into the empty-scanning radar's
/// own ~30fps timer, which never lets pumpAndSettle finish.
class _IdleWithPeer extends PeerDiscoveryController {
  @override
  PeerDiscoveryState build() => PeerDiscoveryState(
        status: PeerDiscoveryStatus.idle,
        peers: [
          DiscoveredPeer(
            id: 'AA:BB:CC:DD:EE:FF',
            advertisedName: 'xoxoxo',
            rssi: -55,
            lastSeen: DateTime(2026, 9, 24),
          ),
        ],
      );

  @override
  Future<void> start() async {}

  @override
  Future<void> retuneScan() async {}
}

class _Broadcasting extends PeripheralController {
  @override
  PeripheralState build() => const PeripheralState(
        status: PeripheralStatus.broadcasting,
        connectedCentralIds: {'central-1'},
      );
}

class _NotBroadcasting extends PeripheralController {
  @override
  PeripheralState build() => PeripheralState.initial;
}

class _FinishedTransfers extends FileTransferController {
  var cleared = 0;

  @override
  Future<void> clearFinished() async {
    cleared++;
  }


  @override
  Map<String, FileTransferTask> build() {
    final at = DateTime(2026, 9, 24);
    return {
      'file': FileTransferTask(
        id: 'file',
        chatId: '',
        fileName: 'photo.jpg',
        filePath: '',
        mime: 'image/jpeg',
        bytesTotal: 24,
        completedUnits: 1,
        totalUnits: 1,
        direction: FileTransferDirection.incoming,
        status: FileTransferStatus.completed,
        createdAt: at,
        updatedAt: at,
      ),
    };
  }
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
  // The scanning pulse repeats its glow animation forever while a scan is
  // running (parked only once UiActivity goes quiet, which the suite-wide
  // config disables), so pumpAndSettle never returns for it — same reason
  // "clear history..." below settles with a fixed pump instead.
  Future<void> pumpReal(
    WidgetTester tester, {
    List<Override> extraOverrides = const [],
    bool settle = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          airdropControllerProvider.overrideWith(_EmptyAirDrop.new),
          airdropHistoryProvider.overrideWith(_EmptyHistory.new),
          airdropReceiveProvider.overrideWith(_DefaultReceive.new),
          airdropLaneProvider.overrideWith(_DefaultLane.new),
          fileTransferControllerProvider.overrideWith(_EmptyTransfers.new),
          ...extraOverrides,
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('uk'),
          home: Scaffold(body: NearbyScreen()),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('subtitle follows the selected Nearby section', (tester) async {
    await pump(tester);
    const subtitle = Key('nearby-section-subtitle');
    String shown() => tester.widget<Text>(find.byKey(subtitle)).data!;
    expect(shown(), '\u041f\u0440\u0438\u0441\u0442\u0440\u043e\u0457 \u0443 \u0440\u0430\u0434\u0456\u0443\u0441\u0456 Bluetooth');
    await tester.tap(find.text('AirDrop'));
    await tester.pumpAndSettle();
    expect(shown(), '\u041e\u0431\u043c\u0456\u043d \u0444\u0430\u0439\u043b\u0430\u043c\u0438 \u0437 \u043b\u044e\u0434\u044c\u043c\u0438 \u043f\u043e\u0431\u043b\u0438\u0437\u0443');
    await tester.tap(find.text('\u0424\u0430\u0439\u043b\u0438'));
    await tester.pumpAndSettle();
    expect(shown(), '\u041d\u0430\u0434\u0456\u0441\u043b\u0430\u043d\u0456 \u0439 \u043e\u0442\u0440\u0438\u043c\u0430\u043d\u0456 \u0444\u0430\u0439\u043b\u0438');
    // And back: the subtitle is the selected page's, not the last one seen.
    await tester.tap(find.text('\u041f\u043e\u0431\u043b\u0438\u0437\u0443').last);
    await tester.pumpAndSettle();
    expect(shown(), '\u041f\u0440\u0438\u0441\u0442\u0440\u043e\u0457 \u0443 \u0440\u0430\u0434\u0456\u0443\u0441\u0456 Bluetooth');
  });

  testWidgets('clear history sits beside History instead of a detached row',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          airdropControllerProvider.overrideWith(_EmptyAirDrop.new),
          airdropHistoryProvider.overrideWith(_EmptyHistory.new),
          airdropReceiveProvider.overrideWith(_DefaultReceive.new),
          airdropLaneProvider.overrideWith(_DefaultLane.new),
          fileTransferControllerProvider.overrideWith(_FinishedTransfers.new),
          peerDiscoveryControllerProvider.overrideWith(_NearbyPeer.new),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('uk'),
          home: Scaffold(body: NearbyScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Файли'));
    await tester.pump(const Duration(milliseconds: 300));
    final historyTop = tester.getTopLeft(find.text('ІСТОРІЯ')).dy;
    final clearTop = tester.getTopLeft(find.text('Очистити історію')).dy;
    expect((historyTop - clearTop).abs(), lessThan(20));
    expect(find.byIcon(Icons.cleaning_services_rounded), findsNothing);

    // Still the same action it was as a broom: it clears finished transfers.
    final files = ProviderScope.containerOf(
      tester.element(find.text('ІСТОРІЯ')),
    ).read(fileTransferControllerProvider.notifier) as _FinishedTransfers;
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Очистити історію'));
    await tester.pump();
    expect(files.cleared, 1);
  });

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
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(c.read(airdropPageOnScreenProvider), isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(c.read(airdropPageOnScreenProvider), isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(c.read(airdropPageOnScreenProvider), isTrue);
  });

  testWidgets('the screen going away turns the AirDrop page off',
      (tester) async {
    final c = await pump(tester);
    await tester.tap(find.text('AirDrop'));
    await tester.pumpAndSettle();
    expect(c.read(airdropPageOnScreenProvider), isTrue);

    // Signing out, a wipe, or the shell rebuilding without this branch:
    // nothing else would ever say the page is gone, and the proximity scan
    // and the stranger-visibility window would run on.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: SizedBox()),
      ),
    );
    await tester.pumpAndSettle();
    expect(c.read(airdropPageOnScreenProvider), isFalse);
  });

  testWidgets('the scanning chip sits above the switch while scanning',
      (tester) async {
    await pumpReal(
      tester,
      extraOverrides: [
        peerDiscoveryControllerProvider.overrideWith(_NearbyPeer.new),
      ],
      settle: false,
    );

    expect(find.byType(ScanningPulse), findsOneWidget);
    final chipTop = tester.getTopLeft(find.byType(ScanningPulse)).dy;
    final switchTop = tester.getTopLeft(find.byType(SectionSwitch)).dy;
    expect(chipTop, lessThan(switchTop));
  });

  testWidgets(
      'the scanning chip is gone, not just invisible, once scanning stops',
      (tester) async {
    await pumpReal(
      tester,
      extraOverrides: [
        peerDiscoveryControllerProvider.overrideWith(_IdleWithPeer.new),
      ],
      // The peer card's online dot pulses off UiActivity too (see
      // "clear history..." above for the same reason), so this never
      // reaches pumpAndSettle's quiet frame.
      settle: false,
    );
    expect(find.byType(ScanningPulse), findsNothing);
  });

  testWidgets('the broadcast chip stretches to the width of the peer cards',
      (tester) async {
    await pumpReal(
      tester,
      extraOverrides: [
        peerDiscoveryControllerProvider.overrideWith(_NearbyPeer.new),
        peripheralControllerProvider.overrideWith(_Broadcasting.new),
      ],
      settle: false,
    );

    final chipWidth =
        tester.getSize(find.byKey(const ValueKey('broadcast-on'))).width;
    // Scoped to PeersScreen: the AirDrop and Files pages stay mounted
    // offstage and use GlassCard too, so an unscoped byType(GlassCard)
    // can pick up one of theirs instead of the peer card.
    final cardWidth = tester
        .getSize(
          find.descendant(
            of: find.byType(PeersScreen),
            matching: find.byType(GlassCard),
          ).first,
        )
        .width;
    expect(chipWidth, closeTo(cardWidth, 0.5));
  });

  testWidgets(
      'switch to first content is 16px when there is no broadcast chip',
      (tester) async {
    // The scanning chip has left the page, so with nothing broadcasting the
    // switch sits 16px above the peer cards directly (commit b375a11b's
    // fix, now with the broadcast chip as the only other thing that could
    // occupy that gap).
    await pumpReal(
      tester,
      extraOverrides: [
        peerDiscoveryControllerProvider.overrideWith(_NearbyPeer.new),
        peripheralControllerProvider.overrideWith(_NotBroadcasting.new),
      ],
      settle: false,
    );
    final peerCard = find.descendant(
      of: find.byType(PeersScreen),
      matching: find.byType(GlassCard),
    );
    final switchBottom = tester.getBottomLeft(find.byType(SectionSwitch)).dy;
    final cardTop = tester.getTopLeft(peerCard.first).dy;
    expect(cardTop - switchBottom, closeTo(16, 1));
  });

  testWidgets(
      'switch to broadcast chip is 16px, and chip to cards is 10-12px',
      (tester) async {
    await pumpReal(
      tester,
      extraOverrides: [
        peerDiscoveryControllerProvider.overrideWith(_NearbyPeer.new),
        peripheralControllerProvider.overrideWith(_Broadcasting.new),
      ],
      settle: false,
    );
    final peerCard = find.descendant(
      of: find.byType(PeersScreen),
      matching: find.byType(GlassCard),
    );
    final switchBottom = tester.getBottomLeft(find.byType(SectionSwitch)).dy;
    final chipTop =
        tester.getTopLeft(find.byKey(const ValueKey('broadcast-on'))).dy;
    expect(chipTop - switchBottom, closeTo(16, 1));
    final chipBottom =
        tester.getBottomLeft(find.byKey(const ValueKey('broadcast-on'))).dy;
    final cardTop = tester.getTopLeft(peerCard.first).dy;
    expect(cardTop - chipBottom, inInclusiveRange(9.5, 12.5));
  });
}
