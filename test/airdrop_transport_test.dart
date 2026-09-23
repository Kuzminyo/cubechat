import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/ble/ble_constants.dart';
import 'package:cubechat/core/ble/ble_peripheral.dart';
import 'package:cubechat/core/crypto/identity_keys.dart';
import 'package:cubechat/core/crypto/identity_service.dart';
import 'package:cubechat/core/crypto/sealed_box.dart';
import 'package:cubechat/core/crypto/signed_payload.dart';
import 'package:cubechat/core/transport/envelope.dart';
import 'package:cubechat/core/transport/frame.dart';
import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:cubechat/core/transport/messaging_service.dart';
import 'package:cubechat/core/transport/nearby_offer.dart';
import 'package:cubechat/core/transport/peer_id.dart';
import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/files/data/file_transfer_controller.dart';
import 'package:cubechat/features/peers/data/known_peers_controller.dart';
import 'package:cubechat/features/peers/data/peripheral_controller.dart';
import 'package:cubechat/features/peers/models/known_peer.dart';
import 'package:cubechat/features/profile/data/relay_settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

class _Offline extends RelaySettingsController {
  @override
  RelaySettings build() =>
      const RelaySettings(enabled: false, urls: RelaySettings.defaultUrls);

  @override
  Future<void> get loaded => Future<void>.value();
}

class _Sink implements NearbyFileSink {
  _Sink(this.verdict);

  final NearbyFileVerdict verdict;
  final asked = <({String mediaIdHex, String senderHex, bool direct})>[];

  @override
  NearbyFileVerdict judge({
    required String mediaIdHex,
    required String senderHex,
    required bool direct,
  }) {
    asked.add((mediaIdHex: mediaIdHex, senderHex: senderHex, direct: direct));
    return verdict;
  }

  @override
  Future<String?> keep({
    required String mediaIdHex,
    required String senderHex,
    required File file,
    required String name,
  }) async =>
      null;
}

/// Stands in for the real BLE peripheral so a test can hand the service a
/// frame "as received over Bluetooth" without a phone. Mirrors the one in
/// circle_retry_identity_test.dart.
class _Peripheral implements BlePeripheral {
  final incoming = StreamController<PeripheralEvent>.broadcast();

  @override
  Stream<PeripheralEvent> events() => incoming.stream;

  @override
  Future<void> stop() async {}

  @override
  Future<bool> notifyInbound(Uint8List bytes) async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Roster extends KnownPeersController {
  _Roster(this.peer);

  final KnownPeer peer;

  @override
  Map<String, KnownPeer> build() => {peer.pubkeyHex: peer};
}

Future<IdentityKeys> _identity() async {
  final x = await X25519().newKeyPair();
  final ed = await Ed25519().newKeyPair();
  return IdentityKeys(
    publicKey: Uint8List.fromList((await x.extractPublicKey()).bytes),
    privateKey: Uint8List.fromList(await x.extractPrivateKeyBytes()),
    signPublicKey: Uint8List.fromList((await ed.extractPublicKey()).bytes),
    signPrivateKey: Uint8List.fromList(await ed.extractPrivateKeyBytes()),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final sender = Uint8List.fromList(List<int>.filled(32, 0xab));
  final senderHex = 'ab' * 32;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_airdrop_tx_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await settleBackgroundStorage();
    try {
      await Hive.close();
    } on FileSystemException {
      // The service closes its own boxes on dispose, unawaited.
    }
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds a just-closed box briefly.
    }
  });

  Future<(ProviderContainer, MessagingService)> start() async {
    final container = ProviderContainer(
      overrides: [
        relaySettingsProvider.overrideWith(_Offline.new),
        messagingServiceProvider.overrideWith((ref) {
          final service = MessagingService(ref);
          ref.onDispose(() => unawaited(service.dispose()));
          return service;
        }),
      ],
    );
    addTearDown(container.dispose);
    await container.read(messagesControllerProvider.notifier).loaded;
    return (container, container.read(messagingServiceProvider));
  }

  (Uint8List, String) fileManifest(int seed) {
    final id = Uint8List.fromList(List<int>.generate(16, (i) => seed + i));
    final manifest = MediaManifest(
      mediaId: id,
      kind: MediaKind.file,
      total: 3,
      mime: 'video/mp4',
      name: 'clip.mp4',
      sha256: Uint8List(32),
    );
    return (manifest.encode(), nearbyHex(id));
  }

  test('with nobody linked there is no direct peer to send to', () async {
    final (_, service) = await start();
    expect(service.hasDirectLinkTo(senderHex), isFalse);
    expect(service.directPeerHexes(), isEmpty);
    expect(
      await service.sendNearbyFrame(
        senderHex,
        answer: NearbyAnswer(
          transferId: Uint8List(nearbyIdLen),
          kind: NearbyAnswerKind.seen,
        ),
      ),
      isFalse,
    );
  });

  test('a file AirDrop refuses is dropped before anything is kept', () async {
    final (container, service) = await start();
    final sink = _Sink(NearbyFileVerdict.refuse);
    service.nearbyFileSink = sink;
    final (bytes, key) = fileManifest(1);
    await service.debugIngestManifest(
      bytes,
      senderPub: sender,
      sentAt: DateTime.now(),
      direct: true,
    );
    expect(sink.asked.single.mediaIdHex, key);
    expect(sink.asked.single.senderHex, senderHex);
    expect(sink.asked.single.direct, isTrue);
    expect(service.debugHasManifest(key), isFalse);
    expect(container.read(fileTransferControllerProvider)[key], isNull);
  });

  test('a file AirDrop keeps is tracked as an AirDrop transfer', () async {
    final (container, service) = await start();
    service.nearbyFileSink = _Sink(NearbyFileVerdict.keep);
    final (bytes, key) = fileManifest(2);
    await service.debugIngestManifest(
      bytes,
      senderPub: sender,
      sentAt: DateTime.now(),
      direct: true,
    );
    expect(service.debugHasManifest(key), isTrue);
    final task = container.read(fileTransferControllerProvider)[key];
    expect(task?.source, FileTransferSource.airdrop);
    expect(task?.direction, FileTransferDirection.incoming);
  });

  test('anything else is an ordinary chat file, as before', () async {
    final (container, service) = await start();
    service.nearbyFileSink = _Sink(NearbyFileVerdict.notNearby);
    final (bytes, key) = fileManifest(3);
    await service.debugIngestManifest(
      bytes,
      senderPub: sender,
      sentAt: DateTime.now(),
    );
    expect(
      container.read(fileTransferControllerProvider)[key]?.source,
      FileTransferSource.chat,
    );
  });

  test(
      'a sealed nearbyBump from a directly-linked peer reaches nearbyInbound '
      'with direct == true', () async {
    final receiver = await _identity();
    final other = await _identity();
    final senderHexId = nearbyHex(other.publicKey);
    final peripheral = _Peripheral();
    final container = ProviderContainer(
      overrides: [
        relaySettingsProvider.overrideWith(_Offline.new),
        blePeripheralProvider.overrideWithValue(peripheral),
        identityProvider.overrideWith((_) async => receiver),
        knownPeersControllerProvider.overrideWith(
          () => _Roster(
            KnownPeer(
              pubkeyHex: senderHexId,
              displayName: 'Bumper',
              lastSeen: DateTime.now(),
              signPublicKey: other.signPublicKey,
            ),
          ),
        ),
        messagingServiceProvider.overrideWith((ref) {
          final service = MessagingService(ref);
          ref.onDispose(() => unawaited(service.dispose()));
          return service;
        }),
      ],
    );
    addTearDown(container.dispose);
    await container.read(messagesControllerProvider.notifier).loaded;
    final service = container.read(messagingServiceProvider);

    final origin = await PeerId.legacy(other.publicKey);
    final dest = await PeerId.legacy(receiver.publicKey);
    // initialTtl == ttl gives traversedHops == 1, one radio hop away — what
    // makes the dispatch read this as `direct: true` (MessageRoute.bluetooth)
    // rather than a mesh relay.
    final msgId = TransportEnvelope.newMsgId(initialTtl: 1);
    final bump = NearbyBump(
      bumpId: Uint8List.fromList(List.generate(nearbyIdLen, (i) => i + 1)),
      hasFiles: true,
      card: Uint8List.fromList(List.generate(40, (i) => i)),
    );
    final signed = await SignedPayload.wrap(
      inner: packInnerPayload(InnerPayloadType.nearbyBump, bump.encode()),
      context: SignedPayload.contextBytes(
        originPubkeyHash: origin,
        destPubkeyHash: dest,
        msgId: msgId,
      ),
      signKeyPair: other.asSignKeyPair(),
      senderEdPub: other.signPublicKey,
    );
    final sealed = await SealedBox.seal(signed, receiver.publicKey);
    final frameBytes = Frame(
      type: FrameType.transport,
      payload: TransportEnvelope(
        originPubkeyHash: origin,
        destPubkeyHash: dest,
        msgId: msgId,
        ttl: 1,
        body: Uint8List.fromList([1, ...sealed]), // 1 == SealedBox cipher tag
      ).encode(),
    ).encode();

    final inbound = Completer<NearbyInbound>();
    final sub = service.nearbyInbound.listen((m) {
      if (!inbound.isCompleted) inbound.complete(m);
    });
    try {
      peripheral.incoming.add(
        PeripheralWrite(
          centralId: 'nearby-peer',
          charUuid: BleConstants.outboundCharUuid,
          data: frameBytes,
        ),
      );
      final result = await inbound.future.timeout(const Duration(seconds: 5));
      expect(result.peerHex, senderHexId);
      expect(result.direct, isTrue);
      expect(result.offer, isNull);
      expect(result.answer, isNull);
      expect(result.bump, isNotNull);
      expect(result.bump!.hasFiles, isTrue);
      expect(
        result.bump!.bumpId,
        Uint8List.fromList(List.generate(nearbyIdLen, (i) => i + 1)),
      );
      expect(
        result.bump!.card,
        Uint8List.fromList(List.generate(40, (i) => i)),
      );
    } finally {
      await sub.cancel();
      await peripheral.incoming.close();
    }
  });
}
