import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/features/moderation/data/ban_list_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

// The cross-language vector from push/test/banned.test.js (written out for
// the app in .superpowers/sdd/2026-09-24-moderation-ugc/ban-canonical-vector.md,
// a git-ignored folder, hence copied here). A THROWAWAY key pair generated for
// the vector — never the production key, which is banListPublicKeyHex.
const _testPublicKey =
    'f8a3b6fc8195e23ce2a0f0f6c67d7a8ff1827843541c17b0a44f4a3f6c7dbb3a';
const _testPrivatePkcs8 =
    'MC4CAQAwBQYDK2VwBCIEIH+86rB/X+X0edbydXmaVdEKiuCIVWxGz0EXx6nBEpe7';
const _vectorSignature =
    'e540f985eb8139302691f82086205a2d29b44a990e03da5b0c9d84e596ab091561be8890dfed566231b36845f52be5937355ac06450e2ca9ee17864c4e761e06';
const _vectorCanonical =
    '{"v":1,"updatedAt":1700000000,'
    '"identities":["1111111111111111111111111111111111111111111111111111111111111111",'
    '"2222222222222222222222222222222222222222222222222222222222222222"],'
    '"npubs":["3333333333333333333333333333333333333333333333333333333333333333"],'
    '"fingerprints":["4444444444444444444444444444444444444444444444444444444444444444"]}';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Signs [body] the way the server's createBans does, with the vector key.
Future<Map<String, dynamic>> _signed(Map<String, dynamic> body) async {
  // PKCS8 for Ed25519 is a 16-byte header followed by the 32-byte seed.
  final seed = base64Decode(_testPrivatePkcs8).sublist(16);
  final keyPair = await Ed25519().newKeyPairFromSeed(seed);
  final signature = await Ed25519().sign(
    utf8.encode(canonicalBanBody(body)),
    keyPair: keyPair,
  );
  return {...body, 'sig': _hex(signature.bytes)};
}

Map<String, dynamic> _list(int updatedAt, {List<String>? identities}) => {
      'v': 1,
      'updatedAt': updatedAt,
      'identities': identities ?? <String>['aa' * 32],
      'npubs': <String>[],
      // Channel authors are known by an 8-byte signing fingerprint.
      'fingerprints': <String>['0123456789abcdef'],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final vectorBody = <String, dynamic>{
    'v': 1,
    'updatedAt': 1700000000,
    // Out of order on purpose: canonicalisation sorts.
    'identities': <String>['22' * 32, '11' * 32],
    'npubs': <String>['33' * 32],
    'fingerprints': <String>['44' * 32],
    'sig': _vectorSignature,
  };

  group('the cross-language vector', () {
    test('canonicalisation matches the server byte for byte', () {
      expect(canonicalBanBody(vectorBody), _vectorCanonical);
    });

    test('canonicalisation sorts a copy, not the caller\'s list', () {
      final identities = <String>['22' * 32, '11' * 32];
      canonicalBanBody({...vectorBody, 'identities': identities});
      expect(identities.first, '22' * 32);
    });

    test('the vector key pair is the one the signing helper uses', () async {
      final seed = base64Decode(_testPrivatePkcs8).sublist(16);
      final keyPair = await Ed25519().newKeyPairFromSeed(seed);
      expect(_hex((await keyPair.extractPublicKey()).bytes), _testPublicKey);
    });

    test('the server signature verifies and every list is readable', () async {
      final verified =
          await verifyBanList(vectorBody, publicKeyHex: _testPublicKey);
      expect(verified, isNotNull);
      expect(verified!.isBannedIdentity('11' * 32), isTrue);
      expect(verified.isBannedNpub('33' * 32), isTrue);
      expect(verified.isBannedFingerprint('44' * 32), isTrue);
    });

    test('one flipped signature byte, an altered field, or no sig: rejected',
        () async {
      final flipped = '${_vectorSignature.substring(0, 10)}'
          '${_vectorSignature[10] == '0' ? '1' : '0'}'
          '${_vectorSignature.substring(11)}';
      for (final body in [
        {...vectorBody, 'sig': flipped},
        {...vectorBody, 'updatedAt': 1700000001},
        {...vectorBody, 'npubs': <String>[]},
        {...vectorBody, 'sig': ''},
        Map<String, dynamic>.of(vectorBody)..remove('sig'),
      ]) {
        expect(
          await verifyBanList(body, publicKeyHex: _testPublicKey),
          isNull,
        );
      }
    });

    test('the production key does not accept a list signed by the test key',
        () async {
      expect(banListPublicKeyHex, isNot(_testPublicKey));
      expect(
        banListPublicKeyHex,
        'a18bbcc304e9c41f586c9fb6bd2c77d0928fad2067b2d241d526eed34258a725',
      );
      expect(await verifyBanList(vectorBody), isNull);
    });

    test('a 16-hex channel-author fingerprint is accepted', () async {
      final verified = await verifyBanList(
        await _signed(_list(5)),
        publicKeyHex: _testPublicKey,
      );
      expect(verified!.isBannedFingerprint('0123456789ABCDEF'), isTrue);
    });
  });

  group('BanListController', () {
    late Directory tempDir;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      await hiveCipherProvider.wipe();
      tempDir = await Directory.systemTemp.createTemp('cubechat_bans_');
      Hive.init(tempDir.path);
    });

    tearDown(() async {
      await settleBackgroundStorage();
      await Hive.close();
      await hiveCipherProvider.wipe();
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows holds the Hive files briefly after close.
      }
    });

    ProviderContainer containerWith(BanListFetcher fetcher) {
      final container = ProviderContainer(
        overrides: [
          banListProvider.overrideWith(
            () => BanListController(
              fetcher: fetcher,
              publicKeyHex: _testPublicKey,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('a verified list is applied; an older one never replaces it',
        () async {
      final newer = await _signed(_list(20, identities: ['aa' * 32]));
      final older = await _signed(_list(10, identities: ['bb' * 32]));
      var answer = newer;
      final container = containerWith((_) async => answer);

      await container.read(banListProvider.notifier).refresh(force: true);
      expect(container.read(banListProvider).updatedAt, 20);

      answer = older;
      await container.read(banListProvider.notifier).refresh(force: true);
      final state = container.read(banListProvider);
      expect(state.updatedAt, 20);
      expect(state.isBannedIdentity('aa' * 32), isTrue);
      expect(state.isBannedIdentity('bb' * 32), isFalse);
    });

    test('an unsigned or forged answer is ignored', () async {
      final forged = {...await _signed(_list(30)), 'updatedAt': 31};
      final container = containerWith((_) async => forged);
      await container.read(banListProvider.notifier).refresh(force: true);
      expect(container.read(banListProvider).updatedAt, 0);
    });

    test('the last good list is persisted and read back at the next start',
        () async {
      final good = await _signed(_list(40));
      await containerWith((_) async => good)
          .read(banListProvider.notifier)
          .refresh(force: true);

      // A new process with no network at all.
      final offline = containerWith((_) async => null);
      await offline.read(banListProvider.notifier).refresh(force: true);
      expect(offline.read(banListProvider).updatedAt, 40);
      expect(
        offline.read(banListProvider).isBannedFingerprint('0123456789abcdef'),
        isTrue,
      );
    });

    test('a start with no network tries again on the next trigger', () async {
      Map<String, dynamic>? answer;
      var calls = 0;
      final container = containerWith((_) async {
        calls++;
        return answer;
      });
      await container.read(banListProvider.notifier).refresh();
      expect(calls, BanListController.endpoints.length);

      answer = await _signed(_list(50));
      await container.read(banListProvider.notifier).refresh();
      expect(container.read(banListProvider).updatedAt, 50);

      // And once it has an answer, the next trigger inside six hours is free.
      final before = calls;
      await container.read(banListProvider.notifier).refresh();
      expect(calls, before);
    });
  });
}
