import 'dart:io';

import 'package:cubechat/core/identity/nickname_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  // The Hive cipher reads its key through a platform channel; without a
  // binding it falls back to a session-only key and logs about it.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_nick_test_');
    Hive.init(tempDir.path);
    container = ProviderContainer();
  });

  tearDown(() async {
    container.dispose();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the Hive files briefly after close.
    }
  });

  NicknameController notifier() =>
      container.read(nicknameControllerProvider.notifier);

  test('starts at the default before anything is loaded', () {
    expect(container.read(nicknameControllerProvider),
        NicknameController.defaultNickname);
  });

  test('set() persists and is readable back', () async {
    await notifier().set('ипхон айос');
    expect(container.read(nicknameControllerProvider), 'ипхон айос');
    await notifier().loaded;
    // A fresh container over the same Hive dir must see the stored name.
    final second = ProviderContainer();
    addTearDown(second.dispose);
    await second.read(nicknameControllerProvider.notifier).loaded;
    expect(second.read(nicknameControllerProvider), 'ипхон айос');
  });

  // Regression: set() used to write through a `_box` that build() populated
  // asynchronously, so a rename issued before the box finished opening was
  // silently dropped and the old name came back on the next launch.
  test('a rename issued before the box opens is still persisted', () async {
    // No `await notifier().loaded` — set() races the open on purpose.
    await notifier().set('поко андроид');

    final second = ProviderContainer();
    addTearDown(second.dispose);
    await second.read(nicknameControllerProvider.notifier).loaded;
    expect(second.read(nicknameControllerProvider), 'поко андроид');
  });

  // The other half of that race: the disk read must not land *after* a rename
  // and clobber it.
  test('a slow load does not overwrite a name the user just set', () async {
    // Seed a stored value, then start a fresh container whose load is in
    // flight while we rename.
    await notifier().set('старое имя');
    await notifier().loaded;

    final second = ProviderContainer();
    addTearDown(second.dispose);
    final n = second.read(nicknameControllerProvider.notifier);
    // Rename immediately — build()'s _load() has not completed yet.
    await n.set('новое имя');
    await n.loaded;

    expect(second.read(nicknameControllerProvider), 'новое имя');
  });

  test('caps at maxLength and ignores empty input', () async {
    await notifier().set('   ');
    expect(container.read(nicknameControllerProvider),
        NicknameController.defaultNickname);

    final long = 'x' * (NicknameController.maxLength + 10);
    await notifier().set(long);
    expect(container.read(nicknameControllerProvider).length,
        NicknameController.maxLength);
  });
}
