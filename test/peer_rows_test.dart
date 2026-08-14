import 'package:cubechat/features/peers/data/peer_discovery_controller.dart';
import 'package:cubechat/features/peers/models/discovered_peer.dart';
import 'package:flutter_test/flutter_test.dart';

DiscoveredPeer _peer(
  String id, {
  String? pubkey,
  String name = 'Anonymous',
  int secondsAgo = 0,
  bool connected = false,
}) =>
    DiscoveredPeer(
      id: id,
      advertisedName: name,
      rssi: -70,
      lastSeen: DateTime.now().subtract(Duration(seconds: secondsAgo)),
      resolvedPubkeyHex: pubkey,
      isConnected: connected,
    );

void main() {
  test('one contact seen at two addresses is one row', () {
    // What a rotation looks like from the radio: same person, two addresses,
    // two signal strengths, both listed until the old one goes stale.
    final rows = oneRowPerContact([
      _peer('44:3C', pubkey: 'admin1', name: 'Admin1', secondsAgo: 0),
      _peer('49:60', pubkey: 'admin1', name: 'Admin1', secondsAgo: 12),
    ]);

    expect(rows, hasLength(1));
    expect(rows.single.id, '44:3C', reason: 'the address answering now');
  });

  test('a live link wins over a fresher advertisement', () {
    final rows = oneRowPerContact([
      _peer('OLD', pubkey: 'admin1', secondsAgo: 5, connected: true),
      _peer('NEW', pubkey: 'admin1', secondsAgo: 0),
    ]);

    expect(rows.single.id, 'OLD');
  });

  test('strangers are never merged', () {
    // Two unresolved peers are two people as far as anything here knows, and
    // folding them together would hide one.
    final rows = oneRowPerContact([
      _peer('AA:AA'),
      _peer('BB:BB'),
    ]);

    expect(rows, hasLength(2));
  });

  test('a list with nothing doubled up is returned untouched', () {
    final peers = [
      _peer('AA:AA', pubkey: 'one'),
      _peer('BB:BB', pubkey: 'two'),
      _peer('CC:CC'),
    ];

    expect(identical(oneRowPerContact(peers), peers), isTrue);
  });
}
