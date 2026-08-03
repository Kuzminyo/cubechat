import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Password-encrypted, authenticated Cubechat backup container.
///
/// PBKDF2 makes each password guess deliberately expensive; AES-256-GCM both
/// hides the payload and rejects a wrong password or a modified file before
/// restore code sees a single identity or history value.
class BackupCodec {
  BackupCodec({Random? random}) : _random = random ?? Random.secure();

  static const magic = 'cubechat-backup';
  static const version = 1;
  static const iterations = 210000;
  static const _saltLength = 16;

  final Random _random;
  final _cipher = AesGcm.with256bits();

  Future<Uint8List> encrypt(
    Map<String, Object?> payload, {
    required String password,
  }) async {
    _validatePassword(password);
    final salt = _randomBytes(_saltLength);
    final nonce = _cipher.newNonce();
    final key = await _deriveKey(password, salt);
    final aad = _aad(iterations);
    final clear = utf8.encode(jsonEncode(payload));
    final box = await _cipher.encrypt(
      clear,
      secretKey: key,
      nonce: nonce,
      aad: aad,
    );
    final container = <String, Object?>{
      'magic': magic,
      'version': version,
      'kdf': 'pbkdf2-hmac-sha256',
      'iterations': iterations,
      'salt': base64Url.encode(salt),
      'nonce': base64Url.encode(box.nonce),
      'ciphertext': base64Url.encode(box.cipherText),
      'mac': base64Url.encode(box.mac.bytes),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(container)));
  }

  Future<Map<String, dynamic>> decrypt(
    List<int> bytes, {
    required String password,
  }) async {
    _validatePassword(password);
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic> ||
          decoded['magic'] != magic ||
          decoded['version'] != version ||
          decoded['kdf'] != 'pbkdf2-hmac-sha256') {
        throw const FormatException('unsupported Cubechat backup');
      }
      final rounds = decoded['iterations'];
      if (rounds is! int || rounds < 100000 || rounds > 1000000) {
        throw const FormatException('invalid backup KDF parameters');
      }
      final salt = base64Url.decode(decoded['salt'] as String);
      final nonce = base64Url.decode(decoded['nonce'] as String);
      final ciphertext = base64Url.decode(decoded['ciphertext'] as String);
      final mac = base64Url.decode(decoded['mac'] as String);
      if (salt.length < 16 || nonce.length != _cipher.nonceLength) {
        throw const FormatException('invalid backup encryption parameters');
      }
      final key = await _deriveKey(password, salt, rounds: rounds);
      final clear = await _cipher.decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
        secretKey: key,
        aad: _aad(rounds),
      );
      final payload = jsonDecode(utf8.decode(clear));
      if (payload is! Map<String, dynamic>) {
        throw const FormatException('invalid backup payload');
      }
      return payload;
    } on FormatException {
      rethrow;
    } on SecretBoxAuthenticationError {
      throw const FormatException('wrong password or modified backup');
    } catch (_) {
      throw const FormatException('invalid or damaged Cubechat backup');
    }
  }

  Future<SecretKey> _deriveKey(
    String password,
    List<int> salt, {
    int rounds = iterations,
  }) =>
      Pbkdf2.hmacSha256(iterations: rounds, bits: 256)
          .deriveKeyFromPassword(password: password, nonce: salt);

  Uint8List _randomBytes(int length) {
    final result = Uint8List(length);
    for (var i = 0; i < result.length; i++) {
      result[i] = _random.nextInt(256);
    }
    return result;
  }

  static List<int> _aad(int rounds) =>
      utf8.encode('$magic:v$version:pbkdf2:$rounds');

  static void _validatePassword(String password) {
    if (password.length < 8) {
      throw const FormatException('backup password is too short');
    }
  }
}
