import 'dart:io';

import 'package:cubechat/core/crypto/identity_service.dart';
import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/core/storage/secure_read_policy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A keystore that refuses the next [failReads] reads, the way iOS refuses
/// every `first_unlock` read before the first unlock after a reboot.
class _FlakyStore extends FlutterSecureStorage {
  _FlakyStore();

  final Map<String, String> store = {};
  int failReads = 0;
  int deleteAlls = 0;

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
    if (failReads > 0) {
      failReads--;
      throw Exception('errSecInteractionNotAllowed (-25308)');
    }
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

  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    deleteAlls++;
    store.clear();
  }
}

void main() {
  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('cubechat_secure_read_');
    Hive.init(tmp.path);
  });

  tearDown(() async {
    await Hive.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {
      // Windows holds the Hive files briefly after close.
    }
  });

  test('a box opened under another key comes back empty, without an error',
      () async {
    // The reason a fresh key after a failed read is a wipe on its own: Hive's
    // crash recovery truncates a box whose first frame fails its checksum.
    final first = HiveAesCipher(List<int>.filled(32, 1));
    final other = HiveAesCipher(List<int>.filled(32, 2));
    final box = await Hive.openBox<String>('history', encryptionCipher: first);
    await box.put('m1', 'hello');
    await box.close();

    final reopened =
        await Hive.openBox<String>('history', encryptionCipher: other);
    expect(reopened.isEmpty, isTrue);
  });

  test('a failed read of the history key keeps the key and the history',
      () async {
    final store = _FlakyStore();
    final before = HiveCipherProvider(storage: store);
    final box = await before.openEncryptedBox<String>('history');
    await box.put('m1', 'hello');
    await Hive.close();
    final key = store.store.values.single;

    // A launch before the first unlock: the keystore refuses, then opens.
    store.failReads = 1;
    final after = HiveCipherProvider(storage: store);
    final reopened = await after.openEncryptedBox<String>('history');

    expect(store.store.values.single, key, reason: 'the key must not change');
    expect(reopened.get('m1'), 'hello', reason: 'the history must survive');
  });

  test('a failed read of the identity keeps the identity', () async {
    final store = _FlakyStore();
    final original = await IdentityService(storage: store).load();

    store.failReads = 1;
    final again = await IdentityService(storage: store).load();

    expect(again.publicKey, original.publicKey);
    expect(store.deleteAlls, 0, reason: 'deleteAll takes every key with it');
  });

  group('SecureReadPolicy', () {
    var now = DateTime.utc(2026, 10, 14, 9);
    SecureReadPolicy policy() => SecureReadPolicy(
          now: () => now,
          window: const Duration(minutes: 5),
          delay: (_) => Duration.zero,
        );

    test('never resets inside the window, however many reads fail', () async {
      final p = policy();
      for (var attempt = 1; attempt <= 50; attempt++) {
        now = now.add(const Duration(seconds: 5));
        expect(await p.shouldReset('t', 'locked', attempts: attempt), isFalse);
      }
    });

    test('resets a store that has failed past the window with no success',
        () async {
      final p = policy();
      expect(await p.shouldReset('t', 'bad', attempts: 1), isFalse);
      now = now.add(const Duration(minutes: 6));
      // Too few attempts to call it broken, even this late.
      expect(await p.shouldReset('t', 'bad', attempts: 2), isFalse);
      expect(await p.shouldReset('t', 'bad', attempts: 3), isTrue);
    });

    test('the window is kept across launches', () async {
      expect(await policy().shouldReset('t', 'bad', attempts: 1), isFalse);
      now = now.add(const Duration(hours: 1));
      // A new process: a fresh policy, the same preferences.
      expect(await policy().shouldReset('t', 'bad', attempts: 3), isTrue);
    });

    test('a success in between starts the window again', () async {
      final p = policy();
      expect(await p.shouldReset('t', 'locked', attempts: 1), isFalse);
      now = now.add(const Duration(hours: 1));
      await p.succeeded();
      expect(await p.shouldReset('t', 'locked', attempts: 3), isFalse);
    });

    test('backs off to thirty seconds', () {
      final p = SecureReadPolicy();
      expect(p.delayAfter(1), const Duration(seconds: 1));
      expect(p.delayAfter(4), const Duration(seconds: 8));
      expect(p.delayAfter(12), const Duration(seconds: 30));
    });
  });
}
