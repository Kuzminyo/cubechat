import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/core/transport/messaging_service.dart';
import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/peers/data/known_peers_controller.dart';
import 'package:cubechat/features/profile/data/relay_settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// No relays, so a text to somebody out of Bluetooth range has no road and is
/// queued — the case under test.
class _Offline extends RelaySettingsController {
  @override
  RelaySettings build() =>
      const RelaySettings(enabled: false, urls: RelaySettings.defaultUrls);

  @override
  Future<void> get loaded => Future<void>.value();
}

/// A waiting text is re-signed rather than sent stale, and survives a restart
/// of the relay half of the queue — "automatic retry", the second part of the
/// bad-connection mode.
///
/// A receiver refuses a signed frame older than an hour. A frame that waited
/// longer used to go out anyway: accepted by the relay, shown as delivered,
/// dropped on arrival. And the relay half of the queue is in memory, so after
/// a restart a waiting text could only ever leave by Bluetooth.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final peerHex = 'ab' * 32;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_remint_');
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
    container.read(knownPeersControllerProvider.notifier).upsert(
          pubkeyHex: peerHex,
          displayName: 'Alice',
          signPublicKey: Uint8List(32),
        );
    return (container, container.read(messagingServiceProvider));
  }

  Future<Message> queueOne(MessagingService service, String text) async {
    final msg = await service.sendText(peerHex, text);
    expect(msg.wireId, isNotNull);
    expect(
      service.debugQueuedFrame(msg.wireId!),
      isNotNull,
      reason: 'no Bluetooth and no relays: it has to be waiting',
    );
    return msg;
  }

  List<Message> copiesOf(ProviderContainer c, String wireId) => [
        for (final m in c.read(messagesControllerProvider)[peerHex] ??
            const <Message>[])
          if (m.wireId == wireId) m,
      ];

  test('a restart does not strand a waiting text', () async {
    final (container, service) = await start();
    final msg = await queueOne(service, 'ключі під килимком');
    final before = service.debugQueuedFrame(msg.wireId!)!;

    service.debugForgetQueue();
    expect(service.debugQueuedFrame(msg.wireId!), isNull);
    await service.debugRemintQueued();

    final after = service.debugQueuedFrame(msg.wireId!);
    expect(after, isNotNull, reason: 'held again, ready for the next road');
    expect(after, isNot(before), reason: 'signed afresh, not the old bytes');
    expect(
      copiesOf(container, msg.wireId!),
      hasLength(1),
      reason: 'the same message, under the same id — not a second bubble',
    );
  });

  test('a frame older than the replay window is signed again', () async {
    final (_, service) = await start();
    final msg = await queueOne(service, 'are you there?');
    final before = service.debugQueuedFrame(msg.wireId!)!;

    service.debugAgeQueued(msg.wireId!, const Duration(minutes: 50));
    await service.debugRemintQueued();

    final minted = service.debugQueuedMintedAt(msg.wireId!)!;
    expect(DateTime.now().difference(minted), lessThan(const Duration(minutes: 1)));
    expect(service.debugQueuedFrame(msg.wireId!), isNot(before));
  });

  test('a frame still fresh is left exactly as it was', () async {
    final (_, service) = await start();
    final msg = await queueOne(service, 'on my way');
    final before = service.debugQueuedFrame(msg.wireId!)!;

    await service.debugRemintQueued();

    expect(service.debugQueuedFrame(msg.wireId!), same(before));
  });

  test("a room's waiting post is not re-sent as a private text", () async {
    final (container, service) = await start();
    const wire = 'cd000000000000000000000000000000';
    container.read(messagesControllerProvider.notifier).append(
          '#room',
          Message(
            id: 'post',
            chatId: '#room',
            text: 'hello room',
            sentAt: DateTime.now(),
            isMine: true,
            status: MessageStatus.sending,
            route: MessageRoute.queued,
            wireId: wire,
          ),
        );

    await service.debugRemintQueued();

    expect(service.debugQueuedFrame(wire), isNull);
  });
}
