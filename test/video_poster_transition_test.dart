import 'dart:io';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chat/presentation/widgets/video_bubble.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('uncached poster waits for route entrance to finish', (tester) async {
    final dir = Directory.systemTemp.createTempSync('poster-transition');
    final file = File('${dir.path}/clip.mp4')..writeAsBytesSync([0]);
    final messenger = tester.binding.defaultBinaryMessenger;
    var calls = 0;
    messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => dir.path);
    messenger.setMockMethodCallHandler(const MethodChannel('cubechat/video_frame'), (_) async {
      calls++;
      return {'frame': false, 'durationMs': 1000};
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), null);
      messenger.setMockMethodCallHandler(const MethodChannel('cubechat/video_frame'), null);
      dir.deleteSync(recursive: true);
    });
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(ProviderScope(child: MaterialApp(
      navigatorKey: nav,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(),
    )));
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => Scaffold(
      body: VideoBubble(message: Message(id: 'transition', chatId: 'peer',
        text: 'video/mp4', sentAt: DateTime(2026), isMine: false,
        kind: MessageKind.file, filePath: file.path)),
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    expect(calls, 0);
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
