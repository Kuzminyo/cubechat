import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/app.dart';
import 'package:cubechat/features/chat/data/message_reply_target.dart';
import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:cubechat/features/peers/data/known_peers_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/hive_settle.dart';

/// The two shortcuts that replace a long-press and a menu: drag a message left
/// to reply to it, double-tap it to leave a heart.
///
/// Both are pure gesture plumbing with nothing on the wire to assert against,
/// so what is pinned here is the observable result — the reply target the
/// composer reads, and the optimistic local echo a reaction leaves on the
/// message.
void main() {
  late Directory tempDir;

  final peerHex = 'ab' * 32;
  final wireId = 'cd' * 16;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_gestures_');
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

  Future<void> beat(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Stands up a 1:1 chat holding one inbound message and opens it.
  ///
  /// A peer rather than a channel because both gestures are 1:1: the composer
  /// only builds reply frames there, so the swipe is deliberately inert in a
  /// channel.
  Future<ProviderContainer> openPeerChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ProviderScope(child: CubechatApp()));
    await tester.pump(const Duration(milliseconds: 50));
    await beat(tester);

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatsListScreen)));

    container.read(knownPeersControllerProvider.notifier).upsert(
          pubkeyHex: peerHex,
          displayName: 'Alice',
          signPublicKey: Uint8List(32),
        );
    container.read(messagesControllerProvider.notifier).append(
          peerHex,
          Message(
            id: 'm1',
            chatId: peerHex,
            text: 'ключі під килимком',
            sentAt: DateTime(2026, 7, 27, 18, 20),
            isMine: false,
            wireId: wireId,
          ),
        );
    await beat(tester);

    await tester.tap(find.text('Alice').first);
    await beat(tester);
    return container;
  }

  testWidgets('dragging a message left files a reply to it', (tester) async {
    final container = await openPeerChat(tester);
    expect(container.read(messageReplyTargetProvider), isNull);

    await tester.drag(
      find.text('ключі під килимком').first,
      const Offset(-110, 0),
    );
    await beat(tester);

    final target = container.read(messageReplyTargetProvider);
    expect(target, isNotNull);
    expect(target!.wireId, wireId);
    expect(target.chatId, peerHex);
    expect(target.preview, contains('ключі'));
  });

  testWidgets('the bubble springs back rather than staying dragged',
      (tester) async {
    await openPeerChat(tester);
    final before = tester.getTopLeft(find.text('ключі під килимком').first);

    await tester.drag(
      find.text('ключі під килимком').first,
      const Offset(-110, 0),
    );
    await beat(tester);

    expect(
      tester.getTopLeft(find.text('ключі під килимком').first).dx,
      closeTo(before.dx, 0.5),
      reason: 'the swipe is a gesture, not a new resting position',
    );
  });

  testWidgets('a short drag is not enough to reply', (tester) async {
    final container = await openPeerChat(tester);

    await tester.drag(
      find.text('ключі під килимком').first,
      const Offset(-20, 0),
    );
    await beat(tester);

    expect(
      container.read(messageReplyTargetProvider),
      isNull,
      reason: 'brushing past a message must not quote it',
    );
  });

  testWidgets('dragging right does nothing', (tester) async {
    final container = await openPeerChat(tester);

    await tester.drag(
      find.text('ключі під килимком').first,
      const Offset(80, 0),
    );
    await beat(tester);

    expect(container.read(messageReplyTargetProvider), isNull);
  });

  testWidgets('vertical drags still belong to the list', (tester) async {
    final container = await openPeerChat(tester);

    await tester.drag(
      find.text('ключі під килимком').first,
      const Offset(0, -120),
    );
    await beat(tester);

    expect(
      container.read(messageReplyTargetProvider),
      isNull,
      reason: 'scrolling the conversation must not quote whatever it passes',
    );
  });

  testWidgets('double-tapping a message leaves a heart', (tester) async {
    final container = await openPeerChat(tester);

    final before = container.read(messagesControllerProvider)[peerHex]!.single;
    expect(before.reactions, isEmpty);

    final finder = find.text('ключі під килимком').first;
    await tester.tap(finder);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(finder);
    await beat(tester);

    final after = container.read(messagesControllerProvider)[peerHex]!.single;
    expect(
      after.reactions['❤️'],
      contains('me'),
      reason: 'the local echo lands immediately, before any transport',
    );
  });

  testWidgets('a reaction landing on a visible bubble pops its chip',
      (tester) async {
    // The chip has no previous state to differ from — it did not exist a frame
    // ago — so the only thing that can tell "a reaction just arrived" apart
    // from "the list scrolled this row back into view" is the bubble saying so.
    // This pins the arrival half; the scroll half is in pop_on_change_test.
    await openPeerChat(tester);

    final finder = find.text('ключі під килимком').first;
    await tester.tap(finder);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(finder);

    // Let the chip be built, then land partway up the arc.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));

    final scale = tester
        .widget<ScaleTransition>(
          find
              .ancestor(
                of: find.text('❤️'),
                matching: find.byType(ScaleTransition),
              )
              .first,
        )
        .scale
        .value;
    expect(
      scale,
      greaterThan(1),
      reason: 'the chip should swell as it arrives, not simply be there',
    );

    await beat(tester);
    final settled = tester
        .widget<ScaleTransition>(
          find
              .ancestor(
                of: find.text('❤️'),
                matching: find.byType(ScaleTransition),
              )
              .first,
        )
        .scale
        .value;
    expect(settled, moreOrLessEquals(1, epsilon: 0.001));
  });

  testWidgets('a single tap leaves no reaction', (tester) async {
    final container = await openPeerChat(tester);

    await tester.tap(find.text('ключі під килимком').first);
    await beat(tester);

    final after = container.read(messagesControllerProvider)[peerHex]!.single;
    expect(after.reactions, isEmpty);
  });
}
