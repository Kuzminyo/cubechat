import 'package:cubechat/features/peers/data/peer_discovery_controller.dart';
import 'package:cubechat/features/peers/models/discovered_peer.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

DiscoveredPeer _peer(
  String id, {
  String? pubkey,
  required int secondsAgo,
}) =>
    DiscoveredPeer(
      id: id,
      advertisedName: 'Anonymous',
      rssi: -70,
      lastSeen: DateTime.now().subtract(Duration(seconds: secondsAgo)),
      resolvedPubkeyHex: pubkey,
    );

void main() {
  late ProviderContainer container;
  late PeerDiscoveryController controller;

  setUp(() {
    container = ProviderContainer();
    controller = container.read(peerDiscoveryControllerProvider.notifier);
  });

  tearDown(() => container.dispose());

  void seed(List<DiscoveredPeer> peers) {
    controller.state = controller.state.copyWith(peers: peers);
  }

  test('a contact is found by identity, not by the name they broadcast', () {
    // Every modern peer advertises the anonymous default, so the name says
    // nothing about who is who. Only the resolved key does.
    seed([
      _peer('AA:AA', pubkey: 'beef', secondsAgo: 2),
      _peer('BB:BB', pubkey: 'cafe', secondsAgo: 1),
      _peer('CC:CC', secondsAgo: 1),
    ]);

    expect(controller.addressOf('cafe'), 'BB:BB');
    expect(controller.addressOf('beef'), 'AA:AA');
  });

  test('the freshest address wins when a peer has rotated', () {
    // The address they rotated away from is still listed until it goes stale,
    // and connecting to it costs the whole connect timeout.
    seed([
      _peer('OLD:ADDR', pubkey: 'beef', secondsAgo: 20),
      _peer('NEW:ADDR', pubkey: 'beef', secondsAgo: 1),
    ]);

    expect(controller.addressOf('beef'), 'NEW:ADDR');
  });

  test('somebody we cannot see has no address', () {
    seed([_peer('AA:AA', pubkey: 'beef', secondsAgo: 1)]);
    expect(controller.addressOf('cafe'), isNull);
  });

  test('waiting only accepts a sighting from after the ask', () async {
    // A stale entry must not satisfy the wait: it is the address that just
    // failed to answer.
    seed([_peer('OLD:ADDR', pubkey: 'beef', secondsAgo: 30)]);

    final waiting = controller.awaitAddressOf(
      'beef',
      timeout: const Duration(seconds: 2),
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));
    seed([
      _peer('OLD:ADDR', pubkey: 'beef', secondsAgo: 30),
      _peer('NEW:ADDR', pubkey: 'beef', secondsAgo: 0),
    ]);

    expect(await waiting, 'NEW:ADDR');
  });
}
