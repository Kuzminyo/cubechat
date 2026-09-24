import 'dart:io';

import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/core/storage/hive_init.dart';
import 'package:cubechat/features/moderation/data/terms_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

// Kept out of terms_gate_test.dart on purpose: a testWidgets pumped in that
// file earlier and a plain test() opening a real encrypted Hive box after it,
// in the same isolate, hung for 30s and timed out — both passed in under a
// second run on their own. `airdrop_lane_controller_test.dart`, which this
// file mirrors, has never mixed the two either. Not fully root-caused; not
// worth the risk of reproducing it here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_terms_');
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

  test('default is 0 (nothing accepted yet)', () async {
    final terms = container.read(termsControllerProvider.notifier);
    await terms.loaded;
    expect(container.read(termsControllerProvider), 0);
  });

  test('accept() persists currentTermsVersion, a fresh container reads it back',
      () async {
    final terms = container.read(termsControllerProvider.notifier);
    await terms.loaded;
    await terms.accept();
    expect(container.read(termsControllerProvider), currentTermsVersion);

    final relaunched = ProviderContainer();
    addTearDown(relaunched.dispose);
    await relaunched.read(termsControllerProvider.notifier).loaded;
    expect(relaunched.read(termsControllerProvider), currentTermsVersion);
  });

  test('reset() returns to 0 and deletes the key', () async {
    final terms = container.read(termsControllerProvider.notifier);
    await terms.loaded;
    await terms.accept();
    expect(container.read(termsControllerProvider), currentTermsVersion);

    await terms.reset();
    expect(container.read(termsControllerProvider), 0);

    final box =
        await hiveCipherProvider.openEncryptedBox<dynamic>(HiveBoxes.settings);
    expect(box.get(TermsController.storageKey), isNull);
  });

  group('a call before _load() finishes', () {
    // accept()/reset() are meant to work on a provider nobody has read yet -
    // that is exactly how the emergency wipe calls reset(). Deliberately do
    // not await `terms.loaded` before calling them, so the in-flight
    // _load() (still reading whatever the box already had) races the
    // caller's write. Same guard, same reason, as AirDropLaneController.

    test('accept() is not overwritten by the persisted value', () async {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      await box.put(TermsController.storageKey, 0);

      final terms = container.read(termsControllerProvider.notifier);
      await terms.accept();

      expect(container.read(termsControllerProvider), currentTermsVersion);
      expect(
        box.get(TermsController.storageKey),
        currentTermsVersion,
      );
    });

    test('reset() is not overwritten by the persisted value', () async {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      await box.put(TermsController.storageKey, currentTermsVersion);

      final terms = container.read(termsControllerProvider.notifier);
      await terms.reset();

      expect(container.read(termsControllerProvider), 0);
      expect(box.get(TermsController.storageKey), isNull);
    });
  });
}
