// Decisions this device made about a contact are ours, not theirs.
//
// Blocking, muting and "may they put me in a forward link" are stored on the
// same `KnownPeer` record as the things a peer broadcasts about itself — its
// name, its keys, its picture. `upsert` is where a broadcast lands, and it
// builds a whole new record rather than editing the old one, so anything it
// forgets to carry silently reverts to its default.
//
// It forgot all three. A blocked contact only had to keep announcing itself to
// be unblocked, which is precisely what a blocked contact's radio keeps doing
// every few minutes, and the roster looked correct right up until it happened.
import 'dart:io';

import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/features/peers/data/known_peers_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  // Real storage, not a stub: `setBlocked` writes through to a box, and
  // without somewhere to write it throws — which under a loaded machine
  // surfaces as this file passing alone and failing in the suite.
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await hiveCipherProvider.wipe();
    tempDir = await Directory.systemTemp.createTemp('cubechat_peer_flags_');
    Hive.init(tempDir.path);
    container = ProviderContainer();
  });

  tearDown(() async {
    container.dispose();
    // The controller opens its box from `build()`, which nothing can await —
    // see [settleBackgroundStorage].
    await settleBackgroundStorage();
    await Hive.close();
    await hiveCipherProvider.wipe();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can briefly retain a Hive handle after close.
    }
  });

  KnownPeersController peers() =>
      container.read(knownPeersControllerProvider.notifier);

  const pubkey =
      'aa11bb22cc33dd44ee55ff6677889900aa11bb22cc33dd44ee55ff6677889900';

  test('a block survives the next announcement from the blocked peer',
      () async {
    final n = peers();
    n.upsert(pubkeyHex: pubkey, displayName: 'Domovoy');
    await n.setBlocked(pubkey, true);
    expect(n.isBlocked(pubkey), isTrue);

    // What a blocked peer's radio keeps doing, on its own, for as long as it
    // is in range.
    n.upsert(pubkeyHex: pubkey, displayName: 'Domovoy');

    expect(
      n.isBlocked(pubkey),
      isTrue,
      reason: 'an announcement is news about a person, not permission to '
          'change what this device decided about them',
    );
  });

  test('a mute survives the next announcement', () async {
    final n = peers();
    n.upsert(pubkeyHex: pubkey, displayName: 'Domovoy');
    await n.setMuted(pubkey, true);

    n.upsert(pubkeyHex: pubkey, displayName: 'Domovoy renamed');

    expect(container.read(knownPeersControllerProvider)[pubkey]?.isMuted,
        isTrue);
    // The rename still lands: this is about what a broadcast may not touch,
    // not about ignoring broadcasts.
    expect(container.read(knownPeersControllerProvider)[pubkey]?.displayName,
        'Domovoy renamed');
  });

  test('a withheld forward link survives the next announcement', () async {
    final n = peers();
    n.upsert(pubkeyHex: pubkey, displayName: 'Domovoy');
    await n.setAllowsForwardLink(pubkey, false);

    n.upsert(pubkeyHex: pubkey, displayName: 'Domovoy');

    expect(
      container.read(knownPeersControllerProvider)[pubkey]?.allowsForwardLink,
      isFalse,
    );
  });
}
