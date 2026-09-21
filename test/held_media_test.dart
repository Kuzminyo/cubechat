import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:cubechat/core/transport/messaging_service.dart';
import 'package:cubechat/features/chat/data/held_media.dart';
import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/profile/data/media_download_settings_controller.dart';
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

/// "Wait for Wi-Fi" holds photos, voice notes, circles and files on the media
/// relays. The manifest of each arrives at once over the conversation relays;
/// the chunks come when the pause ends. The first cut of the pause lost them:
/// a manifest lives five minutes waiting for chunks, and the relay pool drops
/// the second copy of it the media relays hand back on resume as already seen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final sender = Uint8List.fromList(List<int>.filled(32, 0xab));
  final senderHex = 'ab' * 32;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_held_');
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

  (Uint8List, String) photo(int seed) {
    final id = Uint8List.fromList(List<int>.generate(16, (i) => seed + i));
    final manifest = MediaManifest(
      mediaId: id,
      kind: MediaKind.image,
      total: 12,
      mime: 'image/jpeg',
      sha256: Uint8List(32),
    );
    final hex = id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return (manifest.encode(), hex);
  }

  test('without the pause a manifest still gives up after five minutes',
      () async {
    final (_, service) = await start();
    final (bytes, key) = photo(1);
    await service.debugIngestManifest(bytes,
        senderPub: sender, sentAt: DateTime.now());
    service.debugAgeManifestsAndSweep(const Duration(minutes: 6));
    expect(service.debugHasManifest(key), isFalse);
  });

  test('held for Wi-Fi, a manifest outlives the five minutes', () async {
    final (container, service) = await start();
    service.debugMediaPaused = true;
    final (bytes, key) = photo(1);
    await service.debugIngestManifest(bytes,
        senderPub: sender, sentAt: DateTime.now());

    expect(container.read(heldMediaProvider), {senderHex: 1},
        reason: 'the row above the chats has something to say');

    service.debugAgeManifestsAndSweep(const Duration(hours: 5));
    expect(service.debugHasManifest(key), isTrue,
        reason: 'the photo is parked on the relay, not lost');
  });

  test('when the inbox opens, the wait starts over rather than ending',
      () async {
    final (container, service) = await start();
    service.debugMediaPaused = true;
    final (bytes, key) = photo(1);
    await service.debugIngestManifest(bytes,
        senderPub: sender, sentAt: DateTime.now());
    service.debugAgeManifestsAndSweep(const Duration(hours: 5));

    service.debugMediaPaused = false;
    service.debugMediaInboxResumed();
    expect(container.read(heldMediaProvider), isEmpty);
    service.debugAgeManifestsAndSweep(const Duration(minutes: 2));
    expect(service.debugHasManifest(key), isTrue,
        reason: 'five fresh minutes for the chunks now on their way');
  });

  test('a restart does not lose what was held', () async {
    final (_, first) = await start();
    first.debugMediaPaused = true;
    final (bytes, key) = photo(1);
    await first.debugIngestManifest(bytes,
        senderPub: sender, sentAt: DateTime.now());
    await first.debugSaveHeldManifests();

    final (container, second) = await start();
    second.debugMediaPaused = true;
    await second.debugRestoreHeldManifests();
    expect(second.debugHasManifest(key), isTrue);
    expect(container.read(heldMediaProvider), {senderHex: 1});
  });

  test('waiting for Wi-Fi is off unless somebody turns it on', () async {
    final (container, _) = await start();
    final setting = container.read(mediaDownloadSettingsProvider.notifier);
    expect(await setting.resolved(), isFalse);
  });
}
