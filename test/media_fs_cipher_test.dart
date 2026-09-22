import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/crypto/media_fs_cipher.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(int seed, int len) =>
    Uint8List.fromList(List.generate(len, (i) => (seed + i) & 0xFF));

SecretKey _key(int seed) => SecretKey(_bytes(seed, 32));

Uint8List _mediaId(int seed) => _bytes(seed, MediaFsCipher.idLen);

void main() {
  group('MediaFsCipher', () {
    test('seal/open round-trips a chunk payload', () async {
      final key = _key(1);
      final id = _mediaId(9);
      final plain = _bytes(40, 140);
      final sealed = await MediaFsCipher.seal(
        key: key,
        mediaId: id,
        plaintext: plain,
      );
      expect(await MediaFsCipher.open(key: key, body: sealed), plain);
    });

    test('overhead is 44 bytes (mediaId + nonce + tag)', () async {
      final sealed = await MediaFsCipher.seal(
        key: _key(1),
        mediaId: _mediaId(9),
        plaintext: _bytes(0, 100),
      );
      expect(sealed.length, 100 + 44);
    });

    test('readMediaId recovers the clear transfer id', () async {
      final id = _mediaId(9);
      final sealed = await MediaFsCipher.seal(
        key: _key(1),
        mediaId: id,
        plaintext: _bytes(0, 10),
      );
      expect(MediaFsCipher.readMediaId(sealed), id);
    });

    test('a wrong key fails the tag check', () async {
      final sealed = await MediaFsCipher.seal(
        key: _key(1),
        mediaId: _mediaId(9),
        plaintext: _bytes(0, 32),
      );
      expect(
        () => MediaFsCipher.open(key: _key(2), body: sealed),
        throwsA(anything),
      );
    });

    test('a tampered ciphertext fails', () async {
      final key = _key(1);
      final sealed = await MediaFsCipher.seal(
        key: key,
        mediaId: _mediaId(9),
        plaintext: _bytes(0, 32),
      );
      sealed[MediaFsCipher.headerLen + 1] ^= 0xFF;
      expect(
        () => MediaFsCipher.open(key: key, body: sealed),
        throwsA(anything),
      );
    });

    test('a grafted mediaId (AAD) fails — chunk cannot be moved between transfers',
        () async {
      final key = _key(1);
      final sealed = await MediaFsCipher.seal(
        key: key,
        mediaId: _mediaId(9),
        plaintext: _bytes(0, 32),
      );
      // Flip a byte of the clear mediaId prefix; the AEAD binds it as AAD.
      sealed[0] ^= 0xFF;
      expect(
        () => MediaFsCipher.open(key: key, body: sealed),
        throwsA(anything),
      );
    });

    test('too-short body throws FormatException', () {
      expect(
        () => MediaFsCipher.readMediaId(Uint8List(10)),
        throwsA(isA<FormatException>()),
      );
    });

    test('two seals of the same plaintext differ (fresh nonce)', () async {
      final key = _key(1);
      final id = _mediaId(9);
      final a = await MediaFsCipher.seal(key: key, mediaId: id, plaintext: _bytes(0, 32));
      final b = await MediaFsCipher.seal(key: key, mediaId: id, plaintext: _bytes(0, 32));
      expect(a, isNot(b));
      // But both still decrypt.
      expect(await MediaFsCipher.open(key: key, body: a), _bytes(0, 32));
      expect(await MediaFsCipher.open(key: key, body: b), _bytes(0, 32));
    });
  });

  // A relay chunk (63 KiB) is sealed and opened on another isolate. Phones on
  // older builds seal it inline, so the bytes on the wire must be exactly the
  // same layout either way — the receiver cannot know which side did what.
  group('MediaFsCipher off the UI isolate', () {
    const relayChunk = 63 * 1024;

    test('a relay-sized chunk round-trips', () async {
      final key = _key(1);
      final plain = _bytes(7, relayChunk);
      final sealed = await MediaFsCipher.seal(
        key: key,
        mediaId: _mediaId(9),
        plaintext: plain,
      );
      expect(sealed.length, relayChunk + 44);
      expect(await MediaFsCipher.open(key: key, body: sealed), plain);
    });

    test('its layout is plain ChaCha20-Poly1305 an old build can open',
        () async {
      final key = _key(2);
      final id = _mediaId(4);
      final plain = _bytes(3, MediaFsCipher.offloadBytes + 1);
      final sealed =
          await MediaFsCipher.seal(key: key, mediaId: id, plaintext: plain);

      expect(sealed.sublist(0, MediaFsCipher.idLen), id);
      final nonce = sealed.sublist(
        MediaFsCipher.idLen,
        MediaFsCipher.headerLen,
      );
      final tagAt = sealed.length - MediaFsCipher.tagLen;
      final clear = await Chacha20.poly1305Aead().decrypt(
        SecretBox(
          sealed.sublist(MediaFsCipher.headerLen, tagAt),
          nonce: nonce,
          mac: Mac(sealed.sublist(tagAt)),
        ),
        secretKey: key,
        aad: id,
      );
      expect(clear, plain);
    });

    test('a chunk sealed inline by an old build opens here', () async {
      final key = _key(5);
      final id = _mediaId(6);
      final plain = _bytes(1, relayChunk);
      final aead = Chacha20.poly1305Aead();
      final nonce = aead.newNonce();
      final box =
          await aead.encrypt(plain, secretKey: key, nonce: nonce, aad: id);
      final body = Uint8List.fromList([
        ...id,
        ...nonce,
        ...box.cipherText,
        ...box.mac.bytes,
      ]);
      expect(await MediaFsCipher.open(key: key, body: body), plain);
    });

    test('a tampered relay chunk still fails its tag', () async {
      final key = _key(1);
      final sealed = await MediaFsCipher.seal(
        key: key,
        mediaId: _mediaId(9),
        plaintext: _bytes(0, relayChunk),
      );
      sealed[MediaFsCipher.headerLen + 100] ^= 0x01;
      await expectLater(
        MediaFsCipher.open(key: key, body: sealed),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });
}
