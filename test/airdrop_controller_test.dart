import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
import 'package:cubechat/features/airdrop/data/airdrop_storage.dart';
import 'package:cubechat/features/airdrop/data/bump_ledger.dart';
import 'package:cubechat/features/airdrop/data/wifi_lane.dart';
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

NearbyOffer _offer(int seed, {int files = 2, int size = 10, int flags = 0}) =>
    NearbyOffer(
      transferId: _id(seed),
      flags: flags,
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

  void answer(
    String from,
    Uint8List transferId,
    NearbyAnswerKind kind, [
    NearbyDeclineReason reason = NearbyDeclineReason.user,
    NearbyWifiEndpoint? wifi,
  ]) =>
      deliver(
        from,
        answer: NearbyAnswer(
          transferId: transferId,
          kind: kind,
          reason: reason,
          wifi: wifi,
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
    NearbyBump? bump,
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

  /// The real port cancels the Files-centre row; set to do the same.
  void Function(String mediaIdHex)? onCancel;

  @override
  void cancelFile(String mediaIdHex) {
    cancelled.add(mediaIdHex);
    onCancel?.call(mediaIdHex);
  }

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

/// The channel setting without its Hive box — the real one opens the box in
/// `build()`, and `set()` waits on it, which never finishes in a fake zone.
class _Lane extends AirDropLaneController {
  _Lane(this.initial);

  final AirDropLane initial;

  @override
  AirDropLane build() => initial;

  @override
  Future<void> set(AirDropLane lane) async => state = lane;
}

class _FakeReceiver implements WifiLaneReceiver {
  @override
  int debugOpenBatches = 0;

  bool closed = false;
  final _done = Completer<void>();

  /// What the real one does after the last expected file, or on idle.
  void finish() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  int get port => 4000;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    closed = true;
    finish();
  }
}

class _FakeSender implements WifiLaneSender {
  _FakeSender(this.wifi);

  final _Wifi wifi;
  bool closed = false;
  final _closing = Completer<bool>();

  @override
  Future<bool> sendFile({
    required String mediaIdHex,
    required File file,
    required int size,
    required WifiProgress onProgress,
    required bool Function() cancelled,
  }) async {
    wifi.sentOverWifi.add(mediaIdHex);
    wifi.onSend?.call(mediaIdHex);
    if (cancelled()) return false;
    // A socket whose flush never returns: only close() ends it, as the real
    // sender's _failAll does.
    if (wifi.hangFiles.contains(mediaIdHex)) return _closing.future;
    onProgress(mediaIdHex, size, size);
    return !wifi.failFiles.contains(mediaIdHex);
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_closing.isCompleted) _closing.complete(false);
  }
}

class _Wifi implements AirDropWifi {
  InternetAddress? address = InternetAddress('192.168.1.5');
  final started = <Map<String, int>>[];
  final receivers = <_FakeReceiver>[];
  final senders = <_FakeSender>[];
  final tempDirs = <Directory>[];
  WifiKeep? keep;
  WifiProgress? progress;
  bool connectWorks = true;
  final sentOverWifi = <String>[];
  final failFiles = <String>{};
  final hangFiles = <String>{};
  void Function(String mediaIdHex)? onSend;

  /// Holds localAddress() until completed, to act while a port is opening.
  Completer<void>? hold;
  bool startThrows = false;

  @override
  Future<InternetAddress?> localAddress() async {
    await hold?.future;
    return address;
  }

  @override
  Future<WifiLaneReceiver> startReceiver({
    required InternetAddress address,
    required Uint8List key,
    required Uint8List transferId,
    required Map<String, int> expected,
    required Directory tempDir,
    required WifiProgress onProgress,
    required WifiKeep onFile,
    void Function()? onConnected,
    Duration idle = const Duration(minutes: 2),
  }) async {
    if (startThrows) throw StateError('no port today');
    started.add(expected);
    tempDirs.add(tempDir);
    keep = onFile;
    progress = onProgress;
    final rx = _FakeReceiver();
    receivers.add(rx);
    return rx;
  }

  @override
  Future<WifiLaneSender?> connect({
    required NearbyWifiEndpoint endpoint,
    required Uint8List transferId,
  }) async {
    if (!connectWorks) return null;
    final tx = _FakeSender(this);
    senders.add(tx);
    return tx;
  }
}

NearbyWifiEndpoint _endpoint() => NearbyWifiEndpoint(
      address: '192.168.1.7',
      port: 4001,
      key: Uint8List(NearbyWifiEndpoint.keyLen),
    );

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
    _Wifi? wifi,
    AirDropLane lane = AirDropLane.auto,
    void Function(AirDropTransfer)? notify,
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
          airdropNotifyProvider.overrideWithValue(notify ?? (_) {}),
          freeSpaceProvider.overrideWithValue(() async => free),
          airdropDirectoryProvider.overrideWithValue(() async => dir),
          fileTransferControllerProvider.overrideWith(_MemTransfers.new),
          airdropWifiProvider.overrideWithValue(wifi ?? _Wifi()),
          airdropLaneProvider.overrideWith(() => _Lane(lane)),
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

    // The bump gesture itself: a later task's BumpController handles it.
    // AirDrop must not answer it or start anything on its own.
    test('a bump alone changes nothing — no answer, no transfer', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async);
        c.read(airdropControllerProvider);
        port.deliver(
          _bob,
          bump: NearbyBump(
            bumpId: _id(70),
            hasFiles: true,
            card: Uint8List.fromList([1, 2, 3]),
          ),
        );
        async.flushMicrotasks();
        expect(port.sent, isEmpty);
        expect(c.read(airdropControllerProvider).transfers, isEmpty);
        expect(c.read(airdropControllerProvider).requests, isEmpty);
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

  group('bumped offers', () {
    test('an offer from someone just bumped is taken without asking', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_eve);
        final c = make(port, async: async);
        c.read(airdropControllerProvider);
        c.read(bumpLedgerProvider).note(_eve, c.read(airdropClockProvider)());
        async.elapse(const Duration(seconds: 3));
        port.deliver(_eve, offer: _offer(80));
        async.flushMicrotasks();
        final answers = port.answersTo(_eve);
        expect(answers.last.kind, NearbyAnswerKind.accepted);
        expect(
          answers.any((a) => a.kind == NearbyAnswerKind.declined),
          isFalse,
        );
        expect(c.read(airdropControllerProvider).requests, isEmpty);
        expect(
          c.read(airdropControllerProvider).transfers.single.phase,
          AirDropPhase.transferring,
        );
        c.dispose();
      });
    });

    test('a bumped offer over 200 MB asks first, and is not refused as a '
        'stranger\'s', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_eve);
        final c = make(port, async: async);
        c.read(airdropControllerProvider);
        c.read(bumpLedgerProvider).note(_eve, c.read(airdropClockProvider)());
        // Two files of 101 MiB: 202 MiB, just over the line.
        port.deliver(_eve, offer: _offer(84, size: 101 * 1024 * 1024));
        async.flushMicrotasks();
        final answers = port.answersTo(_eve);
        expect(answers.single.kind, NearbyAnswerKind.seen);
        expect(c.read(airdropControllerProvider).requests, hasLength(1));
        c.dispose();
      });
    });

    test('a bumped offer of exactly 200 MB is still taken without asking', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_eve);
        final c = make(port, async: async);
        c.read(airdropControllerProvider);
        c.read(bumpLedgerProvider).note(_eve, c.read(airdropClockProvider)());
        port.deliver(
          _eve,
          offer: _offer(85, files: 2, size: 100 * 1024 * 1024),
        );
        async.flushMicrotasks();
        expect(port.answersTo(_eve).last.kind, NearbyAnswerKind.accepted);
        expect(c.read(airdropControllerProvider).requests, isEmpty);
        c.dispose();
      });
    });

    test('the same offer eleven seconds after the note is an ordinary '
        'stranger request', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_eve);
        final c = make(port, async: async);
        c.read(airdropControllerProvider);
        c.read(bumpLedgerProvider).note(_eve, c.read(airdropClockProvider)());
        async.elapse(const Duration(seconds: 11));
        port.deliver(_eve, offer: _offer(81));
        async.flushMicrotasks();
        final answers = port.answersTo(_eve);
        expect(answers.first.kind, NearbyAnswerKind.seen);
        expect(answers.last.kind, NearbyAnswerKind.declined);
        expect(answers.last.reason, NearbyDeclineReason.contactsOnly);
        expect(c.read(airdropControllerProvider).requests, isEmpty);
        c.dispose();
      });
    });

    test('an offer from someone else while the ledger holds only the '
        'bumped person is an ordinary request', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async);
        c.read(airdropControllerProvider);
        c.read(bumpLedgerProvider).note(_eve, c.read(airdropClockProvider)());
        port.deliver(_bob, offer: _offer(82));
        async.flushMicrotasks();
        expect(port.answersTo(_bob).last.kind, NearbyAnswerKind.seen);
        expect(c.read(airdropControllerProvider).requests, hasLength(1));
        c.dispose();
      });
    });

    test('a bumped offer is still declined for no space', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_eve);
        final c = make(port, async: async, free: 15);
        c.read(airdropControllerProvider);
        c.read(bumpLedgerProvider).note(_eve, c.read(airdropClockProvider)());
        port.deliver(_eve, offer: _offer(83));
        async.flushMicrotasks();
        expect(port.answersTo(_eve).last.reason, NearbyDeclineReason.noSpace);
        expect(c.read(airdropControllerProvider).requests, isEmpty);
        expect(c.read(airdropControllerProvider).transfers, isEmpty);
        c.dispose();
      });
    });

    test('a bumped offer is still refused when the peer is already busy', () {
      fakeAsync((async) {
        // A contact, not a stranger: for a stranger the contacts-only check
        // runs first and always wins, so it would never reach "busy" at
        // all — that path is exercised by the sequential-offers test below.
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async);
        c.read(airdropControllerProvider);
        // An earlier, ordinary request from Bob is still sitting unanswered.
        port.deliver(_bob, offer: _offer(84));
        async.flushMicrotasks();
        expect(c.read(airdropControllerProvider).requests, hasLength(1));

        c.read(bumpLedgerProvider).note(_bob, c.read(airdropClockProvider)());
        port.deliver(_bob, offer: _offer(85));
        async.flushMicrotasks();
        expect(c.read(airdropControllerProvider).requests, hasLength(1));
        expect(port.answersTo(_bob).last.reason, NearbyDeclineReason.busy);
        c.dispose();
      });
    });

    test('one bump buys exactly one auto-accepted offer', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_eve);
        final c = make(port, async: async);
        c.read(airdropControllerProvider);
        c.read(bumpLedgerProvider).note(_eve, c.read(airdropClockProvider)());
        port.deliver(_eve, offer: _offer(87));
        async.flushMicrotasks();
        expect(port.answersTo(_eve).last.kind, NearbyAnswerKind.accepted);
        expect(c.read(airdropControllerProvider).requests, isEmpty);

        // A second, non-overlapping offer within the same ten seconds: the
        // note was already spent by the first one, so this is an ordinary
        // stranger offer in contacts-only mode.
        async.elapse(const Duration(seconds: 2));
        port.deliver(_eve, offer: _offer(88));
        async.flushMicrotasks();
        final answers = port.answersTo(_eve);
        expect(answers.last.kind, NearbyAnswerKind.declined);
        expect(answers.last.reason, NearbyDeclineReason.contactsOnly);
        expect(c.read(airdropControllerProvider).requests, isEmpty);
        c.dispose();
      });
    });

    test('the ten-second window includes the boundary and excludes past it',
        () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_eve);
        final c = make(port, async: async);
        c.read(airdropControllerProvider);
        c.read(bumpLedgerProvider).note(_eve, c.read(airdropClockProvider)());
        async.elapse(const Duration(seconds: 10));
        port.deliver(_eve, offer: _offer(89));
        async.flushMicrotasks();
        expect(port.answersTo(_eve).last.kind, NearbyAnswerKind.accepted);

        c.read(bumpLedgerProvider).note(_eve, c.read(airdropClockProvider)());
        async.elapse(const Duration(seconds: 10, milliseconds: 1));
        port.deliver(_eve, offer: _offer(90));
        async.flushMicrotasks();
        final answers = port.answersTo(_eve);
        expect(answers.last.kind, NearbyAnswerKind.declined);
        expect(answers.last.reason, NearbyDeclineReason.contactsOnly);
        c.dispose();
      });
    });

    test('a bumped offer with the Wi-Fi flag opens the receiver', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_eve);
        final wifi = _Wifi();
        final c = make(port, async: async, wifi: wifi);
        c.read(airdropControllerProvider);
        c.read(bumpLedgerProvider).note(_eve, c.read(airdropClockProvider)());
        port.deliver(_eve, offer: _offer(91, flags: nearbyFlagWifi));
        async.flushMicrotasks();
        final answer = port.answersTo(_eve).last;
        expect(answer.kind, NearbyAnswerKind.accepted);
        expect(answer.wifi, isNotNull);
        expect(wifi.started, hasLength(1));
        c.dispose();
      });
    });

    test('a bumped offer notifies nobody and arms no answer clock', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_eve);
        final notified = <AirDropTransfer>[];
        final c = make(port, async: async, notify: notified.add);
        c.read(airdropControllerProvider);
        c.read(bumpLedgerProvider).note(_eve, c.read(airdropClockProvider)());
        port.deliver(_eve, offer: _offer(86));
        async.flushMicrotasks();
        expect(notified, isEmpty);
        async.elapse(const Duration(seconds: 61));
        expect(c.read(airdropControllerProvider).transfers, hasLength(1));
        expect(
          port
              .answersTo(_eve)
              .any((a) => a.reason == NearbyDeclineReason.timeout),
          isFalse,
        );
        c.dispose();
      });
    });
  });

  group('wifi', () {
    String sep() => Platform.pathSeparator;

    /// Two files offered to Bob, the offer on the wire.
    (ProviderContainer, _Port, NearbyOffer) offered(
      FakeAsync async,
      _Wifi wifi, {
      AirDropLane lane = AirDropLane.auto,
    }) {
      final port = _Port()..direct.add(_bob);
      final c = make(port, async: async, wifi: wifi, lane: lane);
      unawaited(
        c.read(airdropControllerProvider.notifier).offer(
          peerHex: _bob,
          peerName: 'Боб',
          files: [src('a.jpg'), src('b.jpg')],
        ),
      );
      async.flushMicrotasks();
      return (c, port, port.sent.single.offer!);
    }

    List<String> ids(NearbyOffer offer) =>
        [for (final f in offer.files) nearbyHex(f.mediaId)];

    test('offer sets the Wi-Fi flag unless the lane is Bluetooth', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async);
        final ctl = c.read(airdropControllerProvider.notifier);
        unawaited(
          ctl.offer(peerHex: _bob, peerName: 'Боб', files: [src('a.jpg')]),
        );
        async.flushMicrotasks();
        expect(port.sent.last.offer!.flags & nearbyFlagWifi, 1);

        unawaited(c.read(airdropLaneProvider.notifier).set(AirDropLane.bluetooth));
        unawaited(
          ctl.offer(peerHex: _bob, peerName: 'Боб', files: [src('b.jpg')]),
        );
        async.flushMicrotasks();
        expect(port.sent.last.offer!.flags & nearbyFlagWifi, 0);
        c.dispose();
      });
    });

    test('accepting a flagged offer answers with an endpoint', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final wifi = _Wifi();
        final c = make(port, async: async, wifi: wifi);
        c.read(airdropControllerProvider);
        port.deliver(_bob, offer: _offer(60, flags: nearbyFlagWifi));
        async.flushMicrotasks();
        final request = c.read(airdropControllerProvider).requests.single;
        unawaited(
          c.read(airdropControllerProvider.notifier).accept(request.id),
        );
        async.flushMicrotasks();
        final answer = port.answersTo(_bob).last;
        expect(answer.kind, NearbyAnswerKind.accepted);
        expect(answer.wifi!.address, '192.168.1.5');
        expect(answer.wifi!.port, 4000);
        expect(answer.wifi!.key, hasLength(32));
        expect(wifi.started.single, {
          for (final f in request.files) f.mediaIdHex: 10,
        });
        // Half-received files sit apart from the kept ones.
        expect(wifi.tempDirs.single.path, '${dir.path}${sep()}wifi-in');
        expect(wifi.tempDirs.single.existsSync(), isTrue);
        c.dispose();
      });
    });

    test('no local address: a plain acceptance', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final wifi = _Wifi()..address = null;
        final c = make(port, async: async, wifi: wifi);
        c.read(airdropControllerProvider);
        port.deliver(_bob, offer: _offer(61, flags: nearbyFlagWifi));
        async.flushMicrotasks();
        final request = c.read(airdropControllerProvider).requests.single;
        unawaited(
          c.read(airdropControllerProvider.notifier).accept(request.id),
        );
        async.flushMicrotasks();
        final answer = port.answersTo(_bob).last;
        expect(answer.kind, NearbyAnswerKind.accepted);
        expect(answer.wifi, isNull);
        // Says why, so a Wi-Fi-only sender can tell "no network here" from
        // an app too old to take Wi-Fi at all.
        expect(answer.reason, NearbyDeclineReason.noLocalNetwork);
        expect(wifi.started, isEmpty);
        c.dispose();
      });
    });

    test('an unflagged offer is accepted with no reason at all', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final wifi = _Wifi()..address = null;
        final c = make(port, async: async, wifi: wifi);
        c.read(airdropControllerProvider);
        port.deliver(_bob, offer: _offer(66));
        async.flushMicrotasks();
        final request = c.read(airdropControllerProvider).requests.single;
        unawaited(
          c.read(airdropControllerProvider.notifier).accept(request.id),
        );
        async.flushMicrotasks();
        expect(port.answersTo(_bob).last.reason, NearbyDeclineReason.user);
        c.dispose();
      });
    });

    test('an unflagged offer never opens a port', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final wifi = _Wifi();
        final c = make(port, async: async, wifi: wifi);
        c.read(airdropControllerProvider);
        port.deliver(_bob, offer: _offer(62));
        async.flushMicrotasks();
        final request = c.read(airdropControllerProvider).requests.single;
        unawaited(
          c.read(airdropControllerProvider.notifier).accept(request.id),
        );
        async.flushMicrotasks();
        expect(port.answersTo(_bob).last.wifi, isNull);
        expect(wifi.started, isEmpty);
        c.dispose();
      });
    });

    test('the port closes when the sender takes the transfer back', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final wifi = _Wifi();
        final c = make(port, async: async, wifi: wifi);
        c.read(airdropControllerProvider);
        port.deliver(_bob, offer: _offer(63, flags: nearbyFlagWifi));
        async.flushMicrotasks();
        final request = c.read(airdropControllerProvider).requests.single;
        unawaited(
          c.read(airdropControllerProvider.notifier).accept(request.id),
        );
        async.flushMicrotasks();
        expect(wifi.receivers.single.closed, isFalse);
        port.answer(_bob, nearbyUnhex(request.id), NearbyAnswerKind.cancelled);
        async.flushMicrotasks();
        expect(wifi.receivers.single.closed, isTrue);
        c.dispose();
      });
    });

    test('the wipe and the end of the app close the port', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final wifi = _Wifi();
        final c = make(port, async: async, wifi: wifi);
        final ctl = c.read(airdropControllerProvider.notifier);
        port.deliver(_bob, offer: _offer(64, flags: nearbyFlagWifi));
        async.flushMicrotasks();
        unawaited(
          ctl.accept(c.read(airdropControllerProvider).requests.single.id),
        );
        async.flushMicrotasks();
        ctl.clearAll();
        expect(wifi.receivers.single.closed, isTrue);

        port.deliver(_bob, offer: _offer(65, flags: nearbyFlagWifi));
        async.flushMicrotasks();
        unawaited(
          ctl.accept(c.read(airdropControllerProvider).requests.single.id),
        );
        async.flushMicrotasks();
        expect(wifi.receivers.last.closed, isFalse);
        c.dispose();
        expect(wifi.receivers.last.closed, isTrue);
      });
    });

    test('sender streams over Wi-Fi when the endpoint answers', () {
      fakeAsync((async) {
        final wifi = _Wifi();
        final (c, port, offer) = offered(async, wifi);
        port.answer(
          _bob,
          offer.transferId,
          NearbyAnswerKind.accepted,
          NearbyDeclineReason.user,
          _endpoint(),
        );
        async.flushMicrotasks();
        expect(wifi.sentOverWifi, ids(offer));
        expect(port.filesSent, isEmpty);
        expect(
          c.read(airdropControllerProvider).byId(nearbyHex(offer.transferId)),
          isNull,
        );
        expect(
          c.read(airdropHistoryProvider).single.outcome,
          AirDropOutcome.sent,
        );
        expect(wifi.senders.single.closed, isTrue);
        final tasks = c.read(fileTransferControllerProvider);
        for (final id in ids(offer)) {
          expect(tasks[id]?.status, FileTransferStatus.completed);
          expect(tasks[id]?.source, FileTransferSource.airdrop);
          expect(tasks[id]?.chatId, _bob);
        }
        c.dispose();
      });
    });

    test('while connected the transfer says Wi-Fi', () {
      fakeAsync((async) {
        final wifi = _Wifi();
        final (c, port, offer) = offered(async, wifi);
        final seen = <bool>[];
        c.listen(
          airdropControllerProvider,
          (_, s) {
            final t = s.byId(nearbyHex(offer.transferId));
            if (t != null) seen.add(t.wifi);
          },
        );
        port.answer(
          _bob,
          offer.transferId,
          NearbyAnswerKind.accepted,
          NearbyDeclineReason.user,
          _endpoint(),
        );
        async.flushMicrotasks();
        expect(seen, contains(true));
        c.dispose();
      });
    });

    test('Auto falls back to Bluetooth when connect fails', () {
      fakeAsync((async) {
        final wifi = _Wifi()..connectWorks = false;
        final (c, port, offer) = offered(async, wifi);
        port.answer(
          _bob,
          offer.transferId,
          NearbyAnswerKind.accepted,
          NearbyDeclineReason.user,
          _endpoint(),
        );
        async.flushMicrotasks();
        expect(wifi.sentOverWifi, isEmpty);
        expect(port.filesSent, ids(offer));
        expect(
          c.read(airdropHistoryProvider).single.outcome,
          AirDropOutcome.sent,
        );
        c.dispose();
      });
    });

    test('Auto falls back mid-way', () {
      fakeAsync((async) {
        final wifi = _Wifi();
        final (c, port, offer) = offered(async, wifi);
        final [first, second] = ids(offer);
        wifi.failFiles.add(second);
        port.answer(
          _bob,
          offer.transferId,
          NearbyAnswerKind.accepted,
          NearbyDeclineReason.user,
          _endpoint(),
        );
        async.flushMicrotasks();
        expect(wifi.sentOverWifi, [first, second]);
        expect(port.filesSent, [second]);
        expect(wifi.senders.single.closed, isTrue);
        expect(
          c.read(airdropHistoryProvider).single.outcome,
          AirDropOutcome.sent,
        );
        c.dispose();
      });
    });

    test('Wi-Fi-only fails instead', () {
      fakeAsync((async) {
        final wifi = _Wifi()..connectWorks = false;
        final (c, port, offer) =
            offered(async, wifi, lane: AirDropLane.wifi);
        port.answer(
          _bob,
          offer.transferId,
          NearbyAnswerKind.accepted,
          NearbyDeclineReason.user,
          _endpoint(),
        );
        async.flushMicrotasks();
        expect(port.filesSent, isEmpty);
        expect(port.answersTo(_bob).last.kind, NearbyAnswerKind.cancelled);
        expect(
          c.read(airdropHistoryProvider).single.outcome,
          AirDropOutcome.failed,
        );
        // The transfer leaves the state in the same step it fails; the
        // history line is where the reason is shown from.
        expect(c.read(airdropHistoryProvider).single.noWifiRoute, isTrue);
        c.dispose();
      });
    });

    test('Wi-Fi-only never crawls over Bluetooth, even half way', () {
      fakeAsync((async) {
        final wifi = _Wifi();
        final (c, port, offer) =
            offered(async, wifi, lane: AirDropLane.wifi);
        final [first, second] = ids(offer);
        wifi.failFiles.add(second);
        port.answer(
          _bob,
          offer.transferId,
          NearbyAnswerKind.accepted,
          NearbyDeclineReason.user,
          _endpoint(),
        );
        async.flushMicrotasks();
        expect(wifi.sentOverWifi, [first, second]);
        expect(port.filesSent, isEmpty);
        expect(port.answersTo(_bob).last.kind, NearbyAnswerKind.cancelled);
        expect(
          c.read(airdropHistoryProvider).single.outcome,
          AirDropOutcome.partial,
        );
        // They were connected: a refused or dropped file is not "not on the
        // same network".
        expect(c.read(airdropHistoryProvider).single.noWifiRoute, isFalse);
        expect(
          c.read(fileTransferControllerProvider)[second]?.status,
          FileTransferStatus.failed,
        );
        c.dispose();
      });
    });

    test('Wi-Fi-only with a receiver on no network fails as "not on the '
        'same network"', () {
      fakeAsync((async) {
        final wifi = _Wifi();
        final (c, port, offer) =
            offered(async, wifi, lane: AirDropLane.wifi);
        port.answer(
          _bob,
          offer.transferId,
          NearbyAnswerKind.accepted,
          NearbyDeclineReason.noLocalNetwork,
        );
        async.flushMicrotasks();
        expect(port.filesSent, isEmpty);
        expect(wifi.sentOverWifi, isEmpty);
        final entry = c.read(airdropHistoryProvider).single;
        expect(entry.outcome, AirDropOutcome.failed);
        expect(entry.noWifiRoute, isTrue);
        expect(entry.wifiOldVersion, isFalse);
        c.dispose();
      });
    });

    test('Wi-Fi-only against a build that cannot take Wi-Fi says so', () {
      fakeAsync((async) {
        final wifi = _Wifi();
        final (c, port, offer) =
            offered(async, wifi, lane: AirDropLane.wifi);
        // What 1107/1108 answer to any offer: version 1, reason 0.
        port.answer(_bob, offer.transferId, NearbyAnswerKind.accepted);
        async.flushMicrotasks();
        expect(port.filesSent, isEmpty);
        final entry = c.read(airdropHistoryProvider).single;
        expect(entry.outcome, AirDropOutcome.failed);
        expect(entry.wifiOldVersion, isTrue);
        expect(entry.noWifiRoute, isFalse);
        // It survives the history being written and read back.
        final back = AirDropHistoryEntry.fromJson(entry.toJson());
        expect(back!.wifiOldVersion, isTrue);
        c.dispose();
      });
    });

    test('an endpoint on a public address is never dialled', () {
      fakeAsync((async) {
        final wifi = _Wifi();
        final (c, port, offer) = offered(async, wifi);
        port.answer(
          _bob,
          offer.transferId,
          NearbyAnswerKind.accepted,
          NearbyDeclineReason.user,
          NearbyWifiEndpoint(
            address: '8.8.8.8',
            port: 4001,
            key: Uint8List(NearbyWifiEndpoint.keyLen),
          ),
        );
        async.flushMicrotasks();
        expect(wifi.senders, isEmpty);
        expect(port.filesSent, ids(offer), reason: 'Auto goes by Bluetooth');
        c.dispose();
      });
    });

    test('the lane is the one the offer went out with', () {
      fakeAsync((async) {
        final wifi = _Wifi();
        final (c, port, offer) =
            offered(async, wifi, lane: AirDropLane.bluetooth);
        expect(offer.flags & nearbyFlagWifi, 0);
        unawaited(c.read(airdropLaneProvider.notifier).set(AirDropLane.wifi));
        async.flushMicrotasks();
        port.answer(_bob, offer.transferId, NearbyAnswerKind.accepted);
        async.flushMicrotasks();
        expect(port.filesSent, ids(offer));
        final entry = c.read(airdropHistoryProvider).single;
        expect(entry.outcome, AirDropOutcome.sent);
        expect(entry.noWifiRoute, isFalse);
        c.dispose();
      });
    });

    test('a connection silent for twenty seconds is given up on', () {
      fakeAsync((async) {
        final wifi = _Wifi();
        final (c, port, offer) = offered(async, wifi);
        final [first, second] = ids(offer);
        wifi.hangFiles.add(first);
        port.answer(
          _bob,
          offer.transferId,
          NearbyAnswerKind.accepted,
          NearbyDeclineReason.user,
          _endpoint(),
        );
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 19));
        expect(wifi.senders.single.closed, isFalse);
        expect(port.filesSent, isEmpty);

        async.elapse(const Duration(seconds: 2));
        expect(wifi.senders.single.closed, isTrue);
        // Auto: the stuck file and the rest go over Bluetooth.
        expect(port.filesSent, [first, second]);
        expect(
          c.read(airdropHistoryProvider).single.outcome,
          AirDropOutcome.sent,
        );
        c.dispose();
      });
    });

    test('a Wi-Fi-only connection that goes silent fails', () {
      fakeAsync((async) {
        final wifi = _Wifi();
        final (c, port, offer) =
            offered(async, wifi, lane: AirDropLane.wifi);
        wifi.hangFiles.add(ids(offer).first);
        port.answer(
          _bob,
          offer.transferId,
          NearbyAnswerKind.accepted,
          NearbyDeclineReason.user,
          _endpoint(),
        );
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 21));
        expect(port.filesSent, isEmpty);
        expect(port.answersTo(_bob).last.kind, NearbyAnswerKind.cancelled);
        expect(
          c.read(airdropHistoryProvider).single.outcome,
          AirDropOutcome.failed,
        );
        c.dispose();
      });
    });

    /// A flagged request from Bob, accepted, its port open.
    (ProviderContainer, _Port, AirDropTransfer) receiving(
      FakeAsync async,
      _Wifi wifi,
      int seed,
    ) {
      final port = _Port()..direct.add(_bob);
      final c = make(port, async: async, wifi: wifi);
      port.onCancel =
          (id) => c.read(fileTransferControllerProvider.notifier).cancel(id);
      c.read(airdropControllerProvider);
      port.deliver(_bob, offer: _offer(seed, flags: nearbyFlagWifi));
      async.flushMicrotasks();
      final request = c.read(airdropControllerProvider).requests.single;
      unawaited(c.read(airdropControllerProvider.notifier).accept(request.id));
      async.flushMicrotasks();
      return (c, port, request);
    }

    test('an incoming cancel in the Files centre stops the transfer', () {
      fakeAsync((async) {
        final wifi = _Wifi();
        final (c, port, request) = receiving(async, wifi, 66);
        final first = request.files.first.mediaIdHex;
        wifi.progress!(first, 5, 10);
        c.read(fileTransferControllerProvider.notifier).cancel(first);
        wifi.progress!(first, 8, 10);
        async.flushMicrotasks();
        expect(c.read(airdropControllerProvider).transfers, isEmpty);
        expect(
          c.read(airdropHistoryProvider).single.outcome,
          AirDropOutcome.cancelled,
        );
        expect(port.answersTo(_bob).last.kind, NearbyAnswerKind.cancelled);
        expect(
          c.read(fileTransferControllerProvider)[first]!.status,
          FileTransferStatus.canceled,
        );
        expect(wifi.receivers.single.closed, isTrue);
        c.dispose();
      });
    });

    test('a file whose row was cancelled is not kept', () {
      fakeAsync((async) {
        final wifi = _Wifi();
        final (c, port, request) = receiving(async, wifi, 67);
        final first = request.files.first.mediaIdHex;
        // The last chunk's progress, then the cross, then the whole file.
        wifi.progress!(first, 10, 10);
        c.read(fileTransferControllerProvider.notifier).cancel(first);
        bool? kept;
        unawaited(
          wifi.keep!(first, File('${dir.path}${sep()}x')).then((v) => kept = v),
        );
        async.flushMicrotasks();
        expect(kept, isFalse);
        expect(
          c.read(airdropHistoryProvider).single.outcome,
          AirDropOutcome.cancelled,
        );
        expect(port.answersTo(_bob).last.kind, NearbyAnswerKind.cancelled);
        expect(
          c.read(fileTransferControllerProvider)[first]!.status,
          FileTransferStatus.canceled,
        );
        c.dispose();
      });
    });

    test('bytes after a stall bring the row back instead of stopping', () {
      fakeAsync((async) {
        final wifi = _Wifi();
        final (c, port, request) = receiving(async, wifi, 68);
        final first = request.files.first.mediaIdHex;
        wifi.progress!(first, 5, 10);
        async.elapse(const Duration(seconds: 65));
        expect(
          c.read(airdropControllerProvider).transfers.single.phase,
          AirDropPhase.interrupted,
        );
        expect(
          c.read(fileTransferControllerProvider)[first]!.status,
          FileTransferStatus.canceled,
        );
        wifi.progress!(first, 6, 10);
        async.flushMicrotasks();
        expect(c.read(airdropControllerProvider).transfers, hasLength(1));
        expect(
          c.read(fileTransferControllerProvider)[first]!.status,
          FileTransferStatus.transferring,
        );
        expect(
          port.answersTo(_bob).where((a) => a.kind == NearbyAnswerKind.cancelled),
          isEmpty,
        );
        c.dispose();
      });
    });

    test('a stall does not excuse a later cancel of a file not yet started',
        () {
      fakeAsync((async) {
        final wifi = _Wifi();
        final (c, port, request) = receiving(async, wifi, 71);
        final [a, b] = [for (final f in request.files) f.mediaIdHex];
        final rows = c.read(fileTransferControllerProvider.notifier);
        wifi.progress!(a, 5, 10);
        expect(c.read(fileTransferControllerProvider)[b], isNull);
        async.elapse(const Duration(seconds: 65));
        expect(
          c.read(airdropControllerProvider).transfers.single.phase,
          AirDropPhase.interrupted,
        );

        // The bytes come back, B starts, and then the person cancels B.
        wifi.progress!(a, 6, 10);
        wifi.progress!(b, 1, 10);
        rows.cancel(b);
        wifi.progress!(b, 2, 10);
        bool? kept;
        unawaited(
          wifi.keep!(b, File('${dir.path}${sep()}b')).then((v) => kept = v),
        );
        async.flushMicrotasks();
        expect(c.read(airdropControllerProvider).transfers, isEmpty);
        expect(port.answersTo(_bob).last.kind, NearbyAnswerKind.cancelled);
        expect(kept, isFalse);
        expect(
          c.read(fileTransferControllerProvider)[b]!.status,
          FileTransferStatus.canceled,
        );
        c.dispose();
      });
    });

    test('a cancel pressed before a stall still counts after it', () {
      fakeAsync((async) {
        final wifi = _Wifi();
        final (c, port, request) = receiving(async, wifi, 72);
        final a = request.files.first.mediaIdHex;
        wifi.progress!(a, 5, 10);
        // Pressed while nothing moved, so nothing has read it yet.
        c.read(fileTransferControllerProvider.notifier).cancel(a);
        async.elapse(const Duration(seconds: 65));
        wifi.progress!(a, 6, 10);
        async.flushMicrotasks();
        expect(c.read(airdropControllerProvider).transfers, isEmpty);
        expect(port.answersTo(_bob).last.kind, NearbyAnswerKind.cancelled);
        c.dispose();
      });
    });

    test('a wipe while the port opens: no acceptance, the port closed', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final wifi = _Wifi()..hold = Completer<void>();
        final c = make(port, async: async, wifi: wifi);
        final ctl = c.read(airdropControllerProvider.notifier);
        port.deliver(_bob, offer: _offer(69, flags: nearbyFlagWifi));
        async.flushMicrotasks();
        unawaited(
          ctl.accept(c.read(airdropControllerProvider).requests.single.id),
        );
        async.flushMicrotasks();
        ctl.clearAll();
        wifi.hold!.complete();
        async.flushMicrotasks();
        expect(
          port.answersTo(_bob).map((a) => a.kind),
          [NearbyAnswerKind.seen],
        );
        expect(wifi.receivers.single.closed, isTrue);
        c.dispose();
      });
    });

    test('a port that will not open still accepts, over Bluetooth', () {
      fakeAsync((async) {
        final wifi = _Wifi()..startThrows = true;
        final (c, port, _) = receiving(async, wifi, 70);
        final answer = port.answersTo(_bob).last;
        expect(answer.kind, NearbyAnswerKind.accepted);
        expect(answer.wifi, isNull);
        c.dispose();
      });
    });

    test('a cancel in the Files centre stops the whole transfer', () {
      fakeAsync((async) {
        final wifi = _Wifi();
        final (c, port, offer) = offered(async, wifi);
        wifi.onSend =
            (id) => c.read(fileTransferControllerProvider.notifier).cancel(id);
        port.answer(
          _bob,
          offer.transferId,
          NearbyAnswerKind.accepted,
          NearbyDeclineReason.user,
          _endpoint(),
        );
        async.flushMicrotasks();
        expect(wifi.sentOverWifi, [ids(offer).first]);
        expect(port.filesSent, isEmpty);
        expect(port.answersTo(_bob).last.kind, NearbyAnswerKind.cancelled);
        expect(
          c.read(airdropHistoryProvider).single.outcome,
          AirDropOutcome.cancelled,
        );
        expect(wifi.senders.single.closed, isTrue);
        c.dispose();
      });
    });
  });

  // Real time: keep() moves files on disk, and file I/O does not complete
  // inside a fake zone.
  group('keeping files', () {
    Future<(ProviderContainer, _Port, AirDropTransfer)> accepted({
      _Wifi? wifi,
      int flags = 0,
    }) async {
      final port = _Port()..direct.add(_bob);
      final c = make(port, wifi: wifi);
      addTearDown(c.dispose);
      c.read(airdropControllerProvider);
      port.deliver(_bob, offer: _offer(50, flags: flags));
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

    test('a Wi-Fi file lands through keep()', () async {
      final wifi = _Wifi();
      final (c, _, request) =
          await accepted(wifi: wifi, flags: nearbyFlagWifi);
      final first = request.files.first;
      wifi.progress!(first.mediaIdHex, 5, 10);
      final task = c.read(fileTransferControllerProvider)[first.mediaIdHex]!;
      expect(task.direction, FileTransferDirection.incoming);
      expect(task.source, FileTransferSource.airdrop);
      expect(task.chatId, _bob);
      expect(task.completedUnits, 5);

      expect(await wifi.keep!(first.mediaIdHex, await arrived('w1')), isTrue);
      final kept = c.read(airdropControllerProvider).transfers.single.files.first;
      expect(kept.done, isTrue);
      expect(File(kept.path!).parent.path, dir.path);
      expect(File(kept.path!).existsSync(), isTrue);
      final done = c.read(fileTransferControllerProvider)[first.mediaIdHex]!;
      expect(done.status, FileTransferStatus.completed);
      expect(done.filePath, kept.path);

      // The last one ends the transfer from inside the receiver's own
      // callback: the port must not be closed from there (it would wait on
      // itself), and it closes itself once the sender has heard "kept".
      final last = request.files.last;
      expect(await wifi.keep!(last.mediaIdHex, await arrived('w2')), isTrue);
      expect(c.read(airdropControllerProvider).transfers, isEmpty);
      expect(
        c.read(airdropHistoryProvider).single.outcome,
        AirDropOutcome.received,
      );
      expect(wifi.receivers.single.closed, isFalse);

      // ...and when it does (or its idle timer fires), the deferred close
      // follows.
      wifi.receivers.single.finish();
      await Future<void>.delayed(Duration.zero);
      expect(wifi.receivers.single.closed, isTrue);
    });

    test('a Wi-Fi file after the transfer ended is not kept', () async {
      final wifi = _Wifi();
      final (c, port, request) =
          await accepted(wifi: wifi, flags: nearbyFlagWifi);
      port.answer(_bob, nearbyUnhex(request.id), NearbyAnswerKind.cancelled);
      await Future<void>.delayed(Duration.zero);
      expect(
        await wifi.keep!(request.files.first.mediaIdHex, await arrived('late')),
        isFalse,
      );
      expect(c.read(airdropControllerProvider).transfers, isEmpty);
    });
  });
}
