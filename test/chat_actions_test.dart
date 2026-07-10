import 'dart:io';

import 'package:cubechat/app.dart';
import 'package:cubechat/features/channels/data/channel_controller.dart';
import 'package:cubechat/features/chats/data/favorites_controller.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_actions_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('long-pressing a chat opens the actions popup', (tester) async {
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
    // Let the popup route animate in (not pumpAndSettle: the aurora animates
    // forever, so the tree never settles).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The popup carries both actions — proof it opened (and, being on the root
    // navigator, above the floating bar).
    expect(find.text('Delete chat'), findsOneWidget);
    expect(find.text('Add to favorites'), findsOneWidget);
  });

  testWidgets('favoriting from the popup persists and re-sorts', (tester) async {
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

    await tester.tap(find.text('Add to favorites'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      container.read(favoritesControllerProvider).contains('#test'),
      isTrue,
    );
  });
}
