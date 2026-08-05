import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

Uint8List _bytes(int n, [int seed = 0]) =>
    Uint8List.fromList(List.generate(n, (i) => (i + seed) & 0xFF));

MediaManifest _manifest({
  bool viewOnce = false,
  String? caption,
  bool fs = false,
  MediaKind kind = MediaKind.image,
}) =>
    MediaManifest(
      mediaId: _bytes(MediaManifest.idLen),
      kind: kind,
      total: 3,
      mime: 'image/jpeg',
      caption: caption,
      viewOnce: viewOnce,
      sha256: _bytes(MediaManifest.digestLen, 9),
      name: kind == MediaKind.file ? 'a.pdf' : null,
      senderIdentityPub: fs ? _bytes(MediaManifest.pubLen, 3) : null,
      senderEphemeralPub: fs ? _bytes(MediaManifest.pubLen, 4) : null,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the manifest carries view-once without disturbing anything else', () {
    test('an ordinary photo still encodes as the old versions, byte for byte',
        () {
      // The whole back-compat story rests on this: only a photo that actually
      // opted in needs a build that understands the new versions.
      expect(_manifest().encode()[0], MediaManifest.versionV1);
      expect(_manifest(fs: true).encode()[0], MediaManifest.versionV2Fs);
      expect(_manifest(caption: 'hi').encode()[0],
          MediaManifest.versionV3Caption);
      expect(_manifest(caption: 'hi', fs: true).encode()[0],
          MediaManifest.versionV4CaptionFs);
    });

    test('the flag round-trips across every combination it composes with', () {
      for (final caption in [null, 'a line']) {
        for (final fs in [false, true]) {
          final decoded = MediaManifest.decode(
            _manifest(viewOnce: true, caption: caption, fs: fs).encode(),
          );
          expect(decoded.viewOnce, isTrue);
          expect(decoded.caption, caption);
          expect(decoded.isForwardSecret, fs);
        }
      }
    });

    test('a build that predates view-once refuses the manifest outright', () {
      final wire = _manifest(viewOnce: true).encode();
      expect(wire[0], MediaManifest.versionV5ViewOnce);
      // Simulating the old decoder: it knew 0x01–0x04 and threw on the rest.
      // Refusing is the right failure here — the alternative is an old build
      // keeping a copy of something meant to disappear.
      const knownBefore = [
        MediaManifest.versionV1,
        MediaManifest.versionV2Fs,
        MediaManifest.versionV3Caption,
        MediaManifest.versionV4CaptionFs,
      ];
      expect(knownBefore.contains(wire[0]), isFalse);
    });

    test('a version past the view-once block is still rejected', () {
      final wire = _manifest().encode();
      wire[0] = MediaManifest.versionV8ViewOnceCaptionFs + 1;
      expect(() => MediaManifest.decode(wire),
          throwsA(isA<FormatException>()));
    });

    test('only a photo may be view-once', () {
      // A file would leave a bubble pointing at a path the receiver deleted,
      // and a voice note has no "viewed" moment to hang the deletion on.
      expect(
        () => _manifest(viewOnce: true, kind: MediaKind.file),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('consuming a view-once photo', () {
    late Directory tempDir;
    late ProviderContainer container;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cubechat_viewonce_');
      Hive.init(tempDir.path);
      container = ProviderContainer();
    });

    tearDown(() async {
      await settleBackgroundStorage();
      container.dispose();
      await Hive.close();
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows can retain a Hive handle very briefly after close.
      }
    });

    Future<File> _photoOnDisk() async {
      final f = File('${tempDir.path}${Platform.pathSeparator}shot.jpg');
      await f.writeAsBytes(_bytes(64));
      return f;
    }

    test('deletes the file, blanks the path, and keeps the row', () async {
      final messages = container.read(messagesControllerProvider.notifier);
      await messages.loaded;
      final photo = await _photoOnDisk();
      messages.append(
        'peer',
        Message(
          id: 'm1',
          chatId: 'peer',
          text: 'image/jpeg',
          sentAt: DateTime(2026, 8, 5),
          isMine: false,
          kind: MessageKind.image,
          imagePath: photo.path,
          wireId: 'aa11',
          viewOnce: true,
        ),
      );

      final burned = await messages.consumeViewOnce('peer', 'aa11');
      expect(burned, isNotNull);
      expect(await photo.exists(), isFalse, reason: 'the bytes must be gone');

      final row = container.read(messagesControllerProvider)['peer']!.single;
      expect(row.imagePath, isNull);
      expect(row.viewOnceConsumed, isTrue);
      // The row itself survives on purpose — see below.
      expect(row.wireId, 'aa11');
    });

    test('the tombstone absorbs a re-delivered copy of the same photo',
        () async {
      final messages = container.read(messagesControllerProvider.notifier);
      await messages.loaded;
      final photo = await _photoOnDisk();
      messages.append(
        'peer',
        Message(
          id: 'm1',
          chatId: 'peer',
          text: 'image/jpeg',
          sentAt: DateTime(2026, 8, 5),
          isMine: false,
          kind: MessageKind.image,
          imagePath: photo.path,
          wireId: 'aa11',
          viewOnce: true,
        ),
      );
      await messages.consumeViewOnce('peer', 'aa11');

      // A relay replaying the transfer, or a mesh re-flood: same media id, so
      // same wireId. It must not come back as a fresh, viewable bubble.
      final accepted = messages.append(
        'peer',
        Message(
          id: 'm2',
          chatId: 'peer',
          text: 'image/jpeg',
          sentAt: DateTime(2026, 8, 5),
          isMine: false,
          kind: MessageKind.image,
          imagePath: photo.path,
          wireId: 'aa11',
          viewOnce: true,
        ),
      );
      expect(accepted, isFalse);
      final rows = container.read(messagesControllerProvider)['peer']!;
      expect(rows, hasLength(1));
      expect(rows.single.viewOnceConsumed, isTrue);
      expect(rows.single.imagePath, isNull);
    });

    test('burning twice is a no-op rather than a second notification',
        () async {
      final messages = container.read(messagesControllerProvider.notifier);
      await messages.loaded;
      final photo = await _photoOnDisk();
      messages.append(
        'peer',
        Message(
          id: 'm1',
          chatId: 'peer',
          text: 'image/jpeg',
          sentAt: DateTime(2026, 8, 5),
          isMine: false,
          kind: MessageKind.image,
          imagePath: photo.path,
          wireId: 'aa11',
          viewOnce: true,
        ),
      );
      expect(await messages.consumeViewOnce('peer', 'aa11'), isNotNull);
      // Idempotent: the ack travels both ways and must not ping-pong.
      expect(await messages.consumeViewOnce('peer', 'aa11'), isNull);
    });

    test('an ordinary photo is never burned by mistake', () async {
      final messages = container.read(messagesControllerProvider.notifier);
      await messages.loaded;
      final photo = await _photoOnDisk();
      messages.append(
        'peer',
        Message(
          id: 'm1',
          chatId: 'peer',
          text: 'image/jpeg',
          sentAt: DateTime(2026, 8, 5),
          isMine: false,
          kind: MessageKind.image,
          imagePath: photo.path,
          wireId: 'aa11',
        ),
      );
      expect(await messages.consumeViewOnce('peer', 'aa11'), isNull);
      expect(await photo.exists(), isTrue);
    });
  });
}
