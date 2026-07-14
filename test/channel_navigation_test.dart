import 'dart:io';

import 'package:cubechat/app.dart';
import 'package:cubechat/features/channels/data/channel_controller.dart';
import 'package:cubechat/features/chat/presentation/chat_screen.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_nav_test_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('tapping a channel tile opens that channel', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: CubechatApp()));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatsListScreen)));
    await container.read(channelControllerProvider.notifier).join('ios team');

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // The channel shows up in the chat list as a tile.
    expect(find.text('#ios-team'), findsWidgets);

    await tester.tap(find.text('#ios-team').first);
    // pumpAndSettle would hang: the aurora backdrop animates forever, so the
    // tree never reaches a steady state. Pump the route transition by hand.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // …and tapping it must actually open the channel conversation.
    expect(find.byType(ChatScreen), findsOneWidget);
  });
}
