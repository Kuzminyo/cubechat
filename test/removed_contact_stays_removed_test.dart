import 'dart:io';

import 'package:cubechat/features/peers/data/known_peers_controller.dart';
import 'package:cubechat/features/peers/data/removed_contacts_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_removed_');
    Hive.init(tempDir.path);
    container = ProviderContainer();
  });

  tearDown(() async {
    container.dispose();
    await settleBackgroundStorage();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the Hive files briefly after close.
    }
  });

  KnownPeersController peers() =>
      container.read(knownPeersControllerProvider.notifier);
  RemovedContactsController removed() =>
      container.read(removedContactsControllerProvider.notifier);

  final alice = 'a' * 64;
  final bob = 'b' * 64;

  test('a removed contact is not re-created by what their radio says',
      () async {
    peers().upsert(pubkeyHex: alice, displayName: 'Alice');
    expect(container.read(knownPeersControllerProvider), contains(alice));

    await removed().remember(alice);
    await peers().forget(alice);

    // An announcement, a presence beacon, a completed handshake — every road
    // back into the roster runs through upsert, and this is the one they were
    // all taking within seconds of the delete.
    peers().upsert(pubkeyHex: alice, displayName: 'Alice');

    expect(
      container.read(knownPeersControllerProvider),
      isNot(contains(alice)),
      reason: 'removing somebody has to outlast their next broadcast',
    );
  });

  test('it stops exactly one person coming back', () async {
    await removed().remember(alice);
    peers().upsert(pubkeyHex: bob, displayName: 'Bob');
    expect(container.read(knownPeersControllerProvider), contains(bob));
  });

  test('news about somebody still in the roster is not blocked', () async {
    // The tombstone must not be able to freeze a live contact's name or keys:
    // it answers "do not invent this person", not "ignore this person".
    peers().upsert(pubkeyHex: alice, displayName: 'Alice');
    await removed().remember(alice);

    peers().upsert(pubkeyHex: alice, displayName: 'Alice Renamed');

    expect(
      container.read(knownPeersControllerProvider)[alice]?.displayName,
      'Alice Renamed',
    );
  });

  test('writing to us brings them back', () async {
    await removed().remember(alice);
    // What the transport does when a message actually arrives. Mail is never
    // worth losing to a preference.
    await removed().restore(alice);

    peers().upsert(pubkeyHex: alice, displayName: 'Alice');
    expect(container.read(knownPeersControllerProvider), contains(alice));
  });

  test('a wipe leaves no tombstones behind', () async {
    await removed().remember(alice);
    await removed().clear();
    peers().upsert(pubkeyHex: alice, displayName: 'Alice');
    expect(container.read(knownPeersControllerProvider), contains(alice));
  });
}
