import 'dart:io';

import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/peers/data/known_peers_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// "Last online" has to mean the person, not their phone.
///
/// A signed announcement arrives over a relay on a schedule whether or not
/// anybody has opened the app, and it goes through `upsert`. So the timestamp
/// the chat header was printing tracked the handset: an iOS contact who had not
/// touched their phone all day still read "offline · 17:47", because 17:47 was
/// when it last announced itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_presence_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the encrypted box briefly after close.
    }
  });

  final peer = 'ab' * 32;

  Future<KnownPeersController> controller(ProviderContainer c) async {
    final known = c.read(knownPeersControllerProvider.notifier);
    await settleBackgroundStorage();
    return known;
  }

  test('an announcement does not claim somebody was in the app', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final known = await controller(container);

    known.upsert(pubkeyHex: peer, displayName: 'Anonymous');
    await settleBackgroundStorage();
    expect(
      container.read(knownPeersControllerProvider)[peer]?.lastPresenceAt,
      isNull,
      reason: 'a radio being reachable says nothing about its owner',
    );
    expect(
      container.read(knownPeersControllerProvider)[peer]?.lastSeen,
      isNotNull,
      reason: 'the phone was heard from, which is what lastSeen is for',
    );
  });

  test('a presence beacon does', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final known = await controller(container);

    known.upsert(pubkeyHex: peer, displayName: 'Anonymous');
    await settleBackgroundStorage();
    await known.markPresent(peer);
    expect(
      container.read(knownPeersControllerProvider)[peer]?.lastPresenceAt,
      isNotNull,
    );
  });

  test('a later announcement does not move it back to now', () async {
    // The failure this whole change exists to stop: they close the app, their
    // phone keeps announcing, and the header keeps saying they were just here.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final known = await controller(container);

    known.upsert(pubkeyHex: peer, displayName: 'Anonymous');
    await settleBackgroundStorage();
    await known.markPresent(peer);
    final wasPresent =
        container.read(knownPeersControllerProvider)[peer]!.lastPresenceAt;

    await Future<void>.delayed(const Duration(milliseconds: 20));
    known.upsert(pubkeyHex: peer, displayName: 'Anonymous');
    await settleBackgroundStorage();

    expect(
      container.read(knownPeersControllerProvider)[peer]?.lastPresenceAt,
      wasPresent,
      reason: 'an announcement must not pass for somebody opening the app',
    );
  });

  test('a stored conversation answers before any beacon does', () async {
    // The regression this exists to stop. Trusting beacons alone was right and
    // left every existing contact with nothing to show: beacons only go
    // forward, so until somebody opened their app again the header said
    // "offline" and no more. Their messages were on disk the whole time.
    var container = ProviderContainer();
    var known = await controller(container);
    known.upsert(pubkeyHex: peer, displayName: 'Anonymous');
    await settleBackgroundStorage();
    final wrote = DateTime.now().subtract(const Duration(hours: 3));
    container.read(messagesControllerProvider.notifier).append(
          peer,
          Message(
            id: 'm1',
            chatId: peer,
            text: 'hello',
            isMine: false,
            sentAt: wrote,
            status: MessageStatus.delivered,
          ),
        );
    await settleBackgroundStorage();
    container.dispose();

    // A fresh launch: nothing has arrived, nobody has beaconed, and the answer
    // has to come off the stored history.
    container = ProviderContainer();
    addTearDown(container.dispose);
    known = await controller(container);
    await container.read(messagesControllerProvider.notifier).loaded;
    await settleBackgroundStorage();
    expect(
      container.read(knownPeersControllerProvider)[peer]?.lastPresenceAt
          ?.millisecondsSinceEpoch,
      wrote.millisecondsSinceEpoch,
    );
  });

  test('our own messages say nothing about them', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final known = await controller(container);
    known.upsert(pubkeyHex: peer, displayName: 'Anonymous');
    await settleBackgroundStorage();
    container.read(messagesControllerProvider.notifier).append(
          peer,
          Message(
            id: 'mine',
            chatId: peer,
            text: 'anyone there',
            isMine: true,
            sentAt: DateTime.now(),
            status: MessageStatus.sending,
          ),
        );
    await settleBackgroundStorage();
    expect(
      container.read(knownPeersControllerProvider)[peer]?.lastPresenceAt,
      isNull,
      reason: 'writing to somebody is not evidence they were there',
    );
  });

  test('it survives a restart', () async {
    var container = ProviderContainer();
    var known = await controller(container);
    known.upsert(pubkeyHex: peer, displayName: 'Anonymous');
    await settleBackgroundStorage();
    await known.markPresent(peer);
    final wasPresent =
        container.read(knownPeersControllerProvider)[peer]!.lastPresenceAt;
    await settleBackgroundStorage();
    container.dispose();

    container = ProviderContainer();
    addTearDown(container.dispose);
    known = await controller(container);
    expect(
      container.read(knownPeersControllerProvider)[peer]?.lastPresenceAt
          ?.millisecondsSinceEpoch,
      wasPresent?.millisecondsSinceEpoch,
    );
  });
}
