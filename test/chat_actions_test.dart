import 'dart:io';

import 'package:cubechat/app.dart';
import 'package:cubechat/features/channels/data/channel_controller.dart';
import 'package:cubechat/features/chats/data/favorites_controller.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/hive_settle.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_actions_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('long-pressing a chat picks it out for a bulk action',
      (tester) async {
    await tester.pumpWidget(const ProviderScope(child: CubechatApp()));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatsListScreen)));
    await container.read(channelControllerProvider.notifier).join('test');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('#test'), findsWidgets);

    await tester.longPress(find.text('#test').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The title row has become the selection bar: a count, and the actions
    // worth reaching without opening anything.
    expect(find.text('1'), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);

    // And the way out puts the header back.
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
  });

  testWidgets('favouriting from the selection menu persists', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: CubechatApp()));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatsListScreen)));
    await container.read(channelControllerProvider.notifier).join('test');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.longPress(find.text('#test').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The rest of the actions live behind the overflow on the selection bar.
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Add to favorites'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      container.read(favoritesControllerProvider).contains('#test'),
      isTrue,
    );
  });
  testWidgets('top panel search filters chats inline', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: CubechatApp()));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatsListScreen)));
    await container.read(channelControllerProvider.notifier).join('alpha');
    await container.read(channelControllerProvider.notifier).join('beta');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('#alpha'), findsWidgets);
    expect(find.text('#beta'), findsWidgets);

    await tester.tap(find.byIcon(Icons.search_rounded).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('#alpha'), findsWidgets);
    expect(find.text('#beta'), findsNothing);

    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('CubeChat'), findsOneWidget);
  });
}
