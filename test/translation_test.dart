import 'package:cubechat/features/chat/data/translation_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeTranslator implements Translator {
  String? detected = 'en';
  String? output = 'переклад';
  int identifyCalls = 0;
  int translateCalls = 0;
  String? lastFrom;
  String? lastTo;

  @override
  Future<String?> identify(String text) async {
    identifyCalls++;
    return detected;
  }

  @override
  Future<String?> translate(
    String text, {
    required String from,
    required String to,
  }) async {
    translateCalls++;
    lastFrom = from;
    lastTo = to;
    return output;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  late _FakeTranslator fake;
  late ProviderContainer container;

  setUp(() {
    fake = _FakeTranslator();
    container = ProviderContainer(
      overrides: [translatorProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);
  });

  test('a message is identified, then translated, and remembered', () async {
    final controller = container.read(translationProvider.notifier);

    final out = await controller.translate(
      messageId: 'm1',
      text: 'see you at six',
      target: 'uk',
    );

    expect(out, 'переклад');
    expect(container.read(translationProvider)['m1'], 'переклад');
    expect(fake.lastFrom, 'en');
    expect(fake.lastTo, 'uk');
  });

  test('a message already in the target language is left alone', () async {
    // Answering with a "translation" identical to the message is a worse
    // outcome than saying nothing: it looks like the feature misfired.
    fake.detected = 'uk';
    final controller = container.read(translationProvider.notifier);

    expect(
      await controller.translate(
        messageId: 'm1',
        text: 'привіт',
        target: 'uk',
      ),
      isNull,
    );
    expect(fake.translateCalls, 0);
  });

  test('a regional tag still counts as the same language', () async {
    // uk-UA into uk is not a translation.
    fake.detected = 'uk-UA';
    final controller = container.read(translationProvider.notifier);

    expect(
      await controller.translate(messageId: 'm1', text: 'привіт', target: 'uk'),
      isNull,
    );
    expect(fake.translateCalls, 0);
  });

  test('a language it cannot tell is not guessed at', () async {
    fake.detected = null;
    final controller = container.read(translationProvider.notifier);

    expect(
      await controller.translate(messageId: 'm1', text: '?!', target: 'uk'),
      isNull,
    );
    expect(fake.translateCalls, 0);
  });

  test('an unsupported pair loses the translation, not the message', () async {
    fake.output = null;
    final controller = container.read(translationProvider.notifier);

    expect(
      await controller.translate(messageId: 'm1', text: 'hello', target: 'uk'),
      isNull,
    );
    expect(container.read(translationProvider), isEmpty);
  });

  test('asking twice does not translate twice', () async {
    final controller = container.read(translationProvider.notifier);

    await controller.translate(messageId: 'm1', text: 'hi', target: 'uk');
    await controller.translate(messageId: 'm1', text: 'hi', target: 'uk');

    expect(fake.translateCalls, 1);
    expect(fake.identifyCalls, 1);
  });

  test('an empty message is not sent to the translator at all', () async {
    final controller = container.read(translationProvider.notifier);

    expect(
      await controller.translate(messageId: 'm1', text: '   ', target: 'uk'),
      isNull,
    );
    expect(fake.identifyCalls, 0);
  });

  test('a deleted message takes its translation with it', () async {
    final controller = container.read(translationProvider.notifier);
    await controller.translate(messageId: 'm1', text: 'hi', target: 'uk');

    controller.forget('m1');

    expect(container.read(translationProvider), isEmpty);
  });
}
