import 'dart:io';
import 'dart:typed_data';
import 'package:cubechat/core/transport/shared_location.dart';
import 'package:cubechat/core/storage/hive_init.dart';
import 'package:cubechat/features/map/data/shared_map_locations_provider.dart';

import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/core/util/media_storage.dart';
import 'package:cubechat/features/backup/data/backup_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'support/hive_settle.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory phone;
  late ProviderContainer container;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await hiveCipherProvider.wipe();
    phone = await Directory.systemTemp.createTemp('cubechat_media_backup_');
    PathProviderPlatform.instance = _FakePathProvider(phone.path);
    Hive.init(phone.path);
    container = ProviderContainer();
  });

  tearDown(() async {
    container.dispose();
    // Controllers open boxes from constructors nothing can await — see
    // [settleBackgroundStorage].
    await settleBackgroundStorage();
    await Hive.close();
    await hiveCipherProvider.wipe();
    try {
      if (phone.existsSync()) phone.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can briefly retain a Hive handle after close.
    }
  });

  test(
      'file backup restores all media beyond both old limits and map positions',
      () async {
    const password = 'complete archive password';
    final service = container.read(backupServiceProvider);
    final files = <File>[];
    final chunk = Uint8List(1024 * 1024);
    for (var i = 0; i < chunk.length; i++) {
      chunk[i] = i % 251;
    }
    for (final directory in [
      'cubechat-inbox',
      'cubechat-outbox',
      'cubechat-circles'
    ]) {
      final dir = await mediaDirectory(directory);
      final file = File('${dir.path}/video.mp4');
      final sink = file.openWrite();
      for (var i = 0; i < 17; i++) {
        sink.add(chunk);
        await sink.flush();
      }
      await sink.close();
      files.add(file);
    }
    for (final directory in [
      'cubechat-images',
      'cubechat-sent',
      'cubechat-audio',
      'cubechat-stickers',
      'cubechat-saved',
      'cubechat-wallpaper'
    ]) {
      final dir = await mediaDirectory(directory);
      final file = File('${dir.path}/sample');
      await file.writeAsBytes([1, 2, 3]);
      files.add(file);
    }
    final presence = container.read(mapPresenceStoreProvider.notifier);
    // Record immediately, before the asynchronous Hive open completes.
    presence.record(
        'alice', const SharedLocation(latitude: 50.4, longitude: 30.5));
    final archive = File('${phone.path}/complete.cchatbackup');
    await service.createFile(archive, password: password);
    expect(await archive.length(), greaterThan(51 * 1024 * 1024));
    await expectLater(service.create(password: password), throwsStateError);
    for (final file in files) {
      await file.delete();
    }
    presence.record('alice', const SharedLocation(latitude: 1, longitude: 2),
        sentAt: DateTime.now().add(const Duration(seconds: 1)));
    await presence.flush();
    await service.restoreFile(archive, password: password);
    for (final file in files.take(3)) {
      expect(await file.length(), 17 * 1024 * 1024);
      var offset = 0;
      await for (final bytes in file.openRead()) {
        for (final byte in bytes) {
          if (byte != chunk[offset % chunk.length])
            fail('Restored media differs at $offset');
          offset++;
        }
      }
    }
    for (final file in files.skip(3)) {
      expect(await file.readAsBytes(), [1, 2, 3]);
    }
    await container.read(mapPresenceStoreProvider.notifier).loaded;
    expect(container.read(mapPresenceStoreProvider)['alice']!.location.latitude,
        50.4);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('file importer accepts legacy encrypted backup', () async {
    final service = container.read(backupServiceProvider);
    final dir = await mediaDirectory('cubechat-inbox');
    final file = File('${dir.path}/document.pdf');
    await file.writeAsBytes([4, 5, 6]);
    final archive = File('${phone.path}/legacy.cchatbackup');
    await archive
        .writeAsBytes(await service.create(password: 'legacy password'));
    await file.delete();
    await service.restoreFile(archive, password: 'legacy password');
    expect(await file.readAsBytes(), [4, 5, 6]);
  });

  test('failed authentication leaves local settings and media unchanged',
      () async {
    final settings =
        await hiveCipherProvider.openEncryptedBox<dynamic>(HiveBoxes.settings);
    await settings.put('marker', 'backup');
    final dir = await mediaDirectory('cubechat-audio');
    final file = File('${dir.path}/voice.m4a');
    await file.writeAsBytes([1, 2, 3]);
    final service = container.read(backupServiceProvider);
    final archive = File('${phone.path}/bad.cchatbackup');
    await service.createFile(archive, password: 'correct password');
    await settings.put('marker', 'current');
    await file.writeAsBytes([9]);
    final handle = await archive.open(mode: FileMode.append);
    await handle
        .truncate(await handle.length() - 20); // remove authenticated end
    await handle.close();
    await expectLater(
        service.restoreFile(archive, password: 'correct password'),
        throwsFormatException);
    expect(settings.get('marker'), 'current');
    expect(await file.readAsBytes(), [9]);
    expect(
        phone
            .listSync()
            .whereType<Directory>()
            .where((d) => d.path.contains('cubechat-restore-')),
        isEmpty);
  });
}
