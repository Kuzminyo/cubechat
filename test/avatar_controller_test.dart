import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/core/identity/avatar_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

/// A real JPEG, since the controller decodes what it is handed.
Uint8List _photo({int w = 900, int h = 600}) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(20, 200, 120));
  return Uint8List.fromList(img.encodeJpg(im, quality: 80));
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_avatar_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('a photo picked before the box finishes opening still persists',
      () async {
    // The box goes through the platform keystore, which is slow enough that a
    // user can pick a photo first. The write used to go to a null box and be
    // dropped: the avatar appeared to take, then was gone next launch.
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // Read the provider and set immediately — no awaiting the load.
    container.read(avatarProvider);
    final ok =
        await container.read(avatarProvider.notifier).setFromBytes(_photo());
    expect(ok, isTrue);
    expect(container.read(avatarProvider), isNotNull);

    // A fresh container reads what actually reached disk.
    final second = ProviderContainer();
    addTearDown(second.dispose);
    second.read(avatarProvider);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(second.read(avatarProvider), isNotNull,
        reason: 'the avatar should survive a restart');
  });

  test('shrinks and squares whatever it is given', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(avatarProvider);
    await container.read(avatarProvider.notifier).setFromBytes(
          _photo(w: 1600, h: 1200),
        );

    final stored = container.read(avatarProvider)!;
    final decoded = img.decodeImage(stored)!;
    expect(decoded.width, decoded.height, reason: 'must be square');
    expect(decoded.width, AvatarController.storedSize);
  });

  test('refuses bytes that are not an image', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(avatarProvider);
    final ok = await container
        .read(avatarProvider.notifier)
        .setFromBytes(Uint8List.fromList(List.filled(64, 7)));
    expect(ok, isFalse, reason: 'the caller has to be able to say so');
    expect(container.read(avatarProvider), isNull);
  });

  test('clearing survives a restart too', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(avatarProvider);
    await container.read(avatarProvider.notifier).setFromBytes(_photo());
    await container.read(avatarProvider.notifier).clear();

    final second = ProviderContainer();
    addTearDown(second.dispose);
    second.read(avatarProvider);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(second.read(avatarProvider), isNull);
  });
}
