import 'dart:io';

import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

/// In-memory stand-in for the platform keystore, with a deliberate delay so the
/// window between "cache is empty" and "key is cached" is wide enough for a
/// racing caller to slip through.
class _FakeSecureStorage extends FlutterSecureStorage {
  _FakeSecureStorage();

  final Map<String, String> store = {};
  int reads = 0;
  int writes = 0;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    reads++;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return store[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writes++;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (value == null) {
      store.remove(key);
    } else {
      store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    store.remove(key);
  }
}

void main() {
  group('HiveCipherProvider.load', () {
    test('concurrent callers share one key instead of each minting their own',
        () async {
      // Every controller opens its encrypted box during startup, so this is the
      // real access pattern — not a synthetic one. Before the single-flight
      // guard each caller minted a different key, only the last reached the
      // keystore, and on the next launch the other boxes failed to decrypt and
      // were deleted.
      final storage = _FakeSecureStorage();
      final provider = HiveCipherProvider(storage: storage);

      final ciphers = await Future.wait(
        List.generate(6, (_) => provider.load()),
      );

      expect(storage.writes, 1, reason: 'exactly one key may be minted');
      for (final c in ciphers) {
        expect(identical(c, ciphers.first), isTrue,
            reason: 'every caller must get the same cipher');
      }
    });

    test('a second load after the key is cached hits neither read nor write',
        () async {
      final storage = _FakeSecureStorage();
      final provider = HiveCipherProvider(storage: storage);

      final first = await provider.load();
      final readsAfterFirst = storage.reads;
      final second = await provider.load();

      expect(identical(first, second), isTrue);
      expect(storage.reads, readsAfterFirst);
      expect(storage.writes, 1);
    });

    test('an existing key is reused rather than replaced', () async {
      final storage = _FakeSecureStorage();
      final provider = HiveCipherProvider(storage: storage);
      await provider.load();
      final minted = storage.store.values.single;

      // A fresh provider (as after a restart) must adopt the stored key.
      final reopened = HiveCipherProvider(storage: storage);
      await reopened.load();

      expect(storage.writes, 1, reason: 'no second key may be written');
      expect(storage.store.values.single, minted);
    });
  });

  group('HiveCipherProvider.openEncryptedBox', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('cubechat_hive_test');
      Hive.init(tmp.path);
    });

    tearDown(() async {
      await Hive.close();
      await tmp.delete(recursive: true);
    });

    test('concurrent opens of one box share a single live handle', () async {
      // The real startup pattern: several controllers open the same `settings`
      // box at once. Before openEncryptedBox was single-flight, a loser in that
      // race could run the delete-and-retry path, close the handle the winner
      // had handed out, and wipe the box — surfacing later as
      // "Box has already been closed" on a write. Guard the contract: every
      // concurrent caller gets the same open, usable box.
      final provider = HiveCipherProvider(storage: _FakeSecureStorage());

      final boxes = await Future.wait(
        List.generate(
          6,
          (_) => provider.openEncryptedBox<dynamic>('cubechat.settings'),
        ),
      );

      for (final b in boxes) {
        expect(identical(b, boxes.first), isTrue,
            reason: 'all callers must share one handle');
        expect(b.isOpen, isTrue, reason: 'the shared box must stay open');
      }

      // A write through one handle is visible through another — proof they are
      // the same live box and it was never deleted out from under anyone.
      await boxes.first.put('k', 'v');
      expect(boxes.last.get('k'), 'v');
    });
  });
}
