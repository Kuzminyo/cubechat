import 'dart:async';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/transport/announcement.dart';
import 'package:cubechat/core/transport/messaging_service.dart';
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
import 'package:cubechat/features/peers/data/peer_discovery_controller.dart';
import 'package:cubechat/features/peers/models/discovered_peer.dart';
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

AirDropSource _src([String name = 'a.jpg']) => AirDropSource(
      file: File('${Directory.systemTemp.path}${Platform.pathSeparator}$name'),
      name: name,
      size: 10,
      mime: 'image/jpeg',
    );

class _Port implements AirDropPort {
  // Created inside the fake zone by each test, sync so a delivery is handled
  // before the next line runs.
  final inboundCtl = StreamController<NearbyInbound>.broadcast(sync: true);
  final direct = <String>{};

  /// The other phone's port, for two-phone tests: whatever this one sends
  /// arrives there, from [me], in the order it was sent.
  _Port? other;
  String me = '';
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
    other?.deliver(me, offer: offer, answer: answer, bump: bump);
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

class _Discovery extends PeerDiscoveryController {
  _Discovery(this.peers);

  final List<DiscoveredPeer> peers;

  @override
  PeerDiscoveryState build() =>
      PeerDiscoveryState(status: PeerDiscoveryStatus.scanning, peers: peers);
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
    Future<Uint8List> Function()? ownCard,
    Future<String> Function(Uint8List card)? addContact,
    Future<String?> Function(String device, String? hex)? dial,
    int Function()? adverts,
  }) =>
      ProviderContainer(
        overrides: [
          bumpScanAdvertsProvider.overrideWithValue(adverts ?? () => 0),
          bumpDialProvider
              .overrideWithValue(dial ?? (device, hex) async => null),
          airdropClockProvider.overrideWithValue(
            () => DateTime(2026, 9, 23, 12).add(async.elapsed),
          ),
          airdropPortProvider.overrideWithValue(port),
          airdropPageOnScreenProvider.overrideWith((_) => page),
          bumpDirectPeersProvider.overrideWithValue(direct),
          bumpOwnCardProvider
              .overrideWithValue(ownCard ?? () async => _ownCard),
          bumpCardCheckProvider
              .overrideWithValue(check ?? (card, sender) async => true),
          bumpAddContactProvider.overrideWithValue(
            addContact ?? (card) async => throw StateError('not in this test'),
          ),
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

  test('mutual within 2 s: a contact event, and no door for an offer', () {
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
      // A contact swap: a stranger gets a card, not an auto-accepted offer
      // as well.
      expect(
        c.read(bumpLedgerProvider).take(_bob, c.read(airdropClockProvider)()),
        isFalse,
      );
      c.dispose();
    });
  });

  test('their bump with files opens the door for their offer', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      feed(async, c, _bob, const Duration(milliseconds: 500));
      port.deliver(_bob, bump: _bump(40, hasFiles: true));
      expect(
        c.read(bumpLedgerProvider).take(_bob, c.read(airdropClockProvider)()),
        isTrue,
        reason: 'noted synchronously, before anything could overtake it',
      );
      c.dispose();
    });
  });

  test('both have files: each sends, and theirs is let in too', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      c.read(airdropStagedProvider.notifier).state = [_src()];
      feed(async, c, _bob, const Duration(milliseconds: 500));
      port.deliver(_bob, bump: _bump(41, hasFiles: true));
      async.flushMicrotasks();
      expect(event(c), isA<BumpSentFiles>());
      expect(port.offersTo(_bob), hasLength(1));
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
      c.read(airdropStagedProvider.notifier).state = [_src()];
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

  test(
      'sixty staged files: the offer carries the first fifty, without '
      'throwing', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      c.read(airdropStagedProvider.notifier).state = [
        for (var i = 0; i < 60; i++) _src('f$i.jpg'),
      ];
      feed(async, c, _bob, const Duration(milliseconds: 500));
      port.deliver(_bob, bump: _bump(46));
      async.flushMicrotasks();
      expect(port.offersTo(_bob).single.files, hasLength(nearbyMaxFiles));
      expect((event(c)! as BumpSentFiles).count, nearbyMaxFiles);
      c.dispose();
    });
  });

  test('a staged file over the Bluetooth cap is never offered', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      final big = AirDropSource(
        file: File('${Directory.systemTemp.path}${Platform.pathSeparator}b'),
        name: 'big.mov',
        size: MessagingService.maxFileBytesMesh + 1,
        mime: 'video/quicktime',
      );
      c.read(airdropStagedProvider.notifier).state = [big];
      feed(async, c, _bob, const Duration(milliseconds: 500));
      port.deliver(_bob, bump: _bump(47));
      async.flushMicrotasks();
      expect(port.offersTo(_bob), isEmpty);
      c.dispose();
    });
  });

  group('vetAirDropFiles', () {
    test('caps the count at the offer limit', () {
      final v = vetAirDropFiles([for (var i = 0; i < 60; i++) _src('f$i')]);
      expect(v.files, hasLength(nearbyMaxFiles));
      expect(v.tooLarge, isNull);
    });

    test('names the first file over the cap, and passes nothing', () {
      final big = AirDropSource(
        file: File('big'),
        name: 'big.mov',
        size: MessagingService.maxFileBytesMesh + 1,
        mime: 'video/quicktime',
      );
      final v = vetAirDropFiles([_src(), big]);
      expect(v.tooLarge, same(big));
      expect(v.files, isEmpty);
    });
  });

  test('a wipe takes the card off the screen and forgets the gesture', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      final ctl = c.read(bumpControllerProvider.notifier);
      feed(async, c, _bob, const Duration(milliseconds: 500));
      port.deliver(_bob, bump: _bump(48, hasFiles: true));
      async.flushMicrotasks();
      expect(event(c), isA<BumpReceivingFiles>());

      ctl.wipe();
      expect(event(c), isNull);
      expect(c.read(bumpControllerProvider).warmth, 0);
      // Nor is the five-second pause kept: that is a record of who was
      // here, and a fresh install has none.
      feed(async, c, _bob, const Duration(milliseconds: 500));
      port.deliver(_bob, bump: _bump(49));
      async.flushMicrotasks();
      expect(event(c), isA<BumpContact>());
      c.dispose();
    });
  });

  test('an offer that did not go keeps the staging', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      c.read(airdropStagedProvider.notifier).state = [_src()];
      feed(async, c, _bob, const Duration(milliseconds: 500));
      // The link drops between the bumps and the offer.
      port.direct.remove(_bob);
      port.deliver(_bob, bump: _bump(42));
      async.flushMicrotasks();
      expect(event(c), isA<BumpSentFiles>());
      expect(port.offersTo(_bob), isEmpty);
      expect(c.read(airdropStagedProvider), hasLength(1));
      c.dispose();
    });
  });

  test('our offer waits for our bump, however slow our card is', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final card = Completer<Uint8List>();
      final c = make(async, port, ownCard: () => card.future);
      c.read(bumpControllerProvider);
      c.read(airdropStagedProvider.notifier).state = [_src()];
      port.deliver(_bob, bump: _bump(43));
      feed(async, c, _bob, const Duration(milliseconds: 500));
      expect(event(c), isA<BumpSentFiles>(), reason: 'fired as ours went');
      expect(port.sent, isEmpty, reason: 'neither bump nor offer yet');
      card.complete(_ownCard);
      async.flushMicrotasks();
      expect(port.sent.first.bump, isNotNull);
      expect(port.sent.last.offer, isNotNull);
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

  test('a bad card costs only the contact card, not their files', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port, check: (card, sender) async => false);
      c.read(bumpControllerProvider);
      feed(async, c, _bob, const Duration(milliseconds: 500));
      port.deliver(_bob, bump: _bump(44, hasFiles: true));
      async.flushMicrotasks();
      expect(event(c), isA<BumpReceivingFiles>());
      c.dispose();
    });
  });

  test('"not theirs" is written once per person per five seconds', () {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) {
      if (m != null && m.contains('not theirs')) lines.add(m);
    };
    addTearDown(() => debugPrint = previous);
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port, check: (card, sender) async => false);
      c.read(bumpControllerProvider);
      // Held together for 4.5 s while Bob's phone keeps sending forged cards.
      for (var i = 0; i < 9; i++) {
        feed(async, c, _bob, const Duration(milliseconds: 500));
        port.deliver(_bob, bump: _bump(60 + i));
        async.flushMicrotasks();
      }
      expect(lines, hasLength(1));
      c.dispose();
    });
  });

  test('nothing is added until addContact, and then exactly their card', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final added = <Uint8List>[];
      final c = make(
        async,
        port,
        addContact: (card) async {
          added.add(card);
          return _bob;
        },
      );
      final ctl = c.read(bumpControllerProvider.notifier);
      feed(async, c, _bob, const Duration(milliseconds: 500));
      port.deliver(_bob, bump: _bump(45));
      async.flushMicrotasks();
      expect(event(c), isA<BumpContact>());
      async.elapse(const Duration(seconds: 10));
      expect(added, isEmpty);

      String? hex;
      unawaited(ctl.addContact().then((v) => hex = v));
      async.flushMicrotasks();
      expect(added.single, _theirCard);
      expect(hex, _bob);
      expect(event(c), isNull);

      // No card on screen: nothing to add.
      unawaited(ctl.addContact());
      async.flushMicrotasks();
      expect(added, hasLength(1));
      c.dispose();
    });
  });

  test('a louder phone nobody can name blocks the bump', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      final ctl = c.read(bumpControllerProvider.notifier);
      for (var i = 0; i < 15; i++) {
        ctl
          ..sample(_bob, -38)
          ..sample('${bumpAnonPrefix}AA:BB', -30);
        async.elapse(tick);
      }
      expect(port.sent, isEmpty);
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

  test('a card check still running when the page closes shows nothing', () {
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
      expect(event(c), isNull);
      c.dispose();
    });
  });

  test('a card check still running at dispose touches nothing', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final gate = Completer<bool>();
      final c = make(async, port, check: (card, sender) => gate.future);
      c.read(bumpControllerProvider);
      feed(async, c, _bob, const Duration(milliseconds: 500));
      port.deliver(_bob, bump: _bump(16));
      async.flushMicrotasks();
      c.dispose();
      gate.complete(true);
      async.flushMicrotasks();
    });
  });

  test('the tick runs only while the page is on; leaving keeps the staging',
      () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      expect(async.periodicTimerCount, 1);
      c.read(airdropStagedProvider.notifier).state = [_src()];
      feed(async, c, _bob, const Duration(milliseconds: 1000));
      expect(c.read(bumpControllerProvider).warmth, 1);

      // What Android's file picker does to the page: it pauses the app.
      c.read(airdropPageOnScreenProvider.notifier).state = false;
      expect(async.periodicTimerCount, 0);
      expect(c.read(airdropStagedProvider), hasLength(1));
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
          (hex: _bob, device: 'AA', rssi: -35, seen: start),
          (hex: _eve, device: 'EE', rssi: -90, seen: start.add(tick * i)),
        ];
        async.elapse(tick);
      }
      expect(port.bumpsTo(_bob), isEmpty);

      for (var i = 0; i < 10; i++) {
        c.read(_readings.notifier).state = [
          (
            hex: _bob,
            device: 'AA',
            rssi: -35,
            seen: start.add(tick * (20 + i)),
          ),
        ];
        async.elapse(tick);
      }
      expect(port.bumpsTo(_bob), hasLength(1));
      c.dispose();
    });
  });

  test('a phone that resolves is not its own runner-up', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      final start = DateTime(2026, 9, 23, 12);
      // Bob's phone, not yet named: read as anon, touching.
      for (var i = 0; i < 5; i++) {
        c.read(_readings.notifier).state = [
          (
            hex: '${bumpAnonPrefix}AA',
            device: 'AA',
            rssi: -35,
            seen: start.add(tick * i),
          ),
        ];
        async.elapse(tick);
      }
      expect(port.sent, isEmpty, reason: 'nobody to bump yet');

      // The same device, now resolved, at the same RSSI: well inside the
      // three seconds its anon readings would otherwise be held for.
      for (var i = 5; i < 11; i++) {
        c.read(_readings.notifier).state = [
          (hex: _bob, device: 'AA', rssi: -35, seen: start.add(tick * i)),
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
      feed(async, c, _bob, const Duration(seconds: 3), rssi: -50);
      final open = lines.where((l) => l.contains('dBm')).length;
      expect(open, inInclusiveRange(2, 3));
      expect(lines.first, contains('b0b0b0b0 -50 dBm, next -'));

      c.read(airdropPageOnScreenProvider.notifier).state = false;
      lines.clear();
      feed(async, c, _bob, const Duration(seconds: 3), rssi: -50);
      expect(lines, isEmpty);
      c.dispose();
    });
  });

  // Build 1112 wrote one line when a phone appeared and nothing more while
  // it stayed cold, so its log could not say whether readings were still
  // coming. The line now comes once a second while anyone has a reading,
  // with what was heard in that second and what the scan handed over.
  test('the BUMP line keeps coming for someone across the room, with counts',
      () {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) {
      if (m != null && m.startsWith('[BUMP]')) lines.add(m);
    };
    addTearDown(() => debugPrint = previous);
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port, adverts: () => 7);
      c.read(bumpControllerProvider);
      feed(async, c, _bob, const Duration(seconds: 10), rssi: -70);
      final dbm = lines.where((l) => l.contains('dBm')).toList();
      expect(dbm.length, inInclusiveRange(9, 10));
      expect(
        dbm.last,
        matches(
          RegExp(r'^\[BUMP\] b0b0b0b0 -70 dBm, next -, last -70, '
              r'heard (9|10|11)/s, scan 7 adv/s, samples 0/3, link ready$'),
        ),
      );

      // Gone quiet: the held reading still says so, then the lines stop.
      lines.clear();
      async.elapse(const Duration(seconds: 6));
      expect(lines, contains(contains('heard 0/s')));
      final quiet = lines.length;
      async.elapse(const Duration(seconds: 5));
      expect(lines, hasLength(quiet));
      c.dispose();
    });
  });

  test('the BUMP line says which half of a bump is missing', () {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) {
      if (m != null && m.startsWith('[BUMP]') && m.contains('dBm')) {
        lines.add(m);
      }
    };
    addTearDown(() => debugPrint = previous);

    // Held close with a session: every loud reading counted, link ready.
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      feed(async, c, _bob, const Duration(seconds: 2));
      // The first line lands before the window has filled.
      expect(lines.first, matches(RegExp(r'samples [0-2]/3, link ready$')));
      expect(
        lines.where((l) => l.endsWith(' CLOSE')),
        everyElement(matches(RegExp(r'samples ([3-9]|\d\d+)/3, link ready'))),
      );
      expect(lines.where((l) => l.endsWith(' CLOSE')), isNotEmpty);
      c.dispose();
    });

    // The same distance with nobody to carry the bump: link waiting.
    lines.clear();
    fakeAsync((async) {
      final c = make(async, _Port(), direct: const {});
      c.read(bumpControllerProvider);
      feed(async, c, _bob, const Duration(seconds: 2));
      expect(lines, isNotEmpty);
      expect(lines, everyElement(contains('link waiting')));
      c.dispose();
    });
  });

  test('a 1 dB wobble does not move the glow', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      feed(async, c, _bob, const Duration(seconds: 2), rssi: -50);
      final changes = <double>[];
      c.listen<BumpState>(
        bumpControllerProvider,
        (_, s) => changes.add(s.warmth),
      );
      final ctl = c.read(bumpControllerProvider.notifier);
      for (var i = 0; i < 40; i++) {
        ctl.sample(_bob, i.isEven ? -50 : -51);
        async.elapse(tick);
      }
      expect(changes, isEmpty);
      c.dispose();
    });
  });

  group('dialling a phone held close', () {
    final start = DateTime(2026, 9, 23, 12);

    /// [device] read at [rssi] every 100 ms for [n] readings, starting at
    /// reading [from], filed under [hex].
    void readings(
      FakeAsync async,
      ProviderContainer c, {
      required String hex,
      required String device,
      required int from,
      required int n,
      int rssi = -35,
    }) {
      for (var i = from; i < from + n; i++) {
        c.read(_readings.notifier).state = [
          (hex: hex, device: device, rssi: rssi, seen: start.add(tick * i)),
        ];
        async.elapse(tick);
      }
    }

    test('a stranger held close is dialled, at most once per 10 s', () {
      fakeAsync((async) {
        final port = _Port();
        final dials = <(String, String?)>[];
        final c = make(
          async,
          port,
          direct: const {},
          dial: (device, hex) async {
            dials.add((device, hex));
            return null;
          },
        );
        c.read(bumpControllerProvider);
        readings(async, c,
            hex: '${bumpAnonPrefix}AA', device: 'AA', from: 0, n: 15);
        expect(dials, [('AA', null)]);
        // Still held there: no second dial inside the ten seconds.
        readings(async, c,
            hex: '${bumpAnonPrefix}AA', device: 'AA', from: 15, n: 80);
        expect(dials, hasLength(1));
        readings(async, c,
            hex: '${bumpAnonPrefix}AA', device: 'AA', from: 95, n: 15);
        expect(dials, hasLength(2));
        c.dispose();
      });
    });

    test('a phone that is only in the room is not dialled', () {
      fakeAsync((async) {
        final port = _Port();
        final dials = <String>[];
        final c = make(
          async,
          port,
          direct: const {},
          dial: (device, hex) async {
            dials.add(device);
            return null;
          },
        );
        c.read(bumpControllerProvider);
        readings(
          async,
          c,
          hex: '${bumpAnonPrefix}AA',
          device: 'AA',
          from: 0,
          n: 30,
          rssi: -58,
        );
        expect(dials, isEmpty);
        expect(
          c.read(bumpControllerProvider).warmth,
          0,
          reason: 'nobody bumpable, nobody being dialled: no glow',
        );
        c.dispose();
      });
    });

    test('a close phone that already has a session is not dialled', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final dials = <String>[];
        final c = make(
          async,
          port,
          dial: (device, hex) async {
            dials.add(device);
            return null;
          },
        );
        c.read(bumpControllerProvider);
        readings(async, c, hex: _bob, device: 'BB', from: 0, n: 15);
        expect(dials, isEmpty);
        expect(port.bumpsTo(_bob), hasLength(1));
        c.dispose();
      });
    });

    test('a named phone with no session is dialled by its identity', () {
      fakeAsync((async) {
        final port = _Port();
        final dials = <(String, String?)>[];
        final c = make(
          async,
          port,
          direct: const {},
          dial: (device, hex) async {
            dials.add((device, hex));
            return null;
          },
        );
        c.read(bumpControllerProvider);
        readings(async, c, hex: _eve, device: 'EE', from: 0, n: 15);
        expect(dials, [('EE', _eve)]);
        c.dispose();
      });
    });

    test('the dialled phone glows and, once connected, is bumped by name', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final connected = Completer<String?>();
        final c = make(
          async,
          port,
          dial: (device, hex) => connected.future,
        );
        c.read(bumpControllerProvider);
        readings(async, c,
            hex: '${bumpAnonPrefix}AA', device: 'AA', from: 0, n: 15);
        expect(
          c.read(bumpControllerProvider).warmth,
          1,
          reason: 'being dialled counts for the glow',
        );
        expect(port.sent, isEmpty);

        // The handshake finishes: this device is Bob, though the scan cannot
        // name him yet.
        connected.complete(_bob);
        async.flushMicrotasks();
        readings(async, c,
            hex: '${bumpAnonPrefix}AA', device: 'AA', from: 15, n: 15);
        expect(port.bumpsTo(_bob), hasLength(1));
        c.dispose();
      });
    });

    test('a dial that fails is logged and tried again later', () {
      fakeAsync((async) {
        final port = _Port();
        var dials = 0;
        final c = make(
          async,
          port,
          direct: const {},
          dial: (device, hex) async {
            dials++;
            throw StateError('GATT 133');
          },
        );
        c.read(bumpControllerProvider);
        readings(async, c,
            hex: '${bumpAnonPrefix}AA', device: 'AA', from: 0, n: 115);
        expect(dials, 2);
        c.dispose();
      });
    });
  });

  test(
      'two phones: the one with files feels it second, the stranger\'s '
      'offer is still taken without asking', () {
    fakeAsync((async) {
      const alice =
          'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1';
      final aPort = _Port()
        ..me = alice
        ..direct.add(_bob);
      final bPort = _Port()
        ..me = _bob
        ..direct.add(alice);
      aPort.other = bPort;
      bPort.other = aPort;
      // Alice's card is slow to build, as a real signed announcement is.
      final a = make(
        async,
        aPort,
        direct: {_bob},
        ownCard: () =>
            Future.delayed(const Duration(milliseconds: 900), () => _ownCard),
      );
      // Bob: contacts only, and Alice is not one of them. His card check
      // takes as long as an Ed25519 verify might — it must not stand between
      // her bump and her offer.
      final b = make(
        async,
        bPort,
        direct: {alice},
        check: (card, sender) =>
            Future.delayed(const Duration(milliseconds: 20), () => true),
      );
      a.read(bumpControllerProvider);
      b.read(bumpControllerProvider);
      b.read(airdropControllerProvider);
      a.read(airdropStagedProvider.notifier).state = [_src()];

      // Bob's phone reads "close" first; Alice's half a second later.
      feed(async, b, alice, const Duration(milliseconds: 500));
      expect(bPort.bumpsTo(alice), hasLength(1));
      feed(async, a, _bob, const Duration(milliseconds: 1000));
      async.flushMicrotasks();

      expect(a.read(bumpControllerProvider).event, isA<BumpSentFiles>());
      expect(b.read(bumpControllerProvider).event, isA<BumpReceivingFiles>());
      final kinds = [
        for (final s in bPort.sent)
          if (s.answer != null) s.answer!.kind,
      ];
      expect(kinds, contains(NearbyAnswerKind.accepted));
      expect(kinds, isNot(contains(NearbyAnswerKind.declined)));
      expect(b.read(airdropControllerProvider).requests, isEmpty);
      a.dispose();
      b.dispose();
    });
  });

  test('a phone reading -50 dBm answers the touching phone and sends its file',
      () {
    fakeAsync((async) {
      const alice =
          'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1';
      final aPort = _Port()
        ..me = alice
        ..direct.add(_bob);
      final bPort = _Port()
        ..me = _bob
        ..direct.add(alice);
      aPort.other = bPort;
      bPort.other = aPort;
      final a = make(async, aPort, direct: {_bob});
      final b = make(async, bPort, direct: {alice});
      a.read(bumpControllerProvider);
      b.read(bumpControllerProvider);
      b.read(airdropControllerProvider);
      a.read(airdropStagedProvider.notifier).state = [_src()];

      // The September 25 phone logs: Alice heard -48..-55 while Bob briefly
      // got three -40 readings. Alice never reached CLOSE, despite a ready link.
      feed(async, a, _bob, const Duration(milliseconds: 600), rssi: -50);
      expect(aPort.bumpsTo(_bob), isEmpty);
      feed(async, b, alice, const Duration(milliseconds: 500), rssi: -35);
      async.flushMicrotasks();

      expect(aPort.bumpsTo(_bob), hasLength(1));
      expect(a.read(bumpControllerProvider).event, isA<BumpSentFiles>());
      expect(b.read(bumpControllerProvider).event, isA<BumpReceivingFiles>());
      expect(aPort.offersTo(_bob), hasLength(1));
      a.dispose();
      b.dispose();
    });
  });

  test('a touching phone cannot wake a peer with only a held weak reading', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      feed(async, c, _bob, const Duration(milliseconds: 500), rssi: -50);
      async.elapse(const Duration(seconds: 2));
      port.deliver(_bob, bump: _bump(72, hasFiles: true));
      async.flushMicrotasks();
      expect(port.bumpsTo(_bob), isEmpty);
      expect(event(c), isNull);
      c.dispose();
    });
  });
  test(
      'a fresh weak reading can complete a bump received before enough samples',
      () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      c.read(bumpLedgerProvider);
      c.read(bumpControllerProvider.notifier).sample(_bob, -50);
      port.deliver(_bob, bump: _bump(73, hasFiles: true));
      expect(port.bumpsTo(_bob), isEmpty);
      feed(async, c, _bob, const Duration(milliseconds: 500), rssi: -50);
      async.flushMicrotasks();
      expect(port.bumpsTo(_bob), hasLength(1));
      expect(event(c), isA<BumpReceivingFiles>());
      c.dispose();
    });
  });

  test('an authenticated bump does not trigger a reply at -60 dBm', () {
    fakeAsync((async) {
      final port = _Port()..direct.add(_bob);
      final c = make(async, port);
      c.read(bumpControllerProvider);
      feed(async, c, _bob, const Duration(milliseconds: 700), rssi: -60);
      port.deliver(_bob, bump: _bump(74, hasFiles: true));
      async.flushMicrotasks();
      expect(port.bumpsTo(_bob), isEmpty);
      expect(event(c), isNull);
      c.dispose();
    });
  });
  test('the scan\'s readings: named by identity, the rest as anon', () {
    final seen = DateTime(2026, 9, 23, 12);
    final c = ProviderContainer(
      overrides: [
        peerDiscoveryControllerProvider.overrideWith(
          () => _Discovery([
            DiscoveredPeer(
              id: 'AA',
              advertisedName: 'x',
              rssi: -40,
              lastSeen: seen,
              resolvedPubkeyHex: _bob,
            ),
            DiscoveredPeer(
              id: 'BB',
              advertisedName: 'y',
              rssi: -30,
              lastSeen: seen,
            ),
            DiscoveredPeer(
              id: 'CC',
              advertisedName: 'z',
              rssi: DiscoveredPeer.unknownRssi,
              lastSeen: seen,
            ),
          ]),
        ),
      ],
    );
    addTearDown(c.dispose);
    expect(c.read(bumpReadingsProvider), [
      (hex: _bob, device: 'AA', rssi: -40, seen: seen),
      (hex: '${bumpAnonPrefix}BB', device: 'BB', rssi: -30, seen: seen),
    ]);
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
