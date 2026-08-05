import 'dart:io';

import 'package:cubechat/features/channels/data/channel_descriptions_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_chandesc_test_');
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
      // Windows can retain a Hive handle very briefly after close.
    }
  });

  test('a topic round trips and survives a reload', () async {
    final descriptions =
        container.read(channelDescriptionsControllerProvider.notifier);
    await descriptions.loaded;
    expect(await descriptions.store('#team', '  Release planning  '), isTrue);
    // Stored trimmed — the wire carries what the box holds, and a topic that
    // differs only by whitespace would rebroadcast for nothing.
    expect(descriptions.forChannel('#team'), 'Release planning');

    final reloaded = ProviderContainer();
    addTearDown(reloaded.dispose);
    final after =
        reloaded.read(channelDescriptionsControllerProvider.notifier);
    await after.loaded;
    expect(after.forChannel('#team'), 'Release planning');
  });

  test('an empty topic clears rather than storing blank', () async {
    final descriptions =
        container.read(channelDescriptionsControllerProvider.notifier);
    await descriptions.loaded;
    await descriptions.store('#team', 'Something');
    expect(await descriptions.store('#team', '   '), isTrue);
    expect(descriptions.forChannel('#team'), isNull);
  });

  test('a topic past the cap is refused, not truncated', () async {
    final descriptions =
        container.read(channelDescriptionsControllerProvider.notifier);
    await descriptions.loaded;
    final tooLong = 'x' * (kChannelDescriptionMaxLength + 1);
    // Refused rather than silently cut: the sender is told, instead of
    // broadcasting something that is not what they typed.
    expect(await descriptions.store('#team', tooLong), isFalse);
    expect(descriptions.forChannel('#team'), isNull);
    expect(
      await descriptions.store('#team', 'y' * kChannelDescriptionMaxLength),
      isTrue,
    );
  });

  test('leaving a room forgets its topic', () async {
    final descriptions =
        container.read(channelDescriptionsControllerProvider.notifier);
    await descriptions.loaded;
    await descriptions.store('#team', 'Release planning');
    await descriptions.store('#other', 'Kept');
    await descriptions.forget('#team');
    expect(descriptions.forChannel('#team'), isNull);
    expect(descriptions.forChannel('#other'), 'Kept');
  });
}
