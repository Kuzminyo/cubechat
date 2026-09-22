import 'package:cubechat/features/chat/data/translation_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// What [MlKitTranslator] hands the ML Kit plugin.
///
/// 2026-09-22: every tap on "translate" closed the app. The recorded crash was
/// `IllegalArgumentException: Model name expected to be matching
/// [a-z]{2,3}_[a-z]{2,3}` — the model download was asked for "russian"
/// instead of "ru", and ML Kit throws that on a thread nothing can catch.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const translatorChannel = MethodChannel('google_mlkit_on_device_translator');
  const identifierChannel = MethodChannel('google_mlkit_language_identifier');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(translatorChannel, (call) async {
      calls.add(call);
      if (call.method == 'nlp#manageLanguageModelModels') return 'success';
      if (call.method == 'nlp#startLanguageTranslator') return 'hello';
      return null;
    });
    messenger.setMockMethodCallHandler(
      identifierChannel,
      (call) async => 'ru',
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(translatorChannel, null);
    messenger.setMockMethodCallHandler(identifierChannel, null);
  });

  test('models are asked for by language code, the way ML Kit names them',
      () async {
    final translator = MlKitTranslator();
    final out = await translator.translate('привет', from: 'ru', to: 'en');
    expect(out, 'hello');

    final models = [
      for (final c in calls)
        if (c.method == 'nlp#manageLanguageModelModels')
          (c.arguments as Map)['model'],
    ];
    expect(models, ['ru', 'en']);
    for (final model in models) {
      expect(model, matches(RegExp(r'^[a-z]{2,3}$')));
    }

    final start =
        calls.firstWhere((c) => c.method == 'nlp#startLanguageTranslator');
    expect((start.arguments as Map)['source'], 'ru');
    expect((start.arguments as Map)['target'], 'en');
  });

  test('a download never waits for Wi-Fi', () async {
    await MlKitTranslator().translate('привет', from: 'ru', to: 'en');
    for (final c in calls) {
      if (c.method != 'nlp#manageLanguageModelModels') continue;
      expect((c.arguments as Map)['wifi'], isFalse);
    }
  });
}
