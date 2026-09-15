import 'package:cubechat/core/widgets/undo_toast.dart';
import 'package:cubechat/features/chats/data/hidden_chats_controller.dart';
import 'package:cubechat/features/chats/data/pending_chat_deletes.dart';
import 'package:cubechat/features/chats/models/chat.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _NothingHidden extends HiddenChatsController {
  @override
  Set<String> build() => const <String>{};
}

Chat _chat(String id) => Chat(
      id: id,
      peerId: id,
      peerName: id,
      lastMessage: 'hi',
      lastTime: DateTime(2026, 9, 15),
      unreadCount: 0,
      isMesh: false,
    );

/// Deleting a chat gives five seconds to take it back — "Чат видалено.
/// Скасувати", the way Telegram does it — and nothing is removed before they
/// are up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('held deletes', () {
    late ProviderContainer container;
    late PendingChatDeletes pending;
    late List<String> committed;

    setUp(() {
      container = ProviderContainer();
      pending = container.read(pendingChatDeletesProvider.notifier);
      committed = [];
    });
    tearDown(() => container.dispose());

    Future<void> Function() work(String id) => () async => committed.add(id);

    test('held is hidden, and nothing has run', () {
      pending.hold('a', work('a'));
      expect(container.read(pendingChatDeletesProvider), {'a'});
      expect(committed, isEmpty);
    });

    test('undo brings it back and runs nothing', () async {
      pending.hold('a', work('a'));
      expect(pending.undo('a'), isTrue);
      expect(container.read(pendingChatDeletesProvider), isEmpty);
      await pending.commit('a');
      expect(committed, isEmpty, reason: 'an undone delete cannot be committed');
      expect(pending.undo('a'), isFalse);
    });

    test('commit runs the delete once, then lets the id go', () async {
      pending.hold('a', work('a'));
      await pending.commit('a');
      await pending.commit('a');
      expect(committed, ['a']);
      expect(container.read(pendingChatDeletesProvider), isEmpty);
      expect(pending.undo('a'), isFalse, reason: 'too late once it has run');
    });

    test('the app leaving the screen commits everything held', () async {
      pending
        ..hold('a', work('a'))
        ..hold('b', work('b'));
      pending.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(committed, ['a', 'b']);
      expect(container.read(pendingChatDeletesProvider), isEmpty);
    });

    test('a glance at the shade does not', () async {
      pending.hold('a', work('a'));
      pending.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await Future<void>.delayed(Duration.zero);
      expect(committed, isEmpty);
    });

    test('a held chat is gone from the lists that read chats', () {
      final c = ProviderContainer(
        overrides: [
          allChatsProvider.overrideWith((ref) => [_chat('a'), _chat('b')]),
          hiddenChatsControllerProvider.overrideWith(_NothingHidden.new),
        ],
      );
      addTearDown(c.dispose);
      expect(c.read(chatsProvider).map((x) => x.id), ['a', 'b']);
      c.read(pendingChatDeletesProvider.notifier).hold('a', () async {});
      expect(c.read(chatsProvider).map((x) => x.id), ['b']);
      c.read(pendingChatDeletesProvider.notifier).undo('a');
      expect(c.read(chatsProvider).map((x) => x.id), ['a', 'b']);
    });
  });

  group('the toast', () {
    late OverlayState overlay;

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.expand())),
      );
      overlay = tester.state<OverlayState>(find.byType(Overlay).first);
    }

    testWidgets('counts down five seconds, then commits', (tester) async {
      await pump(tester);
      var undone = 0;
      var expired = 0;
      showUndoToast(
        overlay,
        message: 'Chat deleted.',
        undoLabel: 'Undo',
        onUndo: () => undone++,
        onExpire: () => expired++,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Chat deleted.'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      expect(find.text('3'), findsOneWidget);
      expect(expired, 0);

      await tester.pump(const Duration(seconds: 3));
      expect(expired, 1);
      expect(undone, 0);
      await tester.pumpAndSettle();
      expect(find.text('Chat deleted.'), findsNothing);
    });

    testWidgets('Undo takes it back and nothing is committed', (tester) async {
      await pump(tester);
      var undone = 0;
      var expired = 0;
      showUndoToast(
        overlay,
        message: 'Chat deleted.',
        undoLabel: 'Undo',
        onUndo: () => undone++,
        onExpire: () => expired++,
      );
      // One frame to start the entrance, one to finish it: a single pump
      // leaves the pane where it starts, below its own clip.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(undone, 1);

      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(expired, 0);
      expect(undone, 1);
      expect(find.text('Chat deleted.'), findsNothing);
    });

    testWidgets('a second delete commits the first at once', (tester) async {
      await pump(tester);
      final events = <String>[];
      showUndoToast(
        overlay,
        message: 'first',
        undoLabel: 'Undo',
        onUndo: () => events.add('undo first'),
        onExpire: () => events.add('commit first'),
      );
      await tester.pump(const Duration(seconds: 1));
      showUndoToast(
        overlay,
        message: 'second',
        undoLabel: 'Undo',
        onUndo: () => events.add('undo second'),
        onExpire: () => events.add('commit second'),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(events, ['commit first']);
      expect(find.text('first'), findsNothing);
      expect(find.text('second'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(events, ['commit first', 'commit second']);
    });
  });
}
