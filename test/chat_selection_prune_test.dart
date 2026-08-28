import 'package:cubechat/features/chats/data/chat_selection_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The header stays in selection mode for as long as this set is not empty,
/// and the bar counts the rows it can *see* — so an id left behind for a chat
/// that no longer exists puts the app in selection mode over nothing, reading
/// "0". That is what deleting a selected chat used to leave on screen.
void main() {
  ProviderContainer container() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  test('an id for a chat that is gone stops being selected', () {
    final c = container();
    final selection = c.read(chatSelectionProvider.notifier)
      ..select('a')
      ..select('b');

    selection.retainOnly({'a'});

    expect(c.read(chatSelectionProvider), {'a'});
  });

  test('losing the last one leaves selection mode', () {
    final c = container();
    final selection = c.read(chatSelectionProvider.notifier)..select('a');

    selection.retainOnly({'b', 'c'});

    expect(
      c.read(chatSelectionProvider),
      isEmpty,
      reason: 'nothing picked is not a mode, it is the ordinary list',
    );
  });

  test('it does not touch a selection that is all still there', () {
    final c = container();
    final selection = c.read(chatSelectionProvider.notifier)
      ..select('a')
      ..select('b');
    final before = c.read(chatSelectionProvider);

    selection.retainOnly({'a', 'b', 'c'});

    expect(
      identical(c.read(chatSelectionProvider), before),
      isTrue,
      reason: 'this runs on every rebuild while picking; it must not churn',
    );
  });
}
