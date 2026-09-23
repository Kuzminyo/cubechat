import 'dart:io';

import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/core/storage/hive_init.dart';
import 'package:cubechat/features/airdrop/data/airdrop_clock.dart';
import 'package:cubechat/features/airdrop/data/airdrop_history_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_receive_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_spam_store.dart';
import 'package:cubechat/features/airdrop/data/airdrop_storage.dart';
import 'package:cubechat/features/airdrop/domain/airdrop_spam_guard.dart';
import 'package:cubechat/features/airdrop/domain/airdrop_transfer.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

AirDropHistoryEntry _entry(int i, {String? path}) => AirDropHistoryEntry(
      id: 'id$i',
      peerHex: 'bb' * 32,
      peerName: 'Жека',
      direction: AirDropDirection.incoming,
      at: DateTime(2026, 9, 22).add(Duration(minutes: i)),
      outcome: AirDropOutcome.received,
      files: [
        AirDropHistoryFile(
          name: 'p$i.jpg',
          size: 10,
          mime: 'image/jpeg',
          path: path,
        ),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_airdrop_');
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
      // Windows can briefly retain a Hive file handle after close.
    }
  });

  group('uniqueFileIn', () {
    test('numbers a name that is taken, keeping the extension', () async {
      final a = await uniqueFileIn(tempDir, 'a.jpg');
      expect(a.path, endsWith('${Platform.pathSeparator}a.jpg'));
      await a.writeAsString('x');
      final b = await uniqueFileIn(tempDir, 'a.jpg');
      expect(b.path, endsWith('${Platform.pathSeparator}a (1).jpg'));
      await b.writeAsString('x');
      expect(
        (await uniqueFileIn(tempDir, 'a.jpg')).path,
        endsWith('${Platform.pathSeparator}a (2).jpg'),
      );
    });

    test('a name without an extension, and one that tries to climb out',
        () async {
      await File('${tempDir.path}${Platform.pathSeparator}notes')
          .writeAsString('x');
      expect(
        (await uniqueFileIn(tempDir, 'notes')).path,
        endsWith('${Platform.pathSeparator}notes (1)'),
      );
      final climbed = await uniqueFileIn(tempDir, '../x');
      expect(climbed.parent.path, tempDir.path);
    });
  });

  group('history', () {
    test('keeps the newest two hundred, newest first, across a restart',
        () async {
      final history = container.read(airdropHistoryProvider.notifier);
      await history.loaded;
      for (var i = 0; i < 201; i++) {
        history.add(_entry(i));
      }
      expect(container.read(airdropHistoryProvider), hasLength(200));
      expect(container.read(airdropHistoryProvider).first.id, 'id200');
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final relaunched = ProviderContainer();
      addTearDown(relaunched.dispose);
      await relaunched.read(airdropHistoryProvider.notifier).loaded;
      final restored = relaunched.read(airdropHistoryProvider);
      expect(restored, hasLength(200));
      expect(restored.first.id, 'id200');
      expect(restored.first.files.single.name, 'p200.jpg');
    });

    test('a deleted file stays in the history, marked', () async {
      final history = container.read(airdropHistoryProvider.notifier);
      await history.loaded;
      history
        ..add(_entry(1, path: '/x/p1.jpg'))
        ..add(_entry(2, path: '/x/p2.jpg'))
        ..markDeleted('/x/p1.jpg');
      final entries = container.read(airdropHistoryProvider);
      expect(
        entries.firstWhere((e) => e.id == 'id1').files.single.deleted,
        isTrue,
      );
      expect(
        entries.firstWhere((e) => e.id == 'id2').files.single.deleted,
        isFalse,
      );
    });

    test('clear empties it', () async {
      final history = container.read(airdropHistoryProvider.notifier);
      await history.loaded;
      history.add(_entry(1));
      await history.clear();
      expect(container.read(airdropHistoryProvider), isEmpty);
    });

    test('"no Wi-Fi route" is kept, and a line from before it reads false',
        () {
      final failed = AirDropHistoryEntry.of(
        AirDropTransfer(
          id: 'id9',
          peerHex: 'bb' * 32,
          peerName: 'Жека',
          direction: AirDropDirection.outgoing,
          files: const [
            AirDropFile(mediaIdHex: 'aa', name: 'a', size: 1, mime: 'x/y'),
          ],
          phase: AirDropPhase.failed,
          createdAt: DateTime(2026, 9, 23),
          wifiUnreachable: true,
        ),
        DateTime(2026, 9, 23),
      );
      expect(failed.noWifiRoute, isTrue);
      expect(AirDropHistoryEntry.fromJson(failed.toJson())!.noWifiRoute, isTrue);
      expect(failed.withFiles(const []).noWifiRoute, isTrue);

      final old = _entry(1).toJson();
      expect(old.containsKey('noWifi'), isFalse);
      expect(AirDropHistoryEntry.fromJson(old)!.noWifiRoute, isFalse);
    });
  });

  test('spam records survive a restart', () async {
    final spam = container.read(airdropSpamProvider.notifier);
    await spam.loaded;
    spam.put(
      'cc' * 32,
      SpamRecord(lastRequestAt: DateTime(2026, 9, 22), bans: 2),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final relaunched = ProviderContainer();
    addTearDown(relaunched.dispose);
    await relaunched.read(airdropSpamProvider.notifier).loaded;
    expect(
      relaunched.read(airdropSpamProvider.notifier).recordFor('cc' * 32)?.bans,
      2,
    );
  });

  group('receive mode', () {
    test('everyone lasts ten minutes and survives a restart', () async {
      // Whole milliseconds: that is what is stored, and a restart reads back.
      final now = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch,
      );
      final pinned = ProviderContainer(
        overrides: [airdropClockProvider.overrideWithValue(() => now)],
      );
      addTearDown(pinned.dispose);
      final receive = pinned.read(airdropReceiveProvider.notifier);
      await receive.loaded;
      await receive.openToEveryone();
      final until = pinned.read(airdropReceiveProvider).everyoneUntil;
      expect(until, now.add(const Duration(minutes: 10)));
      expect(pinned.read(airdropReceiveProvider).everyoneAt(now), isTrue);

      final relaunched = ProviderContainer(
        overrides: [airdropClockProvider.overrideWithValue(() => now)],
      );
      addTearDown(relaunched.dispose);
      await relaunched.read(airdropReceiveProvider.notifier).loaded;
      expect(relaunched.read(airdropReceiveProvider).everyoneUntil, until);

      await receive.contactsOnly();
      expect(pinned.read(airdropReceiveProvider).everyoneUntil, isNull);
    });

    test('switches itself back to contacts when the time is up', () async {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      await box.put(
        AirDropReceiveController.storageKey,
        DateTime.now()
            .add(const Duration(milliseconds: 300))
            .millisecondsSinceEpoch,
      );
      final receive = container.read(airdropReceiveProvider.notifier);
      await receive.loaded;
      expect(
        container.read(airdropReceiveProvider).everyoneAt(DateTime.now()),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(container.read(airdropReceiveProvider).everyoneUntil, isNull);
    });

    test('a window that ended while the app was closed is not restored',
        () async {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      await box.put(
        AirDropReceiveController.storageKey,
        DateTime.now()
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
      );
      await container.read(airdropReceiveProvider.notifier).loaded;
      expect(container.read(airdropReceiveProvider).everyoneUntil, isNull);
    });
  });
}
