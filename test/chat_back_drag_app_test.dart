import 'dart:io';

import 'package:cubechat/app.dart';
import 'package:cubechat/features/chat/presentation/chat_screen.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

/// Dragging a conversation back, in the whole app: the tabs' Material page
/// under a chat pushed on the root navigator, which is the arrangement a
/// two-screen router in `back_gesture_test.dart` does not have.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_back_drag_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the Hive files briefly after close.
    }
  });

  Future<void> openChat(WidgetTester tester, {String? location}) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const ProviderScope(child: CubechatApp()));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));
    GoRouter.of(tester.element(find.byType(ChatsListScreen)))
        .push(location ?? '/chat/${'e' * 64}?name=Somebody');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(ChatScreen), findsOneWidget);
  }

  /// Where the chat page is, or null once it has gone.
  double? chatLeft(WidgetTester tester) {
    final chat = find.byType(ChatScreen);
    if (chat.evaluate().isEmpty) return null;
    return tester.getTopLeft(chat).dx;
  }

  Future<void> drag(
    WidgetTester tester, {
    required double distance,
    Duration step = const Duration(milliseconds: 16),
    double stepSize = 10,
  }) async {
    final gesture = await tester.startGesture(const Offset(200, 400));
    for (var moved = 0.0; moved < distance; moved += stepSize) {
      await gesture.moveBy(Offset(stepSize, 0));
      await tester.pump(step);
    }
    await gesture.up();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  for (final distance in <double>[80, 200, 320]) {
    testWidgets('let go after $distance px: the chat ends at an edge',
        (tester) async {
      await openChat(tester);
      await drag(tester, distance: distance);
      await settle(tester);
      final left = chatLeft(tester);
      expect(left == null || left == 0, isTrue,
          reason: 'the page was left at $left');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a slow drag that stops before letting go ends at an edge',
      (tester) async {
    await openChat(tester);
    final gesture = await tester.startGesture(const Offset(200, 400));
    for (var i = 0; i < 20; i++) {
      await gesture.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(chatLeft(tester), greaterThan(150),
        reason: 'the page follows the finger');
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await settle(tester);
    final left = chatLeft(tester);
    expect(left == null || left == 0, isTrue,
        reason: 'the page was left at $left');
  });

  for (final location in <String>['/chat/${'e' * 64}?name=S', '/channel/room']) {
    for (final distance in <double>[200]) {
      testWidgets('$location with the composer focused, $distance px',
          (tester) async {
        await openChat(tester, location: location);
        final field = find.descendant(
          of: find.byType(ChatScreen),
          matching: find.byType(EditableText),
        );
        if (field.evaluate().isNotEmpty) {
          await tester.tap(field.first);
          await tester.pump(const Duration(milliseconds: 300));
        }
        await drag(tester, distance: distance);
        await settle(tester);
        final left = chatLeft(tester);
        expect(left == null || left == 0, isTrue,
            reason: 'the page was left at $left');
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('back again right after springing back ends at an edge',
      (tester) async {
    await openChat(tester);
    await drag(tester, distance: 60);
    await tester.pump(const Duration(milliseconds: 60));
    await drag(tester, distance: 300);
    await settle(tester);
    final left = chatLeft(tester);
    expect(left == null || left == 0, isTrue,
        reason: 'the page was left at $left');
  });
}
