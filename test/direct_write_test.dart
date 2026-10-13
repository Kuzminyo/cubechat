import 'package:cubechat/core/transport/direct_write.dart';
import 'package:flutter_test/flutter_test.dart';

/// Which road an AirDrop frame takes to the person next to you.
///
/// Reported 2026-10-13 with two logs of a bump between an S24+ and an iPhone:
/// "[AIRDROP] direct write failed: Bad state: outbound characteristic not
/// ready", then "[BUMP] could not reach" — while the same phones already had a
/// working session, over the iPhone's own connection to this phone's
/// peripheral. The write went to the central link, connected but still
/// discovering its services (ready 2.4 s later), and never tried the other
/// one.
void main() {
  DirectWritePath pick({
    bool hasClient = true,
    bool clientReady = false,
    bool clientConnected = true,
    bool peerIsCentral = false,
  }) =>
      directWritePath(
        hasClient: hasClient,
        clientReady: clientReady,
        clientConnected: clientConnected,
        peerIsCentral: peerIsCentral,
      );

  test('a ready link of ours is written to directly', () {
    expect(pick(clientReady: true), DirectWritePath.client);
    expect(
      pick(clientReady: true, peerIsCentral: true),
      DirectWritePath.client,
      reason: 'both links up: ours, as before',
    );
  });

  test('a link still finding its services is not written to', () {
    expect(
      pick(peerIsCentral: true),
      DirectWritePath.peripheral,
      reason: 'their own connection to us is already there to use',
    );
  });

  test('with nothing else to use, it waits for the link to become ready', () {
    expect(pick(), DirectWritePath.waitForClient);
  });

  test('only their connection to us: notified from our peripheral', () {
    expect(
      pick(hasClient: false, clientConnected: false, peerIsCentral: true),
      DirectWritePath.peripheral,
    );
  });

  test('no link at all is no road', () {
    expect(
      pick(hasClient: false, clientConnected: false),
      DirectWritePath.none,
    );
    expect(pick(clientConnected: false), DirectWritePath.none,
        reason: 'a dropped link is not one to wait for');
  });
}
