import 'dart:io';

import 'package:cubechat/core/crypto/identity_service.dart';
import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/core/storage/hive_init.dart';
import 'package:cubechat/features/backup/data/backup_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await hiveCipherProvider.wipe();
    tempDir = await Directory.systemTemp.createTemp('cubechat_backup_test_');
    Hive.init(tempDir.path);
    container = ProviderContainer();
  });

  tearDown(() async {
    container.dispose();
    await Hive.close();
    await hiveCipherProvider.wipe();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can briefly retain a Hive handle after close.
    }
  });

  test('restores encrypted boxes and the same cryptographic identity',
      () async {
    const password = 'portable profile password';
    final beforeIdentity = await container.read(identityProvider.future);
    final settings = await hiveCipherProvider.openEncryptedBox<dynamic>(
      HiveBoxes.settings,
    );
    await settings.put('backup-test', {
      'message': 'kept',
      'bytes': <int>[1, 2, 3],
    });

    final service = container.read(backupServiceProvider);
    final encrypted = await service.create(password: password);
    await settings.put('backup-test', {'message': 'changed'});

    await service.restore(encrypted, password: password);

    final restoredSettings =
        await hiveCipherProvider.openEncryptedBox<dynamic>(HiveBoxes.settings);
    expect(restoredSettings.get('backup-test'), {
      'message': 'kept',
      'bytes': <int>[1, 2, 3],
    });
    final afterIdentity = await container.read(identityProvider.future);
    expect(afterIdentity.publicKey, beforeIdentity.publicKey);
    expect(afterIdentity.signPublicKey, beforeIdentity.signPublicKey);
  });
}
