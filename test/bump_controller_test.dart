import 'dart:async';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/transport/announcement.dart';
import 'package:cubechat/core/transport/nearby_offer.dart';
import 'package:cubechat/core/util/free_space.dart';
import 'package:cubechat/features/airdrop/data/airdrop_clock.dart';
import 'package:cubechat/features/airdrop/data/airdrop_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_history_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_lane_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_port.dart';
import 'package:cubechat/features/airdrop/data/airdrop_receive_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_source.dart';
import 'package:cubechat/features/airdrop/data/airdrop_spam_store.dart';
import 'package:cubechat/features/airdrop/data/airdrop_staged.dart';
import 'package:cubechat/features/airdrop/data/airdrop_storage.dart';
import 'package:cubechat/features/airdrop/data/bump_controller.dart';
import 'package:cubechat/features/airdrop/data/bump_ledger.dart';
import 'package:cubechat/features/airdrop/domain/airdrop_spam_guard.dart';
import 'package:cubechat/features/airdrop/domain/airdrop_transfer.dart';
import 'package:cubechat/features/airdrop/presentation/airdrop_navigation.dart';
import 'package:cubechat/features/files/data/file_transfer_controller.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _bob = 'b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0';
const _eve = 'e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0';

final _ownCard = Uint8List.fromList([9, 9, 9]);
final _theirCard = Uint8List.fromList([1, 2, 3]);

Uint8List _id(int seed) => Uint8List.fromList(
      List.generate(nearbyIdLen, (i) => (seed * 37 + i * 3) & 0xFF),
    );

NearbyBump _bump(int seed, {bool hasFiles = false}) =>
    NearbyBump(bumpId: _id(seed), hasFiles: hasFiles, card: _theirCard);

class _Port implements AirDropPort {
  // Created inside the fake zone by each test, sync so a delivery is handled
  // before the next line runs.
  final inboundCtl = StreamController<NearbyInbound>.broadcast(sync: true);
  final direct = <String>{};
  final sent = <({
    String to,
    NearbyOffer? offer,
    NearbyAnswer? answer,
    NearbyBump? bump,
  })>[];

  void deliver(
    String from, {
    NearbyOffer? offer,
    NearbyAnswer? answer,
    NearbyBump? bump,
    bool isDirect = true,
  }) =>
      inboundCtl.add(
        NearbyInbound(
          peerHex: from,
          direct: isDirect,
          offer: offer,
          answer: answer,
          bump: bump,
        ),
      );

  List<NearbyBump> bumpsTo(String hex) => [
        for (final s in sent)
          if (s.to == hex && s.bump != null) s.bump!,
      ];

  List<NearbyOffer> offersTo(String hex) => [
        for (final s in sent)
          if (s.to == hex && s.offer != null) s.offer!,
      ];

  @override
  Stream<NearbyInbound> get inbound => inboundCtl.stream;

  @override
  bool hasDirectLinkTo(String peerHex) => direct.contains(peerHex);

  @override
  Future<bool> send(
    String peerHex, {
    NearbyOffer? offer,
    NearbyAnswer? answer,
    NearbyBump? bump,
  }) async {
    if (!direct.contains(peerHex)) return false;
    sent.add((to: peerHex, offer: offer, answer: answer, bump: bump));
    return true;
  }

  @override
  Future<bool> sendFile(
    String peerHex, {
    required File file,
    required AirDropFile meta,
    required String peerName,
  }) async =>
      true;

  @override
  void cancelFile(String mediaIdHex) {}

  @override
  set sink(NearbyFileSink? value) {}
}

class _MemHistory extends AirDropHistoryController {
  @override
  List<AirDropHistoryEntry> build() => const [];

  @override
  Future<void> save(List<AirDropHistoryEntry> entries) async {}
}

class _MemSpam extends AirDropSpamStore {
  @override
  Map<String, SpamRecord> build() => const {};

  @override
  Future<void> save(Map<String, SpamRecord> records) async {}
}

class _Receive extends AirDropReceiveController {
  @override
  AirDropReceive build() => const AirDropReceive();
}

class _MemTransfers extends FileTransferController {
  @override
  Map<String, FileTransferTask> build() => const {};
}

class _Lane extends AirDropLaneController {
  @override
  AirDropLane build() => AirDropLane.bluetooth;

  @override
  Future<void> set(AirDropLane lane) async => state = lane;
}

/// Readings as the discovery controller would hand them over, settable from
/// the test.
final _readings = StateProvider<List<BumpReading>>((_) => const []);

void main() {
  const tick = Duration(milliseconds: 100);

  ProviderContainer make(
    FakeAsync async,
    _Port port, {
    bool page = true,
    Set<String> direct = const {_bob},
    Set<String> contacts = const {},
    Future<bool> Function(Uint8List card, String senderHex)? check,
  }) =>
      ProviderContainer(
        overrides: [
          airdropClockProvider.overrideWithValue(
            () => DateTime(2026, 9, 23, 12).add(async.elapsed),
          ),
          airdropPortProvider.overrideWithValue(port),
          airdropPageOnScreenProvider.overrideWith((_) => page),
          bumpDirectPeersProvider.overrideWithValue(direct),
          bumpOwnCardProvider.overrideWithValue(() async => _ownCard),
          bumpCardCheckProvider
              .overrideWithValue(check ?? (card, sender) async => true),
          bumpReadingsProvider.overrideWith((ref) => ref.watch(_readings)),
          airdropContactsProvider.overrideWithValue(contacts),
          airdropPeerNameProvider.overrideWithValue((_) => 'Боб'),
          airdropHistoryProvider.overrideWith(_MemHistory.new),
          airdropSpamProvider.overrideWith(_MemSpam.new),
          airdropReceiveProvider.overrideWith(_Receive.new),
          airdropNotifyProvider.overrideWithValue((_) {}),
          freeSpaceProvider.overrideWithValue(() async => null),
          airdropDirectoryProvider
              .overrideWithValue(() async => Directory.systemTemp),
          fileTransferControllerProvider.overrideWith(_MemTransfers.new),
          airdropLaneProvider.overrideWith(_Lane.new),
        ],
      );

  /// [peer] held at [rssi], one reading every 100 ms, for [total].
  void feed(
    FakeAsync async,
    ProviderContainer c,
    String peer,
    Duration total, {
    int rssi = -35,
  }) {
    final ctl = c.read(bumpControllerProvider.notifier);
    for (var t = Duration.zero; t < total; t += tick) {
      ctl.sample(peer, rssi);
      async.elapse(tick);
    }
  }

  BumpEvent? event(ProviderContainer c) => c.read(bumpControllerProvider).event;

  test('nothing happens while the page is closed', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port, page: false);
      c.read(bumpControllerProvider);
      port.deliver(_bob, bump: _bump(1));
      async.flushMicrotasks();
      feed(async, c, _bob, const Duration(milliseconds: 1500));
      expect(port.bumpsTo(_bob), isEmpty);
      expect(event(c), isNull);
      expect(async.periodicTimerCount, 0);
      c.dispose();
    });
  });

  test('close: our bump goes out, once', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      feed(async, c, _bob, const Duration(milliseconds: 1500));
      final bump = port.bumpsTo(_bob).single;
      expect(bump.hasFiles, isFalse);
      expect(bump.card, _ownCard);
      expect(event(c), isNull, reason: 'one side alone decides nothing');
      c.dispose();
    });
  });

  test('mutual within 2 s: a contact event, and the ledger noted', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      feed(async, c, _bob, const Duration(milliseconds: 1500));
      expect(port.bumpsTo(_bob), hasLength(1));

      port.deliver(_bob, bump: _bump(2));
      async.flushMicrotasks();
      final e = event(c);
      expect(e, isA<BumpContact>());
      e as BumpContact;
      expect(e.peerHex, _bob);
      expect(e.peerName, 'Боб');
      expect(e.card, _theirCard);
      expect(e.alreadyContact, isFalse);
      expect(
        c.read(bumpLedgerProvider).take(_bob, c.read(airdropClockProvider)()),
        isTrue,
      );
      c.dispose();
    });
  });

  test('a contact already in the list is marked so', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port, contacts: {_bob});
      c.read(bumpControllerProvider);
      feed(async, c, _bob, const Duration(milliseconds: 600));
      port.deliver(_bob, bump: _bump(3));
      async.flushMicrotasks();
      expect((event(c)! as BumpContact).alreadyContact, isTrue);
      c.dispose();
    });
  });

  test('their bump 3 s after ours: nothing', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      // Ours goes out at 400 ms, then the phones part.
      feed(async, c, _bob, const Duration(milliseconds: 500));
      expect(port.bumpsTo(_bob), hasLength(1));
      async.elapse(const Duration(milliseconds: 2900));
      port.deliver(_bob, bump: _bump(4));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2));
      expect(event(c), isNull);
      expect(port.bumpsTo(_bob), hasLength(1));
      c.dispose();
    });
  });

  test('their bump first, ours within 2 s: the event fires as ours goes out',
      () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      port.deliver(_bob, bump: _bump(5));
      async.flushMicrotasks();
      expect(event(c), isNull);
      feed(async, c, _bob, const Duration(milliseconds: 300));
      expect(port.bumpsTo(_bob), isEmpty);
      expect(event(c), isNull);
      feed(async, c, _bob, const Duration(milliseconds: 200));
      expect(port.bumpsTo(_bob), hasLength(1));
      expect(event(c), isA<BumpContact>());
      c.dispose();
    });
  });

  test('their bump first, ours more than 2 s later: nothing', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      port.deliver(_bob, bump: _bump(6));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2));
      feed(async, c, _bob, const Duration(milliseconds: 1000));
      expect(port.bumpsTo(_bob), hasLength(1));
      expect(event(c), isNull);
      c.dispose();
    });
  });

  test('staged files: an offer goes, the staging is cleared', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      c.read(airdropStagedProvider.notifier).state = [
        AirDropSource(
          file: File('${Directory.systemTemp.path}/a.jpg'),
          name: 'a.jpg',
          size: 10,
          mime: 'image/jpeg',
        ),
      ];
      feed(async, c, _bob, const Duration(milliseconds: 500));
      expect(port.bumpsTo(_bob).single.hasFiles, isTrue);
      port.deliver(_bob, bump: _bump(7));
      async.flushMicrotasks();
      expect(port.offersTo(_bob).single.files.single.name, 'a.jpg');
      expect(c.read(airdropStagedProvider), isEmpty);
      final e = event(c);
      expect(e, isA<BumpSentFiles>());
      expect((e! as BumpSentFiles).count, 1);
      c.dispose();
    });
  });

  test('they have files and we do not: a receiving event, no offer', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      feed(async, c, _bob, const Duration(milliseconds: 500));
      port.deliver(_bob, bump: _bump(8, hasFiles: true));
      async.flushMicrotasks();
      expect(event(c), isA<BumpReceivingFiles>());
      expect(port.offersTo(_bob), isEmpty);
      c.dispose();
    });
  });

  test('cooldown: five seconds per person, then it can fire again', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      final ctl = c.read(bumpControllerProvider.notifier);
      feed(async, c, _bob, const Duration(milliseconds: 500));
      port.deliver(_bob, bump: _bump(9));
      async.flushMicrotasks();
      expect(event(c), isA<BumpContact>());
      ctl.dismiss();
      expect(event(c), isNull);
      final firstBumps = port.bumpsTo(_bob).length;

      // Held together for four more seconds, and Bob's phone tries again.
      feed(async, c, _bob, const Duration(seconds: 2));
      port.deliver(_bob, bump: _bump(10));
      async.flushMicrotasks();
      feed(async, c, _bob, const Duration(seconds: 2));
      expect(event(c), isNull);
      expect(
        port.bumpsTo(_bob).length,
        firstBumps,
        reason: 'nothing goes to them while they are quiet',
      );

      // Past the five seconds: ours goes again, and a fresh one of theirs
      // matches it.
      feed(async, c, _bob, const Duration(milliseconds: 1200));
      expect(port.bumpsTo(_bob).length, firstBumps + 1);
      port.deliver(_bob, bump: _bump(11));
      async.flushMicrotasks();
      expect(event(c), isA<BumpContact>());
      c.dispose();
    });
  });

  test('a replayed bumpId is not a fresh bump', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      port.deliver(_bob, bump: _bump(12));
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 2500));
      port.deliver(_bob, bump: _bump(12));
      async.flushMicrotasks();
      // Ours goes out about three seconds after the first delivery, half a
      // second after the replay.
      feed(async, c, _bob, const Duration(milliseconds: 500));
      expect(port.bumpsTo(_bob), hasLength(1));
      expect(event(c), isNull);
      c.dispose();
    });
  });

  test('someone without a direct session is never bumped', () {
    fakeAsync((async) {
      final port = _Port()..direct.addAll([_bob, _eve]);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      feed(async, c, _eve, const Duration(milliseconds: 1500));
      expect(port.bumpsTo(_eve), isEmpty);
      expect(port.sent, isEmpty);
      c.dispose();
    });
  });

  test('a card that is not the sender\'s is dropped', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port, check: (card, sender) async => false);
      c.read(bumpControllerProvider);
      feed(async, c, _bob, const Duration(milliseconds: 500));
      port.deliver(_bob, bump: _bump(13));
      async.flushMicrotasks();
      expect(event(c), isNull);
      c.dispose();
    });
  });

  test('a bump relayed through someone else is ignored', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      feed(async, c, _bob, const Duration(milliseconds: 500));
      port.deliver(_bob, bump: _bump(14), isDirect: false);
      async.flushMicrotasks();
      expect(event(c), isNull);
      c.dispose();
    });
  });

  test('a card check still running when the page closes records nothing', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final gate = Completer<bool>();
      final c = make(async, port, check: (card, sender) => gate.future);
      c.read(bumpControllerProvider);
      feed(async, c, _bob, const Duration(milliseconds: 500));
      port.deliver(_bob, bump: _bump(15));
      async.flushMicrotasks();
      c.read(airdropPageOnScreenProvider.notifier).state = false;
      c.read(airdropPageOnScreenProvider.notifier).state = true;
      gate.complete(true);
      async.flushMicrotasks();
      // Back on the page, ours goes out again: the bump heard before the
      // page closed must not be waiting for it.
      feed(async, c, _bob, const Duration(milliseconds: 500));
      expect(port.bumpsTo(_bob), hasLength(2));
      expect(event(c), isNull);
      c.dispose();
    });
  });

  test('the tick runs only while the page is on; leaving clears the staging',
      () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      expect(async.periodicTimerCount, 1);
      c.read(airdropStagedProvider.notifier).state = [
        AirDropSource(
          file: File('${Directory.systemTemp.path}/a.jpg'),
          name: 'a.jpg',
          size: 10,
          mime: 'image/jpeg',
        ),
      ];
      feed(async, c, _bob, const Duration(milliseconds: 1000));
      expect(c.read(bumpControllerProvider).warmth, 1);

      c.read(airdropPageOnScreenProvider.notifier).state = false;
      expect(async.periodicTimerCount, 0);
      expect(c.read(airdropStagedProvider), isEmpty);
      expect(c.read(bumpControllerProvider).warmth, 0);

      c.read(airdropPageOnScreenProvider.notifier).state = true;
      expect(async.periodicTimerCount, 1);
      c.dispose();
      expect(async.periodicTimerCount, 0);
    });
  });

  test('warmth climbs from -60 dBm and falls back to zero', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      feed(async, c, _bob, const Duration(milliseconds: 1000), rssi: -50);
      expect(c.read(bumpControllerProvider).warmth, closeTo(0.5, 0.05));
      async.elapse(const Duration(seconds: 4));
      expect(c.read(bumpControllerProvider).warmth, 0);
      c.dispose();
    });
  });

  test('only fresh readings from the scan count as samples', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      final start = DateTime(2026, 9, 23, 12);
      // The same advertisement handed over again every time the list moves
      // for somebody else: one sample, never "close".
      for (var i = 0; i < 10; i++) {
        c.read(_readings.notifier).state = [
          (hex: _bob, rssi: -35, seen: start),
          (hex: _eve, rssi: -90, seen: start.add(tick * i)),
        ];
        async.elapse(tick);
      }
      expect(port.bumpsTo(_bob), isEmpty);

      for (var i = 0; i < 10; i++) {
        c.read(_readings.notifier).state = [
          (hex: _bob, rssi: -35, seen: start.add(tick * (20 + i))),
        ];
        async.elapse(tick);
      }
      expect(port.bumpsTo(_bob), hasLength(1));
      c.dispose();
    });
  });

  test('the BUMP line: at most once a second, and only on the open page', () {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) {
      if (m != null && m.startsWith('[BUMP]')) lines.add(m);
    };
    addTearDown(() => debugPrint = previous);
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      feed(async, c, _bob, const Duration(seconds: 3), rssi: -70);
      final open = lines.where((l) => l.contains('dBm')).length;
      expect(open, inInclusiveRange(2, 3));
      expect(lines.first, contains('b0b0b0b0 -70 dBm, next -'));

      c.read(airdropPageOnScreenProvider.notifier).state = false;
      lines.clear();
      feed(async, c, _bob, const Duration(seconds: 3), rssi: -70);
      expect(lines, isEmpty);
      c.dispose();
    });
  });

  group('the default card check', () {
    Future<(Uint8List, String)> signed() async {
      final ed = Ed25519();
      final keys = await (await ed.newKeyPair()).extract();
      final pub = Uint8List.fromList(List.generate(32, (i) => 0xb0));
      final card = await PeerAnnouncement(
        pubkey: pub,
        signPubkey: Uint8List.fromList(keys.publicKey.bytes),
        signedPrekeyPub: Uint8List(32),
        nostrPubkey: Uint8List(32),
        nickname: 'Боб',
      ).sign(keys);
      return (card, nearbyHex(pub));
    }

    test('accepts the sender\'s own signed card only', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final check = c.read(bumpCardCheckProvider);
      final (card, hex) = await signed();
      expect(hex, _bob);
      expect(await check(card, _bob), isTrue);
      expect(await check(card, _eve), isFalse);
      final forged = Uint8List.fromList(card)..[card.length - 1] ^= 0x01;
      expect(await check(forged, _bob), isFalse);
      expect(await check(_theirCard, _bob), isFalse);
    });
  });
}
