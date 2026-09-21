import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/app.dart';
import 'package:cubechat/features/chat/data/message_selection.dart';
import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/data/transcription_language.dart';
import 'package:cubechat/features/chat/data/translation_controller.dart';
import 'package:cubechat/features/chat/data/voice_transcription_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chat/presentation/chat_screen.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:cubechat/features/peers/data/known_peers_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

class _Ukrainian extends TranscriptionLanguageController {
  @override
  TranscriptionLanguage build() => TranscriptionLanguage.ukrainian;
}

class _FakeTranslator implements Translator {
  @override
  Future<String?> identify(String text) async => 'uk';

  @override
  Future<String?> translate(
    String text, {
    required String from,
    required String to,
  }) async =>
      'EN: $text';

  @override
  Future<void> dispose() async {}
}

/// "Перевод сделай в выделить смс и перевод": translation from the bar a
/// ticked message gets, beside copy and forward — for anything with words in
/// it, which a voice note has once the "→A" button has turned it into text.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;
  final peerHex = 'ab' * 32;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const transcribe = MethodChannel('cubechat/transcribe');

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_sel_translate_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(transcribe, null);
    await settleBackgroundStorage();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the Hive files briefly after close.
    }
  });

  Future<void> beat(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Finder inBar(IconData icon) => find.descendant(
        of: find.byType(ChatScreen),
        matching: find.byIcon(icon),
      );

  Future<ProviderContainer> openChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          translatorProvider.overrideWithValue(_FakeTranslator()),
          // Chosen already, so the transcription below does not wait on a
          // settings box opened in the test's fake-async zone.
          transcriptionLanguageProvider.overrideWith(_Ukrainian.new),
        ],
        child: const CubechatApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await beat(tester);

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatsListScreen)));
    container.read(knownPeersControllerProvider.notifier).upsert(
          pubkeyHex: peerHex,
          displayName: 'Alice',
          signPublicKey: Uint8List(32),
        );
    final messages = container.read(messagesControllerProvider.notifier);
    messages.append(
      peerHex,
      Message(
        id: 'm1',
        chatId: peerHex,
        text: 'ключі під килимком',
        sentAt: DateTime(2026, 9, 21, 10, 0),
        isMine: false,
        wireId: 'cd' * 16,
      ),
    );
    messages.append(
      peerHex,
      Message(
        id: 'v1',
        chatId: peerHex,
        text: 'audio/ogg',
        sentAt: DateTime(2026, 9, 21, 10, 1),
        isMine: false,
        wireId: 'ef' * 16,
        kind: MessageKind.audio,
        audioPath: '${tempDir.path}/v1.opus',
        audioMime: 'audio/ogg',
        audioDurationMs: 3000,
      ),
    );
    await beat(tester);
    await tester.tap(find.text('Alice').first);
    await beat(tester);
    return container;
  }

  testWidgets('a ticked message with words in it can be translated',
      (tester) async {
    final container = await openChat(tester);
    container.read(messageSelectionProvider(peerHex).notifier).start('m1');
    await beat(tester);

    expect(inBar(Icons.translate_rounded), findsOneWidget);
    await tester.tap(inBar(Icons.translate_rounded));
    await beat(tester);

    expect(
      container.read(translationProvider)['m1'],
      'EN: ключі під килимком',
    );
    expect(
      find.descendant(
        of: find.byType(ChatScreen),
        matching: find.text('EN: ключі під килимком'),
      ),
      findsOneWidget,
      reason: 'under the message, the way the long-press translation is',
    );
    expect(container.read(messageSelectionProvider(peerHex)), isEmpty);
  });

  testWidgets('a voice note is translatable once it has been transcribed',
      (tester) async {
    final container = await openChat(tester);
    container.read(messageSelectionProvider(peerHex).notifier).start('v1');
    await beat(tester);
    expect(
      inBar(Icons.translate_rounded),
      findsNothing,
      reason: 'no words yet: the "→A" button comes first',
    );

    messenger.setMockMethodCallHandler(
      transcribe,
      (_) async => 'привіт з голосового',
    );
    await tester.runAsync(
      () => container.read(voiceTranscriptionProvider.notifier).transcribe(
            messageId: 'v1',
            audioPath: '${tempDir.path}/v1.opus',
          ),
    );
    await beat(tester);

    expect(inBar(Icons.translate_rounded), findsOneWidget);
    await tester.tap(inBar(Icons.translate_rounded));
    await beat(tester);
    expect(
      container.read(translationProvider)['v1'],
      'EN: привіт з голосового',
    );
  });
}
