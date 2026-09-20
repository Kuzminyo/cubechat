import 'dart:io';

import 'package:cubechat/core/crypto/identity_service.dart';
import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/core/storage/hive_init.dart';
import 'package:cubechat/features/backup/data/backup_service.dart';
import 'package:cubechat/features/backup/data/backup_codec.dart';
import 'support/hive_settle.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _BackupPaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _BackupPaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await hiveCipherProvider.wipe();
    tempDir = await Directory.systemTemp.createTemp('cubechat_backup_test_');
    PathProviderPlatform.instance = _BackupPaths(tempDir.path);
    Hive.init(tempDir.path);
    container = ProviderContainer();
  });

  tearDown(() async {
    await settleBackgroundStorage();
    container.dispose();
    await Hive.close();
    await hiveCipherProvider.wipe();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can briefly retain a Hive handle after close.
    }
  });

  test('backs up record and summary boxes already opened by the chat store', () async {
    final records = await hiveCipherProvider.openEncryptedBox<Map<dynamic, dynamic>>(
      HiveBoxes.messageRecords,
    );
    final summaries = await hiveCipherProvider.openEncryptedBox<Map<dynamic, dynamic>>(
      HiveBoxes.chatSummaries,
    );
    await records.put('record', {'text': 'keep me'});
    await summaries.put('peer', {'last': 'record'});
    final service = container.read(backupServiceProvider);
    final bytes = await service.create(password: 'regression test password');
    expect(bytes, isNotEmpty);
    final payload = await BackupCodec().decrypt(
      bytes,
      password: 'regression test password',
    );
    final boxes = payload['boxes'] as Map<String, dynamic>;
    expect(boxes[HiveBoxes.messageRecords], [
      [
        {'t': 'scalar', 'v': 'record'},
        {'t': 'map', 'v': [
          [{'t': 'scalar', 'v': 'text'}, {'t': 'scalar', 'v': 'keep me'}],
        ]},
      ],
    ]);
    expect(boxes[HiveBoxes.chatSummaries], [
      [
        {'t': 'scalar', 'v': 'peer'},
        {'t': 'map', 'v': [
          [{'t': 'scalar', 'v': 'last'}, {'t': 'scalar', 'v': 'record'}],
        ]},
      ],
    ]);
    expect(records.get('record')?['text'], 'keep me');
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
