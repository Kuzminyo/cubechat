import 'dart:convert';
import 'dart:io';

import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/data/conversation_settings_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chat/presentation/chat_media_gallery_screen.dart';
import 'package:cubechat/features/chat/presentation/widgets/media_photo_surface.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Messages extends MessagesController {
  _Messages(this.path);
  final String path;
  @override
  Map<String, List<Message>> build() => {
        'test': [
          for (var i = 0; i < 3; i++)
            Message(
              id: 'image$i',
              chatId: 'test',
              text: '',
              sentAt: DateTime(2026),
              isMine: false,
              authorName: 'Test',
              kind: MessageKind.image,
              imagePath: path,
            ),
        ],
      };
}

class _Settings extends ConversationSettingsController {
  @override
  Map<String, ConversationSettings> build() => {};
}

void main() {
  testWidgets(
      'gallery pages horizontally then dismisses repeatedly with one finger',
      (tester) async {
    final directory =
        Directory.systemTemp.createTempSync('cubechat_gallery_gesture_');
    final file = File('${directory.path}/pixel.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==',
        ),
      );
    addTearDown(() {
      file.deleteSync();
      directory.deleteSync();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messagesControllerProvider.overrideWith(() => _Messages(file.path)),
          conversationSettingsControllerProvider.overrideWith(_Settings.new),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ChatMediaGalleryScreen(
                      chatId: 'test',
                      initialMessageId: 'image0',
                    ),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    for (var attempt = 0; attempt < 2; attempt++) {
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byType(MediaPhotoSurface).hitTestable().first,
        const Offset(-550, 0),
      );
      await tester.pumpAndSettle();
      final pager = tester.widget<PageView>(find.byType(PageView));
      expect(pager.controller!.page, 1);
      await tester.drag(
        find.byType(MediaPhotoSurface).hitTestable().first,
        const Offset(0, 220),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ChatMediaGalleryScreen), findsNothing);
      expect(find.text('Open'), findsOneWidget);
    }
  });
}
