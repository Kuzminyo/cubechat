// A backup that puts the conversations back and none of the pictures is not a
// backup, and that is what this one did.
//
// `_restoreMedia` screens the filename it was handed, because a key inside an
// archive is attacker-supplied and must not be allowed to name a location. One
// of the three screens was `fileName.contains(r'')` — an empty raw string,
// which every string contains — so the guard rejected every file there has
// ever been. The restore reported success, the history came back, and every
// photo, voice note and sticker it referred to was a grey box.
//
// Nothing caught it because the media half of a backup had no test: the box
// round-trip did, and that half was fine.
import 'dart:io';

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

  test('a photo and a voice note come back with the conversations', () async {
    const password = 'a password somebody would actually type';

    final images = await mediaDirectory('cubechat-images');
    final audio = await mediaDirectory('cubechat-audio');
    final photo = File('${images.path}${Platform.pathSeparator}photo-1.jpg')
      ..writeAsBytesSync(List<int>.generate(2048, (i) => i % 256));
    final note = File('${audio.path}${Platform.pathSeparator}voice-1.m4a')
      ..writeAsBytesSync(List<int>.generate(512, (i) => (i * 7) % 256));

    final service = container.read(backupServiceProvider);
    final archive = await service.create(password: password);

    // The phone this is restored onto does not have them.
    final photoBytes = photo.readAsBytesSync();
    final noteBytes = note.readAsBytesSync();
    photo.deleteSync();
    note.deleteSync();
    expect(photo.existsSync(), isFalse);

    await service.restore(archive, password: password);

    expect(
      photo.existsSync(),
      isTrue,
      reason: 'the archive carried this photo and the restore dropped it',
    );
    expect(note.existsSync(), isTrue);
    expect(photo.readAsBytesSync(), photoBytes);
    expect(note.readAsBytesSync(), noteBytes);
  });

  // The guard's *other* direction — a key in the archive that tries to name a
  // location outside the media directories — is not tested here, and saying so
  // is more use than a test that looks like it covers it and does not. Reaching
  // it means hand-building a payload around a private method; the screen itself
  // is three `contains` calls read directly above.
}
