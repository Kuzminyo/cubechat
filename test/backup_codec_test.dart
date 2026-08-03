import 'dart:convert';
import 'dart:math';

import 'package:cubechat/features/backup/data/backup_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final codec = BackupCodec(random: Random(42));
  const password = 'correct horse battery staple';
  final payload = <String, Object?>{
    'version': 1,
    'identity': {'x25519': 'secret'},
    'messages': [
      {'text': 'hello'},
    ],
  };

  test('encrypted backup round-trips structured data', () async {
    final encrypted = await codec.encrypt(payload, password: password);
    final restored = await codec.decrypt(encrypted, password: password);

    expect(restored, payload);
    expect(utf8.decode(encrypted), isNot(contains('hello')));
    expect(utf8.decode(encrypted), isNot(contains('secret')));
  });

  test('wrong password is rejected before payload is exposed', () async {
    final encrypted = await codec.encrypt(payload, password: password);

    expect(
      () => codec.decrypt(encrypted, password: 'wrong password'),
      throwsFormatException,
    );
  });

  test('modified ciphertext is rejected by AES-GCM authentication', () async {
    final encrypted = await codec.encrypt(payload, password: password);
    final outer = jsonDecode(utf8.decode(encrypted)) as Map<String, dynamic>;
    final ciphertext = outer['ciphertext'] as String;
    outer['ciphertext'] = '${ciphertext.substring(0, ciphertext.length - 2)}AA';

    expect(
      () => codec.decrypt(
        utf8.encode(jsonEncode(outer)),
        password: password,
      ),
      throwsFormatException,
    );
  });

  test('short backup passwords are refused', () {
    expect(
      () => codec.encrypt(payload, password: 'short'),
      throwsFormatException,
    );
  });
}
