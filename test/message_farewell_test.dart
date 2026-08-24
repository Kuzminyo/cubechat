import 'package:cubechat/features/chat/data/message_farewell.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  MessageFarewell notifier(String chatId) =>
      container.read(messageFarewellProvider(chatId).notifier);

  Set<String> leaving(String chatId) =>
      container.read(messageFarewellProvider(chatId));

  test('the message is still there while it plays out, and gone after', () async {
    var removed = false;

    final done = notifier('anna').dismiss({'m1'}, () => removed = true);

    // The whole point of the inversion: the list can only animate a row it
    // still has. Deleting first leaves nothing to animate.
    expect(leaving('anna'), {'m1'});
    expect(removed, isFalse, reason: 'not deleted until the animation is over');

    await done;

    expect(removed, isTrue);
    expect(leaving('anna'), isEmpty, reason: 'the mark is not left behind');
  });

  test('a batch is marked in one go', () async {
    final done = notifier('anna').dismiss({'a', 'b', 'c'}, () {});
    expect(leaving('anna'), {'a', 'b', 'c'});
    await done;
    expect(leaving('anna'), isEmpty);
  });

  test('nothing to say goodbye to deletes immediately', () async {
    var removed = false;
    // A peer's delete for a message this device never had. Waiting 220 ms to
    // animate nothing would only delay the write.
    await notifier('anna').dismiss(const {}, () => removed = true);
    expect(removed, isTrue);
    expect(leaving('anna'), isEmpty);
  });

  test('a removal that throws still clears the mark', () async {
    // A mark that outlives its animation is worse than a failed delete: the
    // row stays collapsed to nothing, so the message looks deleted, is still
    // there, and comes back at the next launch with nothing to explain it.
    await expectLater(
      notifier('anna').dismiss({'m1'}, () => throw StateError('gone')),
      throwsStateError,
    );
    expect(leaving('anna'), isEmpty);
  });

  test('one conversation does not mark another', () async {
    final done = notifier('anna').dismiss({'m1'}, () {});
    expect(leaving('petro'), isEmpty);
    await done;
  });

  test('the deletion happens even if the screen is gone', () async {
    var removed = false;
    final done = notifier('anna').dismiss({'m1'}, () => removed = true);
    // Leaving the conversation mid-animation must not cancel what the user
    // asked for.
    container.dispose();
    await done;
    expect(removed, isTrue);
    // Re-created for the tearDown, which disposes it again.
    container = ProviderContainer();
  });
}
