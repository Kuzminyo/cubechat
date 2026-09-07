import 'dart:io';

import 'package:cubechat/features/chat/data/pinned_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'support/hive_settle.dart';

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
    await settleBackgroundStorage();
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

  test('pinning another message keeps both and selects the newest', () async {
    final n = notifier();
    await n.pin(chat, first);
    await n.pin(chat, second);
    expect(n.pinnedIn(chat)?.wireId, second);
    expect(n.pinnedAllIn(chat).map((pin) => pin.wireId), [first, second]);
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

  group('a pin only this phone can see', () {
    // Pinning was always an act performed on the other person: their carousel
    // changed too, because that is what makes "the address is at the top"
    // useful. A note to yourself in their conversation is a different thing to
    // want, and putting it in front of them is not part of it.
    test('is remembered as such', () async {
      final n = notifier();
      await n.loaded;
      await n.pin(chat, first, mineOnly: true);

      expect(n.isPinned(chat, first), isTrue);
      expect(n.isMineOnly(chat, first), isTrue);
    });

    test('a shared one is not', () async {
      final n = notifier();
      await n.loaded;
      await n.pin(chat, first);

      expect(n.isMineOnly(chat, first), isFalse);
    });

    test('survives a restart, and so does the difference', () async {
      // The flag decides whether unpinning tells the other side anything, so
      // losing it across a restart would mean quietly unpinning something on
      // somebody else's phone that was never pinned there.
      final first0 = notifier();
      await first0.loaded;
      await first0.pin(chat, first, mineOnly: true);
      await first0.pin(chat, second);
      await settleBackgroundStorage();

      final reopened = ProviderContainer();
      addTearDown(reopened.dispose);
      final n = reopened.read(pinnedControllerProvider.notifier);
      await n.loaded;

      expect(n.isMineOnly(chat, first), isTrue);
      expect(n.isMineOnly(chat, second), isFalse);
    });

    test('a pin written before this existed reads back as shared', () async {
      // Everything on disk today has no flag, and the absence has to mean
      // shared — those pins were mirrored when they were made.
      final n = notifier();
      await n.loaded;
      await n.pin(chat, first);
      expect(n.pinnedIn(chat)?.mineOnly, isFalse);
    });
  });
}
