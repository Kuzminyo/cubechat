import 'dart:io';

import 'package:cubechat/features/chat/data/reaction_emoji_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// The strip of emoji the long-press menu offers, and what a double-tap leaves.
///
/// Both used to be constants in the bubble's source. What is pinned here is
/// that they now follow use: the head of the list is what the gesture reaches
/// for, so promoting an emoji has to move it there.
void main() {
  // The Hive cipher reads its key through a platform channel; without a binding
  // it falls back to a session-only key and logs about it.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_reactions_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the Hive files briefly after close.
    }
  });

  test('a fresh install offers the stock six, heart first', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(reactionEmojiControllerProvider),
        ReactionEmojiController.defaults);
    expect(
      container.read(reactionEmojiControllerProvider.notifier).quickReaction,
      '❤️',
      reason: 'double-tap left a heart long before the list existed',
    );
  });

  test('using an emoji moves it to the front of the strip', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(reactionEmojiControllerProvider.notifier);

    await controller.remember('😂');

    expect(container.read(reactionEmojiControllerProvider).first, '😂');
    expect(controller.quickReaction, '😂');
    expect(
      container.read(reactionEmojiControllerProvider),
      hasLength(ReactionEmojiController.maxEntries),
      reason: 'promoting one already in the list must not lengthen it',
    );
  });

  test('an emoji from the picker pushes the least used one off the end',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(reactionEmojiControllerProvider.notifier);
    final dropped = ReactionEmojiController.defaults.last;

    await controller.remember('🦄');

    final strip = container.read(reactionEmojiControllerProvider);
    expect(strip.first, '🦄');
    expect(strip, hasLength(ReactionEmojiController.maxEntries));
    expect(strip, isNot(contains(dropped)));
  });

  test('a wipe restores the stock six', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(reactionEmojiControllerProvider.notifier);

    await controller.remember('🦄');
    await controller.reset();

    expect(container.read(reactionEmojiControllerProvider),
        ReactionEmojiController.defaults);
  });
}
