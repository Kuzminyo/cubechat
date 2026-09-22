import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/core/transport/messaging_service.dart';
import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chat/presentation/widgets/message_bubble.dart';
import 'package:cubechat/features/peers/data/known_peers_controller.dart';
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

/// "Сделай так, чтобы отправку смс, фото, гс, кружков, файлов можно было
/// отменить, и это всё можно было перекидывать в другие чаты и в избранное."
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('what can be forwarded', () {
    late Directory dir;
    late String media;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('cubechat_fwd_');
      media = '${dir.path}/note.ogg';
      File(media).writeAsBytesSync([1, 2, 3]);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Message voice({String? path, bool viewOnce = false}) => Message(
          id: 'v',
          chatId: 'peer',
          text: '',
          sentAt: DateTime(2026, 9, 22),
          isMine: false,
          kind: MessageKind.audio,
          audioPath: path,
          viewOnce: viewOnce,
        );

    test('a voice note, when its recording is on the phone', () {
      expect(messageCanBeForwarded(voice(path: media), copyingRestricted: false),
          isTrue);
      expect(messageCanBeForwarded(voice(), copyingRestricted: false), isFalse);
    });

    test('a circle and a file', () {
      for (final name in [Message.circleFileName, 'report.pdf']) {
        final message = Message(
          id: 'f',
          chatId: 'peer',
          text: 'video/mp4',
          sentAt: DateTime(2026, 9, 22),
          isMine: true,
          kind: MessageKind.file,
          filePath: media,
          fileName: name,
        );
        expect(
          messageCanBeForwarded(message, copyingRestricted: false),
          isTrue,
          reason: name,
        );
      }
    });

    test('never with copying switched off in the chat', () {
      expect(messageCanBeForwarded(voice(path: media), copyingRestricted: true),
          isFalse);
    });
  });

  group('taking a send back', () {
    late Directory tempDir;
    final peerHex = 'ab' * 32;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cubechat_cancel_');
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

    test('a text waiting for a connection leaves the queue and the chat',
        () async {
      final (container, service) = await start();
      final msg = await service.sendText(peerHex, 'on second thoughts');
      expect(service.debugQueuedFrame(msg.wireId!), isNotNull);

      final cancelled = await service.cancelSending(peerHex, msg);

      expect(cancelled, isTrue);
      expect(service.debugQueuedFrame(msg.wireId!), isNull);
      final left = container.read(messagesControllerProvider)[peerHex] ?? [];
      expect(left.where((m) => m.id == msg.id), isEmpty);
    });

    test('not something already delivered, and not somebody else\'s',
        () async {
      final (_, service) = await start();
      final delivered = Message(
        id: 'd',
        chatId: peerHex,
        text: 'done',
        sentAt: DateTime.now(),
        isMine: true,
        status: MessageStatus.delivered,
      );
      final theirs = Message(
        id: 't',
        chatId: peerHex,
        text: 'hi',
        sentAt: DateTime.now(),
        isMine: false,
      );
      expect(await service.cancelSending(peerHex, delivered), isFalse);
      expect(await service.cancelSending(peerHex, theirs), isFalse);
    });
  });
}
