import 'package:cubechat/features/peers/data/typing_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ProviderContainer container;
  late TypingController typing;

  setUp(() {
    container = ProviderContainer();
    typing = container.read(typingControllerProvider.notifier);
  });

  tearDown(() => container.dispose());

  test('a notice makes a peer typing, and only that peer', () {
    typing.record('alice');
    expect(typing.isTyping('alice'), isTrue);
    expect(typing.isTyping('bohdan'), isFalse);
  });

  test('a notice lapses on its own once the TTL is past', () {
    // Expiry is the primary stop mechanism, not the explicit stop frame: the
    // composer gets cleared by sending, the app gets backgrounded mid-word,
    // the link drops. The indicator has to end without being told.
    typing.record(
      'alice',
      at: DateTime.now().subtract(TypingController.ttl * 2),
    );
    expect(typing.isTyping('alice'), isFalse);
  });

  test('a fresh notice pushes the expiry out rather than stacking', () {
    typing.record(
      'alice',
      at: DateTime.now().subtract(TypingController.ttl * 2),
    );
    expect(typing.isTyping('alice'), isFalse);
    typing.record('alice');
    expect(typing.isTyping('alice'), isTrue);
  });

  test('an explicit stop ends it early', () {
    typing.record('alice');
    typing.clear('alice');
    expect(typing.isTyping('alice'), isFalse);
  });

  test('stopping someone who never started is harmless', () {
    typing.clear('nobody');
    expect(typing.isTyping('nobody'), isFalse);
  });

  test('a wipe leaves nobody typing', () {
    typing.record('alice');
    typing.record('bohdan');
    typing.clearAll();
    expect(typing.isTyping('alice'), isFalse);
    expect(typing.isTyping('bohdan'), isFalse);
  });
}
