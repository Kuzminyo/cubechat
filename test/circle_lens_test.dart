import 'dart:io';

import 'package:cubechat/features/profile/data/circle_lens_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// Which camera a circle records with.
///
/// A setting rather than a button on the recorder, because the camera plugin
/// cannot hand a running capture to the other sensor. The thing worth pinning
/// is that it *survives a restart*: the default is the front lens, so a stored
/// "back" that arrives after something has already opened a camera looks
/// exactly like a setting that did not save — which is the shape of bug the
/// mesh switch had.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_lens_');
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
      // Windows can retain a Hive handle briefly after close.
    }
  });

  test('a circle is a message with your face in it, by default', () async {
    final lens = container.read(circleLensProvider.notifier);
    await lens.loaded;
    expect(container.read(circleLensProvider), isTrue);
  });

  test('the back camera survives a restart', () async {
    final lens = container.read(circleLensProvider.notifier);
    await lens.loaded;
    await lens.set(false);
    expect(container.read(circleLensProvider), isFalse);
    await settleBackgroundStorage();

    final next = ProviderContainer();
    addTearDown(next.dispose);
    final restored = next.read(circleLensProvider.notifier);
    // Waited for, exactly as the recorder waits: read before the box opens and
    // the answer is the default, whatever was stored.
    await restored.loaded;
    expect(next.read(circleLensProvider), isFalse);
  });

  test('a wipe puts it back to a fresh install', () async {
    final lens = container.read(circleLensProvider.notifier);
    await lens.loaded;
    await lens.set(false);
    await lens.reset();
    expect(container.read(circleLensProvider), isTrue);
    await settleBackgroundStorage();

    final next = ProviderContainer();
    addTearDown(next.dispose);
    final restored = next.read(circleLensProvider.notifier);
    await restored.loaded;
    expect(next.read(circleLensProvider), isTrue);
  });
}
