import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/features/backup/data/backup_file_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temporary;
  late File encrypted;
  late File clear;
  late Uint8List original;
  const password = 'authenticated file password';

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('backup_codec_v2_');
    encrypted = File('${temporary.path}/encrypted');
    clear = File('${temporary.path}/clear');
    await BackupFileCodec().encrypt(
      Stream<List<int>>.fromIterable([
        [1, 2, 3],
        [4, 5, 6],
      ]),
      encrypted,
      password: password,
    );
    original = await encrypted.readAsBytes();
  });

  tearDownAll(() async {
    await temporary.delete(recursive: true);
  });

  test('bounded file records round-trip', () async {
    await encrypted.writeAsBytes(original);
    await BackupFileCodec().decrypt(encrypted, clear, password: password);
    expect(await clear.readAsBytes(), [1, 2, 3, 4, 5, 6]);
  });

  for (final corruption in [
    'header',
    'ciphertext',
    'mac',
    'reorder',
    'duplicate',
    'truncate',
    'missing-final',
    'append',
    'oversized'
  ]) {
    test('rejects $corruption', () async {
      final bytes = Uint8List.fromList(original);
      // Header: 32 bytes. Each of our records: 4 length + 3 body + 16 tag.
      final List<int> modified;
      switch (corruption) {
        case 'header':
          bytes[8] ^= 1;
          modified = bytes;
        case 'ciphertext':
          bytes[36] ^= 1;
          modified = bytes;
        case 'mac':
          bytes[40] ^= 1;
          modified = bytes;
        case 'reorder':
          modified = [
            ...bytes.sublist(0, 32),
            ...bytes.sublist(55, 78),
            ...bytes.sublist(32, 55),
            ...bytes.sublist(78)
          ];
        case 'duplicate':
          modified = [
            ...bytes.sublist(0, 55),
            ...bytes.sublist(32, 55),
            ...bytes.sublist(78)
          ];
        case 'truncate':
          modified = bytes.sublist(0, bytes.length - 1);
        case 'missing-final':
          modified = bytes.sublist(0, 78);
        case 'append':
          modified = [...bytes, 0];
        case 'oversized':
          ByteData.sublistView(bytes)
              .setUint32(32, BackupFileCodec.chunkBytes + 1);
          modified = bytes;
        default:
          throw StateError(corruption);
      }
      await encrypted.writeAsBytes(modified);
      await expectLater(
          BackupFileCodec().decrypt(encrypted, clear, password: password),
          throwsFormatException);
    });
  }

  test('wrong password fails', () async {
    await encrypted.writeAsBytes(original);
    await expectLater(
        BackupFileCodec().decrypt(encrypted, clear, password: 'wrong password'),
        throwsFormatException);
  });
}
