import 'dart:io';

import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/core/storage/hive_init.dart';
import 'package:cubechat/features/airdrop/data/airdrop_lane_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_airdrop_lane_');
    Hive.init(tempDir.path);
    container = ProviderContainer();
  });

  tearDown(() async {
    await settleBackgroundStorage();
    container.dispose();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can briefly retain a Hive file handle after close.
    }
  });

  test('default is auto', () async {
    final lane = container.read(airdropLaneProvider.notifier);
    await lane.loaded;
    expect(container.read(airdropLaneProvider), AirDropLane.auto);
  });

  test('set(wifi) survives a new ProviderContainer over the same box',
      () async {
    final lane = container.read(airdropLaneProvider.notifier);
    await lane.loaded;
    await lane.set(AirDropLane.wifi);
    expect(container.read(airdropLaneProvider), AirDropLane.wifi);

    final relaunched = ProviderContainer();
    addTearDown(relaunched.dispose);
    await relaunched.read(airdropLaneProvider.notifier).loaded;
    expect(relaunched.read(airdropLaneProvider), AirDropLane.wifi);
  });

  test('an unknown stored string reads as auto', () async {
    final box =
        await hiveCipherProvider.openEncryptedBox<dynamic>(HiveBoxes.settings);
    await box.put(AirDropLaneController.storageKey, 'carrier-pigeon');

    final lane = container.read(airdropLaneProvider.notifier);
    await lane.loaded;
    expect(container.read(airdropLaneProvider), AirDropLane.auto);
  });

  test('reset() returns to auto and deletes the key', () async {
    final lane = container.read(airdropLaneProvider.notifier);
    await lane.loaded;
    await lane.set(AirDropLane.bluetooth);
    expect(container.read(airdropLaneProvider), AirDropLane.bluetooth);

    await lane.reset();
    expect(container.read(airdropLaneProvider), AirDropLane.auto);

    final box =
        await hiveCipherProvider.openEncryptedBox<dynamic>(HiveBoxes.settings);
    expect(box.get(AirDropLaneController.storageKey), isNull);
  });

  group('a call before _load() finishes', () {
    // set()/reset() are meant to work on a provider nobody has read yet -
    // that is exactly how the wipe calls reset(). Deliberately do not await
    // `lane.loaded` before calling them, so the in-flight _load() (still
    // reading whatever the box already had) races the caller's write.

    test('set(wifi) is not overwritten by the persisted value', () async {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      await box.put(AirDropLaneController.storageKey, AirDropLane.bluetooth.name);

      final lane = container.read(airdropLaneProvider.notifier);
      await lane.set(AirDropLane.wifi);

      expect(container.read(airdropLaneProvider), AirDropLane.wifi);
      expect(box.get(AirDropLaneController.storageKey), AirDropLane.wifi.name);
    });

    test('reset() is not overwritten by the persisted value', () async {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      await box.put(AirDropLaneController.storageKey, AirDropLane.wifi.name);

      final lane = container.read(airdropLaneProvider.notifier);
      await lane.reset();

      expect(container.read(airdropLaneProvider), AirDropLane.auto);
      expect(box.get(AirDropLaneController.storageKey), isNull);
    });
  });
}
