import 'dart:io';

import 'package:cubechat/features/chat/data/pinned_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  // The Hive cipher reads its key through a platform channel; without a binding
  // it falls back to a session-only key and logs about it.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_pins_test_');
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

  PinnedController notifier() =>
      container.read(pinnedControllerProvider.notifier);

  final chat = 'ab' * 32;
  final first = '11' * 16;
  final second = '22' * 16;

  test('pinning records the message for that chat', () async {
    final n = notifier();
    await n.pin(chat, first);
    expect(n.pinnedIn(chat)?.wireId, first);
    expect(n.isPinned(chat, first), isTrue);
    expect(n.isPinned(chat, second), isFalse);
  });

  test('pinning something else replaces the previous pin', () async {
    final n = notifier();
    await n.pin(chat, first);
    await n.pin(chat, second);
    expect(n.pinnedIn(chat)?.wireId, second);
    expect(container.read(pinnedControllerProvider), hasLength(1));
  });

  test('unpin clears it', () async {
    final n = notifier();
    await n.pin(chat, first);
    await n.unpin(chat);
    expect(n.pinnedIn(chat), isNull);
  });

  // Both sides can pin, so two pins can cross on the wire. An unpin naming the
  // message that is no longer pinned is the loser of that race and must not
  // clear the pin that replaced it.
  test('a stale unpin naming an older message is ignored', () async {
    final n = notifier();
    await n.pin(chat, second);
    await n.unpin(chat, wireId: first);
    expect(n.pinnedIn(chat)?.wireId, second);
  });

  test('pins are per chat', () async {
    final n = notifier();
    await n.pin(chat, first);
    await n.pin('#channel', second);
    expect(n.pinnedIn(chat)?.wireId, first);
    expect(n.pinnedIn('#channel')?.wireId, second);
  });

  test('a pin survives a restart', () async {
    final n = notifier();
    await n.loaded; // box open, so the pin below actually reaches disk
    await n.pin(chat, first);

    final relaunched = ProviderContainer();
    addTearDown(relaunched.dispose);
    final restored = relaunched.read(pinnedControllerProvider.notifier);
    await restored.loaded;
    expect(restored.pinnedIn(chat)?.wireId, first);
    expect(restored.pinnedIn(chat)?.pinnedAt, n.pinnedIn(chat)?.pinnedAt);
  });

  test('forget drops one chat, clear drops everything', () async {
    final n = notifier();
    await n.pin(chat, first);
    await n.pin('#channel', second);
    await n.forget(chat);
    expect(n.pinnedIn(chat), isNull);
    expect(n.pinnedIn('#channel')?.wireId, second);
    await n.clear();
    expect(container.read(pinnedControllerProvider), isEmpty);
  });
}
