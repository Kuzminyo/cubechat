import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chat/presentation/view_once_media_screen.dart';
import 'package:cubechat/features/chat/presentation/widgets/message_bubble.dart';
import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
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

    test('a photo with no transport id is left alone', () async {
      // Nothing to tell the sender about, and nothing for a re-delivery to
      // match — burning it would only lose the local file.
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
          viewOnce: true,
        ),
      );
      expect(await messages.consumeViewOnce('peer', 'aa11'), isNull);
      expect(await photo.exists(), isTrue);
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

  group('who may open a view-once photo', () {
    Message photoFrom({required bool mine, DateTime? consumedAt}) => Message(
          id: 'm1',
          chatId: 'peer',
          text: 'image/jpeg',
          sentAt: DateTime(2026, 8, 6),
          isMine: mine,
          kind: MessageKind.image,
          wireId: 'aa11',
          viewOnce: true,
          viewOnceConsumedAt: consumedAt,
        );

    test('the person it was sent to, once, while the bytes are here', () {
      expect(
        viewOnceCanBeOpened(photoFrom(mine: false), fileExists: true),
        isTrue,
      );
      // Still arriving, or already burned: nothing to show either way.
      expect(
        viewOnceCanBeOpened(photoFrom(mine: false), fileExists: false),
        isFalse,
      );
      expect(
        viewOnceCanBeOpened(
          photoFrom(mine: false, consumedAt: DateTime(2026, 8, 6)),
          fileExists: true,
        ),
        isFalse,
      );
    });

    test('never the sender, however available the file looks', () {
      // The sender's own copy used to stay openable until the recipient's ack
      // came back — and opening it fired the "I have seen it" notice, which
      // burned the photo on a phone whose owner had not looked at it yet.
      expect(
        viewOnceCanBeOpened(photoFrom(mine: true), fileExists: true),
        isFalse,
      );
    });
  });

  /// The half that kept escaping: the store above always burned correctly, and
  /// the viewer never reached it.
  ///
  /// It asked for the transport from inside `dispose`, where Flutter has
  /// already cleared the element and Riverpod throws rather than answering.
  /// The exception left through `dispose`, the framework swallowed it, and the
  /// photo survived every viewing. Capturing the service in a `late final`
  /// field looked like the fix and was not one — a late initialiser runs at its
  /// first *read*, which was still inside dispose. So what is pinned here is
  /// not "the burn happens" but "the burn happens when the screen goes away",
  /// driven through the same route pop a person performs.
  group('leaving the viewer', () {
    Message photo({bool mine = false}) => Message(
          id: 'm1',
          chatId: 'peer',
          text: 'image/jpeg',
          sentAt: DateTime(2026, 8, 5),
          isMine: mine,
          kind: MessageKind.image,
          // No file on disk on purpose: the screen shows its unavailable
          // state, which keeps the test off the image decoder without changing
          // the path being exercised.
          imagePath: null,
          wireId: 'aa11',
          viewOnce: true,
        );

    Future<GlobalKey<NavigatorState>> pumpViewer(
      WidgetTester tester,
      List<String> burned, {
      bool mine = false,
    }) async {
      final shown = photo(mine: mine);
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            viewOnceBurnProvider.overrideWithValue(
              (chatId, wireId, {bool notifyPeer = true}) async =>
                  burned.add('$chatId/$wireId${notifyPeer ? '/told' : ''}'),
            ),
          ],
          child: MaterialApp(
            navigatorKey: nav,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: SizedBox()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      unawaited(nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => ViewOnceMediaScreen(chatId: 'peer', message: shown),
        ),
      ));
      await tester.pumpAndSettle();
      return nav;
    }

    testWidgets('burns the photo on the way out, not on the way in',
        (tester) async {
      final burned = <String>[];
      final nav = await pumpViewer(tester, burned);
      expect(burned, isEmpty, reason: 'opening it is not having seen it');

      nav.currentState!.pop();
      await tester.pumpAndSettle();

      expect(burned, ['peer/aa11/told']);
    });

    testWidgets('looking at our own photo does not spend the recipient\'s',
        (tester) async {
      // "I have seen it" is a thing only the receiver can say. Sent for our own
      // outgoing copy, it reached the other phone as permission to destroy a
      // picture nobody there had opened yet — so checking what you just sent
      // took their one viewing away.
      final burned = <String>[];
      final nav = await pumpViewer(tester, burned, mine: true);

      nav.currentState!.pop();
      await tester.pumpAndSettle();

      expect(burned, ['peer/aa11'], reason: 'ours goes, theirs is not touched');
    });

    testWidgets('burns it when the app is put away with it still open',
        (tester) async {
      // A process killed from the switcher never runs dispose, and the photo
      // used to be there again on the next launch.
      final burned = <String>[];
      await pumpViewer(tester, burned);
      addTearDown(
        () => tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed),
      );

      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      expect(burned, isEmpty, reason: 'a half-pulled shade is not leaving');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(burned, ['peer/aa11/told']);
    });
  });
}
