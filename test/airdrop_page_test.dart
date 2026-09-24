import 'dart:io';

import 'package:cubechat/core/transport/nearby_offer.dart';
import 'package:cubechat/features/airdrop/data/airdrop_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_history_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_lane_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_receive_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_source.dart';
import 'package:cubechat/features/airdrop/data/airdrop_staged.dart';
import 'package:cubechat/features/airdrop/data/bump_controller.dart';
import 'package:cubechat/features/airdrop/domain/airdrop_transfer.dart';
import 'package:cubechat/features/airdrop/presentation/airdrop_page.dart';
import 'package:cubechat/features/airdrop/presentation/airdrop_people_sheet.dart';
import 'package:cubechat/features/files/data/file_transfer_controller.dart';
import 'package:cubechat/features/peers/data/peer_discovery_controller.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAirDrop extends AirDropController {
  _FakeAirDrop(this.initial);

  final AirDropState initial;
  final accepted = <String>[];
  final declined = <String>[];
  final cancelled = <String>[];

  @override
  AirDropState build() => initial;

  @override
  Future<void> accept(String id) async => accepted.add(id);

  @override
  Future<void> decline(String id) async => declined.add(id);

  @override
  Future<void> cancel(String id) async => cancelled.add(id);
}

class _MemHistory extends AirDropHistoryController {
  _MemHistory(this.entries);

  final List<AirDropHistoryEntry> entries;

  @override
  List<AirDropHistoryEntry> build() => entries;

  @override
  Future<void> save(List<AirDropHistoryEntry> entries) async {}
}

class _Receive extends AirDropReceiveController {
  var opened = 0;

  @override
  AirDropReceive build() => const AirDropReceive();

  @override
  Future<void> openToEveryone() async => opened++;
}

/// The channel setting without its Hive box — the real one opens the box in
/// `build()`, and `set()` awaits it, which a widget test never lets finish.
class _Lane extends AirDropLaneController {
  @override
  AirDropLane build() => AirDropLane.auto;

  @override
  Future<void> set(AirDropLane lane) async => state = lane;
}

/// The bump gesture at rest — the page mounts its glow, and the real
/// controller would reach for the messaging service.
class _IdleBump extends BumpController {
  @override
  BumpState build() => const BumpState();
}

/// Stands in for the scanner, which the page now watches for the adapter
/// state — the real controller would reach for flutter_blue_plus.
class _Discovery extends PeerDiscoveryController {
  _Discovery(this.status);

  final PeerDiscoveryStatus status;

  @override
  PeerDiscoveryState build() =>
      PeerDiscoveryState(status: status, peers: const []);
}

class _MemTransfers extends FileTransferController {
  @override
  Map<String, FileTransferTask> build() => const {};
}

AirDropTransfer _transfer({
  required AirDropDirection direction,
  required AirDropPhase phase,
}) =>
    AirDropTransfer(
      id: 'aa' * 16,
      peerHex: 'bb' * 32,
      peerName: 'Жека',
      direction: direction,
      phase: phase,
      createdAt: DateTime(2026, 9, 22),
      files: const [
        AirDropFile(
          mediaIdHex: 'f0',
          name: 'a.jpg',
          size: 10,
          mime: 'image/jpeg',
        ),
        AirDropFile(
          mediaIdHex: 'f1',
          name: 'b.jpg',
          size: 10,
          mime: 'image/jpeg',
        ),
      ],
    );

Widget _app(Widget home, List<Override> overrides) => ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('uk'),
        home: Scaffold(body: home),
      ),
    );

void main() {
  late _Receive receive;
  late _Lane lane;
  late PeerDiscoveryStatus scan;

  List<Override> overrides(
    _FakeAirDrop airdrop, [
    List<AirDropHistoryEntry> history = const [],
  ]) =>
      [
        airdropControllerProvider.overrideWith(() => airdrop),
        airdropHistoryProvider.overrideWith(() => _MemHistory(history)),
        airdropReceiveProvider.overrideWith(() => receive),
        airdropLaneProvider.overrideWith(() => lane),
        fileTransferControllerProvider.overrideWith(_MemTransfers.new),
        bumpControllerProvider.overrideWith(_IdleBump.new),
        peerDiscoveryControllerProvider.overrideWith(() => _Discovery(scan)),
      ];

  setUp(() {
    receive = _Receive();
    lane = _Lane();
    scan = PeerDiscoveryStatus.scanning;
  });

  const bluetoothHint = 'Увімкніть Bluetooth на обох телефонах, щоб знайти '
      'один одного й підтвердити передачу.';

  testWidgets('with Bluetooth off the page says both phones need it',
      (tester) async {
    scan = PeerDiscoveryStatus.adapterOff;
    final airdrop = _FakeAirDrop(const AirDropState());
    await tester.pumpWidget(_app(const AirDropPage(), overrides(airdrop)));
    await tester.pumpAndSettle();
    expect(find.text(bluetoothHint), findsOneWidget);
  });

  // Bluetooth on, or merely not known yet: no hint.
  for (final status in [
    PeerDiscoveryStatus.scanning,
    PeerDiscoveryStatus.idle,
    PeerDiscoveryStatus.permissionsUnknown,
  ]) {
    testWidgets('no Bluetooth hint while ${status.name}', (tester) async {
      scan = status;
      final airdrop = _FakeAirDrop(const AirDropState());
      await tester.pumpWidget(_app(const AirDropPage(), overrides(airdrop)));
      await tester.pumpAndSettle();
      expect(find.text(bluetoothHint), findsNothing);
    });
  }

  testWidgets('a request says who, what and how much, and both buttons work',
      (tester) async {
    final request = _transfer(
      direction: AirDropDirection.incoming,
      phase: AirDropPhase.waiting,
    );
    final airdrop = _FakeAirDrop(AirDropState(transfers: [request]));
    await tester.pumpWidget(_app(const AirDropPage(), overrides(airdrop)));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('хоче надіслати 2 фото · 20 B', findRichText: true),
      findsOneWidget,
    );
    await tester.tap(find.text('Прийняти'));
    await tester.tap(find.text('Відхилити'));
    expect(airdrop.accepted, [request.id]);
    expect(airdrop.declined, [request.id]);
  });

  testWidgets('an offer nobody saw says it may be an old version',
      (tester) async {
    final sending = _transfer(
      direction: AirDropDirection.outgoing,
      phase: AirDropPhase.unheard,
    );
    final airdrop = _FakeAirDrop(AirDropState(transfers: [sending]));
    await tester.pumpWidget(_app(const AirDropPage(), overrides(airdrop)));
    await tester.pumpAndSettle();

    expect(
      find.text('Не отримав — можливо, стара версія CubeChat'),
      findsOneWidget,
    );
    await tester.tap(find.byIcon(Icons.close_rounded));
    expect(airdrop.cancelled, [sending.id]);
  });

  testWidgets('the history says what happened and why', (tester) async {
    final airdrop = _FakeAirDrop(const AirDropState());
    final entry = AirDropHistoryEntry(
      id: 'h1',
      peerHex: 'bb' * 32,
      peerName: 'Жека',
      direction: AirDropDirection.outgoing,
      at: DateTime(2026, 9, 22, 14, 5),
      outcome: AirDropOutcome.declined,
      reason: NearbyDeclineReason.busy,
      files: const [
        AirDropHistoryFile(name: 'a.jpg', size: 10, mime: 'image/jpeg'),
      ],
    );
    await tester.pumpWidget(
      _app(const AirDropPage(), overrides(airdrop, [entry])),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Відхилено · зайнято'), findsOneWidget);
  });

  testWidgets('nothing yet: the empty line, and "everyone" opens the window',
      (tester) async {
    final airdrop = _FakeAirDrop(const AirDropState());
    await tester.pumpWidget(_app(const AirDropPage(), overrides(airdrop)));
    await tester.pumpAndSettle();
    expect(
      find.text('Тут будуть файли, які ви надсилаєте й отримуєте поруч'),
      findsOneWidget,
    );
    await tester.tap(find.text('Усі 10 хв'));
    expect(receive.opened, 1);
  });

  testWidgets('the people list offers only who is linked, and a tap picks',
      (tester) async {
    AirDropPeer? picked;
    await tester.pumpWidget(
      _app(
        AirDropPeopleList(onPick: (p) => picked = p),
        [
          airdropDirectPeersProvider.overrideWithValue(
            const [AirDropPeer('cc', 'Оля'), AirDropPeer('dd', 'Петро')],
          ),
        ],
      ),
    );
    // Fixed pumps: the online dot on each avatar pulses, so nothing settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Петро'));
    expect(picked?.hex, 'dd');
  });

  testWidgets('with nobody nearby the list says so', (tester) async {
    await tester.pumpWidget(
      _app(
        AirDropPeopleList(onPick: (_) {}),
        [airdropDirectPeersProvider.overrideWithValue(const [])],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Поруч поки нікого з cubechat'), findsOneWidget);
  });

  testWidgets(
      'the lane switch offers Auto/Bluetooth/Wi-Fi, and picking Wi-Fi sets it',
      (tester) async {
    final airdrop = _FakeAirDrop(const AirDropState());
    await tester.pumpWidget(_app(const AirDropPage(), overrides(airdrop)));
    await tester.pumpAndSettle();

    expect(find.text('Авто'), findsOneWidget);
    expect(find.text('Bluetooth'), findsOneWidget);
    expect(find.text('Wi‑Fi'), findsOneWidget);

    await tester.tap(find.text('Wi‑Fi'));
    await tester.pumpAndSettle();
    expect(lane.state, AirDropLane.wifi);
  });

  testWidgets('a transferring card over Wi-Fi shows the Wi-Fi icon',
      (tester) async {
    final sending = _transfer(
      direction: AirDropDirection.outgoing,
      phase: AirDropPhase.transferring,
    ).copyWith(wifi: true);
    final airdrop = _FakeAirDrop(AirDropState(transfers: [sending]));
    await tester.pumpWidget(_app(const AirDropPage(), overrides(airdrop)));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.wifi_rounded), findsOneWidget);
    expect(find.byIcon(Icons.bluetooth_rounded), findsNothing);
  });

  testWidgets('a transferring card over Bluetooth shows the Bluetooth icon',
      (tester) async {
    final sending = _transfer(
      direction: AirDropDirection.outgoing,
      phase: AirDropPhase.transferring,
    ).copyWith(wifi: false);
    final airdrop = _FakeAirDrop(AirDropState(transfers: [sending]));
    await tester.pumpWidget(_app(const AirDropPage(), overrides(airdrop)));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.bluetooth_rounded), findsOneWidget);
    expect(find.byIcon(Icons.wifi_rounded), findsNothing);
  });

  // A Wi-Fi-only send that fails leaves the live list the moment it fails
  // (see AirDropTransitions), so `wifiUnreachable` on a live card is never
  // actually seen on a phone. The reason survives only in the history entry
  // — that is where this has to be tested instead of on the progress card.
  testWidgets('a failed history row says it was not on the same network',
      (tester) async {
    final airdrop = _FakeAirDrop(const AirDropState());
    final entry = AirDropHistoryEntry(
      id: 'h2',
      peerHex: 'bb' * 32,
      peerName: 'Жека',
      direction: AirDropDirection.outgoing,
      at: DateTime(2026, 9, 22, 14, 5),
      outcome: AirDropOutcome.failed,
      noWifiRoute: true,
      files: const [
        AirDropHistoryFile(name: 'a.jpg', size: 10, mime: 'image/jpeg'),
      ],
    );
    await tester.pumpWidget(
      _app(const AirDropPage(), overrides(airdrop, [entry])),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Не в одній мережі'), findsOneWidget);
  });

  testWidgets('a Wi-Fi-only send to an old app says so, not "network"',
      (tester) async {
    final airdrop = _FakeAirDrop(const AirDropState());
    final entry = AirDropHistoryEntry(
      id: 'h3',
      peerHex: 'bb' * 32,
      peerName: 'Жека',
      direction: AirDropDirection.outgoing,
      at: DateTime(2026, 9, 22, 14, 5),
      outcome: AirDropOutcome.failed,
      wifiOldVersion: true,
      files: const [
        AirDropHistoryFile(name: 'a.jpg', size: 10, mime: 'image/jpeg'),
      ],
    );
    await tester.pumpWidget(
      _app(const AirDropPage(), overrides(airdrop, [entry])),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Їхній застосунок ще не приймає через Wi‑Fi'),
      findsOneWidget,
    );
    expect(find.textContaining('Не в одній мережі'), findsNothing);
  });

  testWidgets('with nothing staged, the page offers to choose files',
      (tester) async {
    final airdrop = _FakeAirDrop(const AirDropState());
    await tester.pumpWidget(_app(const AirDropPage(), overrides(airdrop)));
    await tester.pumpAndSettle();
    expect(find.text('Вибрати файли'), findsOneWidget);
  });

  testWidgets(
      'staged files show the ready count and hint, and let you clear or '
      'pick a person', (tester) async {
    final airdrop = _FakeAirDrop(const AirDropState());
    final staged = [
      AirDropSource(
        file: File('a.jpg'),
        name: 'a.jpg',
        size: 10,
        mime: 'image/jpeg',
      ),
      AirDropSource(
        file: File('b.jpg'),
        name: 'b.jpg',
        size: 20,
        mime: 'image/jpeg',
      ),
    ];
    await tester.pumpWidget(
      _app(const AirDropPage(), [
        ...overrides(airdrop),
        airdropStagedProvider.overrideWith((ref) => staged),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 файли готові'), findsOneWidget);
    expect(
      find.text(
        'З увімкненим Bluetooth та AirDrop на обох телефонах піднесіть їх '
        'або виберіть людину',
      ),
      findsOneWidget,
    );
    expect(find.text('Вибрати людину'), findsOneWidget);
    expect(find.text('Вибрати файли'), findsNothing);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AirDropPage)),
    );
    expect(container.read(airdropStagedProvider), staged);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    expect(container.read(airdropStagedProvider), isEmpty);
    expect(find.text('Вибрати файли'), findsOneWidget);
  });
}
