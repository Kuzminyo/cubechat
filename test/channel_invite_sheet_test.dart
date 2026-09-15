import 'dart:io';

import 'package:cubechat/features/channels/presentation/channel_invite_sheet.dart';
import 'package:cubechat/features/chats/models/chat.dart';
import 'package:cubechat/features/contacts/presentation/contacts_screen.dart';
import 'package:cubechat/features/peers/data/known_peers_controller.dart';
import 'package:cubechat/features/peers/models/known_peer.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

KnownPeer _peer(String id, String name, {bool blocked = false}) => KnownPeer(
      pubkeyHex: id,
      displayName: name,
      lastSeen: DateTime(2026, 9, 15),
      blockedAt: blocked ? DateTime(2026, 9, 1) : null,
    );

Chat _contact(String id, String name) => Chat(
      id: id,
      peerId: id,
      peerName: name,
      lastMessage: 'hi',
      lastTime: DateTime(2026, 9, 15),
      unreadCount: 0,
      isMesh: false,
    );

class _Roster extends KnownPeersController {
  @override
  Map<String, KnownPeer> build() => {
        for (final p in [
          _peer('a' * 64, 'roma'),
          _peer('b' * 64, 'Anonymous'),
          _peer('c' * 64, 'Anonymous'),
          _peer('d' * 64, 'blocked one', blocked: true),
        ])
          p.pubkeyHex: p,
      };
}

/// "Add members" lists the people on the Contacts tab, not everybody this
/// phone has ever shaken hands with — which was a column of "Anonymous".
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_invite_');
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

  testWidgets('only contacts, by the name Contacts shows, never the blocked',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knownPeersControllerProvider.overrideWith(_Roster.new),
          contactChatsProvider.overrideWithValue([
            _contact('a' * 64, 'Roma (work)'),
            _contact('d' * 64, 'blocked one'),
          ]),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: ChannelInviteSheet(channelName: '#room')),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Roma (work)'), findsOneWidget);
    expect(find.text('Anonymous'), findsNothing,
        reason: 'strangers from the roster are not contacts');
    expect(find.text('blocked one'), findsNothing);
    expect(find.byType(CheckboxListTile), findsOneWidget);
  });
}
