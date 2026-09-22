import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:cubechat/core/transport/messaging_service.dart';
import 'package:cubechat/core/transport/nearby_offer.dart';
import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/files/data/file_transfer_controller.dart';
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
}
