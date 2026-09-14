import 'package:cubechat/core/routing/tab_reset.dart';
import 'package:cubechat/features/chat/data/chat_scroll_memory.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A tab you leave comes back fresh; a conversation you leave does not.
///
/// "The profile photo stays opened when you come back; pages and open tabs
/// should not keep their state - but a chat should stay where it was scrolled
/// to, until the app is closed" was the whole request.
void main() {
  group('a tab left behind', () {
    test('is rebuilt once it has slid out of sight, not while it slides', () {
      fakeAsync((async) {
        final container = ProviderContainer();
        final tabs = container.read(tabGenerationsProvider.notifier);
        tabs.noteCurrent(4);
        tabs.noteCurrent(0);
        async.elapse(const Duration(milliseconds: 200));
        expect(container.read(tabGenerationsProvider)[4], isNull,
            reason: 'still on screen, sliding out');
        async.elapse(const Duration(milliseconds: 400));
        expect(container.read(tabGenerationsProvider)[4], 1);
        expect(container.read(tabGenerationsProvider)[0], isNull,
            reason: 'the tab now showing is left as it is');
        container.dispose();
      });
    });

    test('is not rebuilt when the finger comes straight back to it', () {
      fakeAsync((async) {
        final container = ProviderContainer();
        final tabs = container.read(tabGenerationsProvider.notifier);
        tabs.noteCurrent(4);
        tabs.noteCurrent(0);
        async.elapse(const Duration(milliseconds: 100));
        tabs.noteCurrent(4);
        async.elapse(const Duration(seconds: 1));
        expect(container.read(tabGenerationsProvider)[4], isNull);
        container.dispose();
      });
    });

    test('a rebuild asked for twice on one tab is one step each time', () {
      fakeAsync((async) {
        final container = ProviderContainer();
        final tabs = container.read(tabGenerationsProvider.notifier);
        tabs.noteCurrent(1);
        tabs.noteCurrent(0);
        async.elapse(const Duration(seconds: 1));
        tabs.noteCurrent(1);
        tabs.noteCurrent(0);
        async.elapse(const Duration(seconds: 1));
        expect(container.read(tabGenerationsProvider)[1], 2);
        container.dispose();
      });
    });
  });

  group('where a conversation was left', () {
    tearDown(ChatScrollMemory.forgetAll);

    test('is remembered per chat', () {
      ChatScrollMemory.save('alice', 1200);
      ChatScrollMemory.save('bob', 300);
      expect(ChatScrollMemory.of('alice'), 1200);
      expect(ChatScrollMemory.of('bob'), 300);
    });

    test('a chat left at the bottom opens at the bottom', () {
      ChatScrollMemory.save('alice', 1200);
      ChatScrollMemory.save('alice', 0);
      expect(ChatScrollMemory.of('alice'), isNull);
    });

    test('closing the app forgets every position', () {
      ChatScrollMemory.save('alice', 1200);
      ChatScrollMemory.forgetAll();
      expect(ChatScrollMemory.of('alice'), isNull);
    });
  });
}
