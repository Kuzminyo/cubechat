import 'dart:async';

import 'package:cubechat/features/airdrop/data/airdrop_controller.dart';
import 'package:cubechat/features/airdrop/data/bump_controller.dart';
import 'package:cubechat/features/airdrop/presentation/airdrop_people_sheet.dart';
import 'package:cubechat/features/peers/data/peer_discovery_controller.dart';
import 'package:cubechat/features/peers/models/discovered_peer.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _oly = 'cc' * 32;
final _petro = 'dd' * 32;
final _stranger = 'ee' * 32;

class _Scan extends PeerDiscoveryController {
  _Scan(this.peers);

  final List<DiscoveredPeer> peers;

  @override
  PeerDiscoveryState build() => PeerDiscoveryState(
        status: PeerDiscoveryStatus.scanning,
        peers: peers,
      );
}

DiscoveredPeer _seen(String id, int rssi, {String? hex}) => DiscoveredPeer(
      id: id,
      advertisedName: '',
      rssi: rssi,
      lastSeen: DateTime(2026, 9, 24),
      resolvedPubkeyHex: hex,
    );

/// Who has a session, changeable mid-test the way a handshake changes it.
final _linked = StateProvider<List<AirDropPeer>>((_) => const []);

typedef _Dialler = Future<String?> Function(String device, String? hex);

void main() {
  late List<({String device, String? hex})> dials;

  Widget app({
    required List<DiscoveredPeer> scan,
    required _Dialler dial,
    required ValueChanged<AirDropPeer> onPick,
    List<AirDropPeer> linked = const [],
    ValueNotifier<bool>? shown,
  }) {
    final open = shown ?? ValueNotifier(true);
    return ProviderScope(
      overrides: [
        _linked.overrideWith((_) => linked),
        airdropDirectPeersProvider.overrideWith((ref) => ref.watch(_linked)),
        peerDiscoveryControllerProvider.overrideWith(() => _Scan(scan)),
        airdropPeerNameProvider.overrideWithValue(
          (hex) => hex == _oly
              ? 'Оля'
              : hex == _petro
                  ? 'Петро'
                  : 'CubeChat',
        ),
        bumpDialProvider.overrideWithValue((device, hex) {
          dials.add((device: device, hex: hex));
          return dial(device, hex);
        }),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('uk'),
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: open,
            builder: (_, on, __) => on
                ? AirDropPeopleList(onPick: onPick)
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }

  // Fixed pumps throughout: the online dot and the spinner animate forever,
  // so nothing settles.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  setUp(() => dials = []);

  testWidgets(
      'somebody the scan sees but nobody linked is listed as "Поруч", '
      'after the linked', (tester) async {
    await tester.pumpWidget(
      app(
        scan: [_seen('AA:01', -40)],
        linked: [AirDropPeer(_oly, 'Оля')],
        dial: (_, __) async => null,
        onPick: (_) {},
      ),
    );
    await settle(tester);
    expect(find.text('Поруч'), findsOneWidget);
    expect(find.text('Оля'), findsOneWidget);
    // Linked first, although the stranger is louder.
    expect(
      tester.getTopLeft(find.text('Оля')).dy,
      lessThan(tester.getTopLeft(find.text('Поруч')).dy),
    );
    expect(find.textContaining('ніхто не підключений'), findsNothing);
  });

  testWidgets('one row per person: a scanned phone that is linked is not two',
      (tester) async {
    await tester.pumpWidget(
      app(
        scan: [
          _seen('AA:01', -60, hex: _oly),
          _seen('AA:02', -50, hex: _petro),
          _seen('AA:03', -70),
        ],
        linked: [AirDropPeer(_oly, 'Оля')],
        dial: (_, __) async => null,
        onPick: (_) {},
      ),
    );
    await settle(tester);
    expect(find.text('Оля'), findsOneWidget);
    expect(find.text('Петро'), findsOneWidget);
    expect(find.text('Поруч'), findsOneWidget);
    // Unlinked by signal: Петро (-50) above the unknown phone (-70).
    expect(
      tester.getTopLeft(find.text('Петро')).dy,
      lessThan(tester.getTopLeft(find.text('Поруч')).dy),
    );
  });

  testWidgets('a linked person is picked at once, without dialling',
      (tester) async {
    AirDropPeer? picked;
    await tester.pumpWidget(
      app(
        scan: const [],
        linked: [AirDropPeer(_oly, 'Оля')],
        dial: (_, __) async => fail('must not dial'),
        onPick: (p) => picked = p,
      ),
    );
    await settle(tester);
    await tester.tap(find.text('Оля'));
    expect(picked?.hex, _oly);
    expect(dials, isEmpty);
  });

  testWidgets(
      'a tap on a stranger dials once, says it is connecting, and picks '
      'the identity the handshake proved', (tester) async {
    final answer = Completer<String?>();
    AirDropPeer? picked;
    await tester.pumpWidget(
      app(
        scan: [_seen('AA:01', -40)],
        dial: (_, __) => answer.future,
        onPick: (p) => picked = p,
      ),
    );
    await settle(tester);
    await tester.tap(find.text('Поруч'));
    await tester.pump();
    await tester.tap(find.text('Поруч'));
    await tester.pump();
    expect(dials, [(device: 'AA:01', hex: null)]);
    expect(find.text('З’єднуюсь…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(picked, isNull);

    answer.complete(_stranger);
    await tester.pump();
    expect(picked?.hex, _stranger);
  });

  testWidgets(
      'a known person without a session is picked when the session appears',
      (tester) async {
    AirDropPeer? picked;
    await tester.pumpWidget(
      app(
        scan: [_seen('AA:02', -50, hex: _petro)],
        // The GATT link came up but the handshake had not finished in time.
        dial: (_, __) async => null,
        onPick: (p) => picked = p,
      ),
    );
    await settle(tester);
    await tester.tap(find.text('Петро'));
    await tester.pump();
    expect(dials, [(device: 'AA:02', hex: _petro)]);
    expect(picked, isNull);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AirDropPeopleList)),
    );
    container.read(_linked.notifier).state = [AirDropPeer(_petro, 'Петро')];
    await tester.pump();
    expect(picked?.hex, _petro);
  });

  testWidgets(
      'no session in 15 s: a toast, the row stays, and it can be tapped again',
      (tester) async {
    AirDropPeer? picked;
    await tester.pumpWidget(
      app(
        scan: [_seen('AA:01', -40)],
        dial: (_, __) => Completer<String?>().future,
        onPick: (p) => picked = p,
      ),
    );
    await settle(tester);
    await tester.tap(find.text('Поруч'));
    await tester.pump(const Duration(seconds: 14));
    expect(find.text('З’єднуюсь…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('Не вдалося з’єднатися'), findsOneWidget);
    expect(find.text('З’єднуюсь…'), findsNothing);
    expect(find.text('Поруч'), findsOneWidget);
    expect(picked, isNull);

    await tester.tap(find.text('Поруч'));
    await tester.pump();
    expect(dials, hasLength(2));
    expect(find.text('З’єднуюсь…'), findsOneWidget);
    // Let the toast and the second wait run out, so no timer is left.
    await tester.pump(const Duration(seconds: 16));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('closing the sheet cancels the wait: nothing is picked later',
      (tester) async {
    final answer = Completer<String?>();
    final shown = ValueNotifier(true);
    AirDropPeer? picked;
    await tester.pumpWidget(
      app(
        scan: [_seen('AA:01', -40)],
        dial: (_, __) => answer.future,
        onPick: (p) => picked = p,
        shown: shown,
      ),
    );
    await settle(tester);
    await tester.tap(find.text('Поруч'));
    await tester.pump();
    shown.value = false;
    await tester.pump();

    answer.complete(_stranger);
    await tester.pump();
    // No toast either: the timeout went with the sheet.
    await tester.pump(const Duration(seconds: 16));
    expect(picked, isNull);
    expect(find.text('Не вдалося з’єднатися'), findsNothing);
  });
}
