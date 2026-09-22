import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/core/transport/nearby_offer.dart';
import 'package:cubechat/core/util/free_space.dart';
import 'package:cubechat/features/airdrop/data/airdrop_clock.dart';
import 'package:cubechat/features/airdrop/data/airdrop_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_history_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_port.dart';
import 'package:cubechat/features/airdrop/data/airdrop_receive_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_source.dart';
import 'package:cubechat/features/airdrop/data/airdrop_spam_store.dart';
import 'package:cubechat/features/airdrop/data/airdrop_storage.dart';
import 'package:cubechat/features/airdrop/domain/airdrop_spam_guard.dart';
import 'package:cubechat/features/airdrop/domain/airdrop_transfer.dart';
import 'package:cubechat/features/files/data/file_transfer_controller.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _bob = 'b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0';
const _eve = 'e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0';

Uint8List _id(int seed) => Uint8List.fromList(
      List.generate(nearbyIdLen, (i) => (seed * 37 + i * 3) & 0xFF),
    );

NearbyOffer _offer(int seed, {int files = 2, int size = 10}) => NearbyOffer(
      transferId: _id(seed),
      files: [
        for (var i = 0; i < files; i++)
          NearbyOfferFile(
            mediaId: _id(seed * 10 + i + 1),
            size: size,
            name: 'f$i.jpg',
            mime: 'image/jpeg',
          ),
      ],
    );

class _Port implements AirDropPort {
  // Created inside the fake zone by each test, sync so a delivery is handled
  // before the next line runs.
  final inboundCtl = StreamController<NearbyInbound>.broadcast(sync: true);
  final direct = <String>{};
  final sent = <({String to, NearbyOffer? offer, NearbyAnswer? answer})>[];
  final filesSent = <String>[];
  final cancelled = <String>[];
  final failing = <String>{};
  NearbyFileSink? currentSink;

  void deliver(
    String from, {
    NearbyOffer? offer,
    NearbyAnswer? answer,
    bool isDirect = true,
  }) =>
      inboundCtl.add(
        NearbyInbound(
          peerHex: from,
          direct: isDirect,
          offer: offer,
          answer: answer,
        ),
      );

  void answer(
    String from,
    Uint8List transferId,
    NearbyAnswerKind kind, [
    NearbyDeclineReason reason = NearbyDeclineReason.user,
  ]) =>
      deliver(
        from,
        answer: NearbyAnswer(
          transferId: transferId,
          kind: kind,
          reason: reason,
        ),
      );

  List<NearbyAnswer> answersTo(String hex) => [
        for (final s in sent)
          if (s.to == hex && s.answer != null) s.answer!,
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
  }) async {
    if (!direct.contains(peerHex)) return false;
    sent.add((to: peerHex, offer: offer, answer: answer));
    return true;
  }

  @override
  Future<bool> sendFile(
    String peerHex, {
    required File file,
    required AirDropFile meta,
    required String peerName,
  }) async {
    filesSent.add(meta.mediaIdHex);
    return !failing.contains(meta.mediaIdHex);
  }

  @override
  void cancelFile(String mediaIdHex) => cancelled.add(mediaIdHex);

  @override
  set sink(NearbyFileSink? value) => currentSink = value;
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
  _Receive(this.everyone);

  final bool everyone;

  @override
  AirDropReceive build() =>
      AirDropReceive(everyoneUntil: everyone ? DateTime(2100) : null);
}

class _MemTransfers extends FileTransferController {
  @override
  Map<String, FileTransferTask> build() => const {};
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cubechat_airdrop_ctl_');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  /// [async] drives the clock in the fake-zone tests: `DateTime.now()` does
  /// not move under `fakeAsync`, and bans, stalls and acceptances are all
  /// measured against it.
  ProviderContainer make(
    _Port port, {
    FakeAsync? async,
    bool everyone = false,
    Set<String> contacts = const {_bob},
    int? free,
  }) =>
      ProviderContainer(
        overrides: [
          if (async != null)
            airdropClockProvider.overrideWithValue(
              () => DateTime(2026, 9, 22, 12).add(async.elapsed),
            ),
          airdropPortProvider.overrideWithValue(port),
          airdropHistoryProvider.overrideWith(_MemHistory.new),
          airdropSpamProvider.overrideWith(_MemSpam.new),
          airdropReceiveProvider.overrideWith(() => _Receive(everyone)),
          airdropContactsProvider.overrideWithValue(contacts),
          airdropPeerNameProvider.overrideWithValue((_) => 'Жека'),
          airdropNotifyProvider.overrideWithValue((_) {}),
          freeSpaceProvider.overrideWithValue(() async => free),
          airdropDirectoryProvider.overrideWithValue(() async => dir),
          fileTransferControllerProvider.overrideWith(_MemTransfers.new),
        ],
      );

  AirDropSource src(String name) => AirDropSource(
        file: File('${dir.path}${Platform.pathSeparator}$name'),
        name: name,
        size: 10,
        mime: 'image/jpeg',
      );

  group('sending', () {
    test('seen, accepted, every file goes, and the history says sent', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async);
        final ctl = c.read(airdropControllerProvider.notifier);
        unawaited(
          ctl.offer(
            peerHex: _bob,
            peerName: 'Боб',
            files: [src('a.jpg'), src('b.jpg')],
          ),
        );
        async.flushMicrotasks();
        final offer = port.sent.single.offer!;
        expect(offer.files.map((f) => f.name), ['a.jpg', 'b.jpg']);

        port.answer(_bob, offer.transferId, NearbyAnswerKind.seen);
        async.flushMicrotasks();
        expect(
          c.read(airdropControllerProvider).transfers.single.phase,
          AirDropPhase.waiting,
        );

        port.answer(_bob, offer.transferId, NearbyAnswerKind.accepted);
        async.flushMicrotasks();
        expect(port.filesSent, [
          for (final f in offer.files) nearbyHex(f.mediaId),
        ]);
        expect(c.read(airdropControllerProvider).transfers, isEmpty);
        expect(
          c.read(airdropHistoryProvider).single.outcome,
          AirDropOutcome.sent,
        );
        c.dispose();
      });
    });

    test('no seen in ten seconds says unheard; nothing at all fails it', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async);
        unawaited(
          c.read(airdropControllerProvider.notifier).offer(
            peerHex: _bob,
            peerName: 'Боб',
            files: [src('a.jpg')],
          ),
        );
        async.elapse(const Duration(seconds: 10));
        expect(
          c.read(airdropControllerProvider).transfers.single.phase,
          AirDropPhase.unheard,
        );
        async.elapse(const Duration(seconds: 60));
        expect(c.read(airdropControllerProvider).transfers, isEmpty);
        expect(
          c.read(airdropHistoryProvider).single.outcome,
          AirDropOutcome.failed,
        );
        c.dispose();
      });
    });

    test('a decline comes back with its reason', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async);
        unawaited(
          c.read(airdropControllerProvider.notifier).offer(
            peerHex: _bob,
            peerName: 'Боб',
            files: [src('a.jpg')],
          ),
        );
        async.flushMicrotasks();
        port.answer(
          _bob,
          port.sent.single.offer!.transferId,
          NearbyAnswerKind.declined,
          NearbyDeclineReason.noSpace,
        );
        async.flushMicrotasks();
        final entry = c.read(airdropHistoryProvider).single;
        expect(entry.outcome, AirDropOutcome.declined);
        expect(entry.reason, NearbyDeclineReason.noSpace);
        c.dispose();
      });
    });

    test('a broken link interrupts; a retry sends only what did not go', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async);
        final ctl = c.read(airdropControllerProvider.notifier);
        unawaited(
          ctl.offer(
            peerHex: _bob,
            peerName: 'Боб',
            files: [src('a.jpg'), src('b.jpg')],
          ),
        );
        async.flushMicrotasks();
        final offer = port.sent.single.offer!;
        final second = nearbyHex(offer.files[1].mediaId);
        port.failing.add(second);
        port.answer(_bob, offer.transferId, NearbyAnswerKind.accepted);
        async.flushMicrotasks();
        final t = c.read(airdropControllerProvider).transfers.single;
        expect(t.phase, AirDropPhase.interrupted);
        expect(t.doneCount, 1);

        port.failing.clear();
        unawaited(ctl.retry(t.id));
        async.flushMicrotasks();
        expect(port.filesSent.last, second);
        expect(port.filesSent, hasLength(3));
        expect(port.sent.where((s) => s.offer != null), hasLength(1));
        expect(
          c.read(airdropHistoryProvider).single.outcome,
          AirDropOutcome.sent,
        );
        c.dispose();
      });
    });

    test('without a direct link nothing is offered', () {
      fakeAsync((async) {
        final port = _Port();
        final c = make(port, async: async);
        AirDropTransfer? result;
        unawaited(
          c
              .read(airdropControllerProvider.notifier)
              .offer(peerHex: _bob, peerName: 'Боб', files: [src('a.jpg')])
              .then((v) => result = v),
        );
        async.flushMicrotasks();
        expect(result, isNull);
        expect(port.sent, isEmpty);
        c.dispose();
      });
    });
  });

  group('receiving', () {
    test('a contact: seen at once, the card, then accepted', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async);
        c.read(airdropControllerProvider);
        port.deliver(_bob, offer: _offer(1));
        async.flushMicrotasks();
        expect(port.answersTo(_bob).single.kind, NearbyAnswerKind.seen);
        final request = c.read(airdropControllerProvider).requests.single;
        expect(request.peerName, 'Жека');

        unawaited(
          c.read(airdropControllerProvider.notifier).accept(request.id),
        );
        async.flushMicrotasks();
        expect(port.answersTo(_bob).last.kind, NearbyAnswerKind.accepted);
        final sink = port.currentSink!;
        final fileHex = request.files.first.mediaIdHex;
        expect(
          sink.judge(mediaIdHex: fileHex, senderHex: _bob, direct: true),
          NearbyFileVerdict.keep,
        );
        expect(
          sink.judge(mediaIdHex: fileHex, senderHex: _eve, direct: true),
          NearbyFileVerdict.refuse,
        );
        expect(
          sink.judge(mediaIdHex: fileHex, senderHex: _bob, direct: false),
          NearbyFileVerdict.refuse,
        );
        expect(
          sink.judge(mediaIdHex: 'ff' * 16, senderHex: _bob, direct: true),
          NearbyFileVerdict.notNearby,
        );
        c.dispose();
      });
    });

    test('a file for a request nobody accepted yet is refused', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async);
        c.read(airdropControllerProvider);
        port.deliver(_bob, offer: _offer(2));
        async.flushMicrotasks();
        final fileHex = c
            .read(airdropControllerProvider)
            .requests
            .single
            .files
            .first
            .mediaIdHex;
        expect(
          port.currentSink!
              .judge(mediaIdHex: fileHex, senderHex: _bob, direct: true),
          NearbyFileVerdict.refuse,
        );
        c.dispose();
      });
    });

    test('an offer that did not come straight from the phone is ignored', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async);
        c.read(airdropControllerProvider);
        port.deliver(_bob, offer: _offer(3), isDirect: false);
        async.flushMicrotasks();
        expect(port.sent, isEmpty);
        expect(c.read(airdropControllerProvider).transfers, isEmpty);
        c.dispose();
      });
    });

    test('a stranger in contacts-only mode is told so', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_eve);
        final c = make(port, async: async);
        c.read(airdropControllerProvider);
        port.deliver(_eve, offer: _offer(4));
        async.flushMicrotasks();
        final answers = port.answersTo(_eve);
        expect(answers.first.kind, NearbyAnswerKind.seen);
        expect(answers.last.kind, NearbyAnswerKind.declined);
        expect(answers.last.reason, NearbyDeclineReason.contactsOnly);
        expect(c.read(airdropControllerProvider).requests, isEmpty);
        c.dispose();
      });
    });

    test('a stranger while "everyone" is on gets the card', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_eve);
        final c = make(port, async: async, everyone: true);
        c.read(airdropControllerProvider);
        port.deliver(_eve, offer: _offer(5));
        async.flushMicrotasks();
        expect(c.read(airdropControllerProvider).requests, hasLength(1));
        c.dispose();
      });
    });

    test('a second offer while the first waits is busy', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async);
        c.read(airdropControllerProvider);
        port
          ..deliver(_bob, offer: _offer(6))
          ..deliver(_bob, offer: _offer(7));
        async.flushMicrotasks();
        expect(c.read(airdropControllerProvider).requests, hasLength(1));
        expect(port.answersTo(_bob).last.reason, NearbyDeclineReason.busy);
        c.dispose();
      });
    });

    test('an offer bigger than the free space is declined for it', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async, free: 15);
        c.read(airdropControllerProvider);
        port.deliver(_bob, offer: _offer(8));
        async.flushMicrotasks();
        expect(port.answersTo(_bob).last.reason, NearbyDeclineReason.noSpace);
        expect(c.read(airdropControllerProvider).requests, isEmpty);
        c.dispose();
      });
    });

    test('sixty seconds without an answer declines for the person', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_eve);
        final c = make(port, async: async, everyone: true);
        c.read(airdropControllerProvider);
        port.deliver(_eve, offer: _offer(9));
        async.elapse(const Duration(seconds: 60));
        expect(port.answersTo(_eve).last.reason, NearbyDeclineReason.timeout);
        expect(c.read(airdropControllerProvider).requests, isEmpty);
        // An offer left to expire says nothing about the sender.
        expect(
          c.read(airdropSpamProvider.notifier).recordFor(_eve)?.declines,
          0,
        );
        c.dispose();
      });
    });

    test('three declines of a stranger: silence for ten minutes', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_eve);
        final c = make(port, async: async, everyone: true);
        final ctl = c.read(airdropControllerProvider.notifier);
        for (var i = 0; i < 3; i++) {
          port.deliver(_eve, offer: _offer(20 + i));
          async.flushMicrotasks();
          final id = c.read(airdropControllerProvider).requests.single.id;
          unawaited(ctl.decline(id));
          async.flushMicrotasks();
        }
        final before = port.sent.length;
        port.deliver(_eve, offer: _offer(30));
        async.flushMicrotasks();
        expect(port.sent.length, before, reason: 'not even a seen');
        expect(c.read(airdropControllerProvider).requests, isEmpty);

        async.elapse(const Duration(minutes: 10));
        port.deliver(_eve, offer: _offer(31));
        async.flushMicrotasks();
        expect(c.read(airdropControllerProvider).requests, hasLength(1));
        c.dispose();
      });
    });

    test('sixty seconds without a piece interrupts and drops the unfinished',
        () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async);
        c.read(airdropControllerProvider);
        port.deliver(_bob, offer: _offer(40));
        async.flushMicrotasks();
        final request = c.read(airdropControllerProvider).requests.single;
        unawaited(
          c.read(airdropControllerProvider.notifier).accept(request.id),
        );
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 65));
        final t = c.read(airdropControllerProvider).transfers.single;
        expect(t.phase, AirDropPhase.interrupted);
        expect(port.cancelled, [for (final f in request.files) f.mediaIdHex]);
        // Still accepted: a retry from the sender goes straight in.
        expect(
          port.currentSink!.judge(
            mediaIdHex: request.files.first.mediaIdHex,
            senderHex: _bob,
            direct: true,
          ),
          NearbyFileVerdict.keep,
        );
        async.elapse(const Duration(minutes: 10));
        expect(c.read(airdropControllerProvider).transfers, isEmpty);
        expect(
          c.read(airdropHistoryProvider).single.outcome,
          AirDropOutcome.failed,
        );
        c.dispose();
      });
    });
  });

  // Real time: keep() moves files on disk, and file I/O does not complete
  // inside a fake zone.
  group('keeping files', () {
    Future<(ProviderContainer, _Port, AirDropTransfer)> accepted() async {
      final port = _Port()..direct.add(_bob);
      final c = make(port);
      addTearDown(c.dispose);
      c.read(airdropControllerProvider);
      port.deliver(_bob, offer: _offer(50));
      await Future<void>.delayed(Duration.zero);
      final request = c.read(airdropControllerProvider).requests.single;
      await c.read(airdropControllerProvider.notifier).accept(request.id);
      return (c, port, request);
    }

    Future<File> arrived(String name) async {
      final f = File('${dir.path}${Platform.pathSeparator}tmp-$name');
      await f.writeAsString(name);
      return f;
    }

    test('both files land in the AirDrop folder and the history says received',
        () async {
      final (c, port, request) = await accepted();
      final sink = port.currentSink!;
      for (final f in request.files) {
        final path = await sink.keep(
          mediaIdHex: f.mediaIdHex,
          senderHex: _bob,
          file: await arrived(f.name),
          name: f.name,
        );
        expect(path, endsWith('${Platform.pathSeparator}${f.name}'));
        expect(File(path!).existsSync(), isTrue);
      }
      expect(c.read(airdropControllerProvider).transfers, isEmpty);
      final entry = c.read(airdropHistoryProvider).single;
      expect(entry.outcome, AirDropOutcome.received);
      expect(entry.files.every((f) => f.path != null), isTrue);
    });

    test('taken back half way: what came stays, the rest is not wanted',
        () async {
      final (c, port, request) = await accepted();
      final sink = port.currentSink!;
      await sink.keep(
        mediaIdHex: request.files.first.mediaIdHex,
        senderHex: _bob,
        file: await arrived('first'),
        name: 'first',
      );
      port.answer(_bob, nearbyUnhex(request.id), NearbyAnswerKind.cancelled);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(airdropControllerProvider).transfers, isEmpty);
      expect(
        c.read(airdropHistoryProvider).single.outcome,
        AirDropOutcome.partial,
      );
      expect(
        await sink.keep(
          mediaIdHex: request.files.last.mediaIdHex,
          senderHex: _bob,
          file: await arrived('second'),
          name: 'second',
        ),
        isNull,
      );
      expect(
        sink.judge(
          mediaIdHex: request.files.last.mediaIdHex,
          senderHex: _bob,
          direct: true,
        ),
        NearbyFileVerdict.refuse,
      );
    });
  });
}
