import 'dart:io';

import 'package:cubechat/features/chat/data/drafts_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_drafts_test_');
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
      // Windows may hold a Hive file briefly after close.
    }
  });

  test('drafts are stored per chat and empty text clears one', () async {
    final drafts = container.read(draftsControllerProvider.notifier);
    await drafts.loaded;

    drafts.update('alice', 'unfinished');
    drafts.update('#room', 'channel draft');
    expect(
      container.read(draftsControllerProvider)['alice']?.text,
      'unfinished',
    );
    expect(
      container.read(draftsControllerProvider)['#room']?.text,
      'channel draft',
    );

    drafts.update('alice', '   ');
    expect(
      container.read(draftsControllerProvider).containsKey('alice'),
      isFalse,
    );
    expect(
      container.read(draftsControllerProvider).containsKey('#room'),
      isTrue,
    );
  });

  test('a draft survives a provider restart', () async {
    final drafts = container.read(draftsControllerProvider.notifier);
    await drafts.loaded;
    drafts.update('alice', 'persist me');
    await Future<void>.delayed(const Duration(milliseconds: 450));

    final relaunched = ProviderContainer();
    addTearDown(relaunched.dispose);
    final restored = relaunched.read(draftsControllerProvider.notifier);
    await restored.loaded;

    expect(
      relaunched.read(draftsControllerProvider)['alice']?.text,
      'persist me',
    );
  });

  test('clear and clearAll remove drafts', () async {
    final drafts = container.read(draftsControllerProvider.notifier);
    await drafts.loaded;
    drafts.update('alice', 'one');
    drafts.update('bob', 'two');

    await drafts.clear('alice');
    expect(container.read(draftsControllerProvider).keys, ['bob']);
    await drafts.clearAll();
    expect(container.read(draftsControllerProvider), isEmpty);
  });
}
