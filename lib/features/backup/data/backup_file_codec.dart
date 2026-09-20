import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'backup_codec.dart';

/// File container v2. Each bounded record authenticates its index and the
/// header. An authenticated empty final record detects truncation (including
/// truncation exactly at a record boundary), reordering and appended data.
class BackupFileCodec {
  static final magic = utf8.encode('CCHATB2\n');
  static const chunkBytes = 256 * 1024;
  final _cipher = AesGcm.with256bits();

  Future<void> encrypt(
    Stream<List<int>> clear,
    File destination, {
    required String password,
  }) async {
    if (password.length < 8) {
      throw const FormatException('backup password is too short');
    }
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final prefix = List<int>.generate(8, (_) => random.nextInt(256));
    final header = [...magic, ...salt, ...prefix];
    final key = await _key(password, salt);
    final output = await destination.open(mode: FileMode.write);
    var index = 0;
    Future<void> record(List<int> bytes) async {
      if (index >= 0xffffffff) throw StateError('backup is too large');
      final counter = uint32(index++);
      final box = await _cipher.encrypt(
        bytes,
        secretKey: key,
        nonce: [...prefix, ...counter],
        aad: [...header, ...counter],
      );
      await output.writeFrom(uint32(box.cipherText.length));
      await output.writeFrom(box.cipherText);
      await output.writeFrom(box.mac.bytes);
    }

    try {
      await output.writeFrom(header);
      await for (final bytes in clear) {
        for (var offset = 0; offset < bytes.length; offset += chunkBytes) {
          await record(
              bytes.sublist(offset, min(offset + chunkBytes, bytes.length)));
        }
      }
      await record(const []);
      await output.flush();
    } finally {
      await output.close();
    }
  }

  Future<void> decrypt(File source, File destination,
      {required String password}) async {
    final input = await source.open();
    final output = await destination.open(mode: FileMode.write);
    try {
      final header = await readExactly(input, 32);
      if (!_equal(header.sublist(0, 8), magic)) {
        throw const FormatException('unsupported file backup');
      }
      final key = await _key(password, header.sublist(8, 24));
      final prefix = header.sublist(24);
      var index = 0;
      while (true) {
        if (index >= 0xffffffff)
          throw const FormatException('too many records');
        final size =
            ByteData.sublistView(await readExactly(input, 4)).getUint32(0);
        if (size > chunkBytes)
          throw const FormatException('oversized backup record');
        final encrypted = await readExactly(input, size);
        final mac = await readExactly(input, 16);
        final counter = uint32(index++);
        final clear = await _cipher.decrypt(
          SecretBox(encrypted, nonce: [...prefix, ...counter], mac: Mac(mac)),
          secretKey: key,
          aad: [...header, ...counter],
        );
        if (size == 0) {
          if (await input.position() != await input.length()) {
            throw const FormatException('trailing backup data');
          }
          break;
        }
        await output.writeFrom(clear);
      }
      await output.flush();
    } on SecretBoxAuthenticationError {
      throw const FormatException('wrong password or modified backup');
    } finally {
      await input.close();
      await output.close();
    }
  }

  static Future<SecretKey> _key(String password, List<int> salt) =>
      Pbkdf2.hmacSha256(iterations: BackupCodec.iterations, bits: 256)
          .deriveKeyFromPassword(password: password, nonce: salt);

  static Uint8List uint32(int value) =>
      (ByteData(4)..setUint32(0, value)).buffer.asUint8List();

  static Future<Uint8List> readExactly(
      RandomAccessFile file, int length) async {
    final bytes = Uint8List(length);
    var offset = 0;
    while (offset < length) {
      final count = await file.readInto(bytes, offset);
      if (count == 0) throw const FormatException('truncated backup');
      offset += count;
    }
    return bytes;
  }

  static bool _equal(List<int> a, List<int> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);
}
