import 'dart:typed_data';

import 'package:cubechat/core/transport/peer_id.dart';
import 'package:flutter_test/flutter_test.dart';

/// A contact recognising a peer from what it broadcasts.
///
/// The advertisement is the only thing available before a handshake, and until
/// now it said nothing about identity — which is why an IK opener could not be
/// addressed at anyone met over Bluetooth. These pin the two halves that make
/// recognition work and keep it useless to a stranger.
void main() {
  Uint8List key(int base) =>
      Uint8List.fromList(List.generate(32, (i) => (base + i) & 0xFF));

  group('advertised rotating id', () {
    test('is what a contact resolves back to the peer', () async {
      final now = DateTime.now();
      final advertised = await PeerId.derive(key(1), PeerId.epochAt(now));

      final index = PeerIdIndex();
      final resolved = await index.lookup(
        advertised,
        rosterToken: Object(),
        pubkeys: [key(1), key(90)],
      );
      expect(resolved, equals(key(1)));
    });

    test('means nothing to someone without the key', () async {
      final advertised = await PeerId.derive(key(1), PeerId.epochAt(DateTime.now()));

      // A stranger's roster does not contain us.
      final index = PeerIdIndex();
      final resolved = await index.lookup(
        advertised,
        rosterToken: Object(),
        pubkeys: [key(90), key(200)],
      );
      expect(resolved, isNull);
    });

    test('is short enough for a BLE advertisement', () async {
      final id = await PeerId.derive(key(1), 100);
      // Service data on Android and the local name on iOS both have to fit
      // inside a 31-byte advertising payload alongside the service UUID.
      expect(id.length, 8);
      expect(PeerId.hex(id).length, 16);
    });

    test('changes between epochs, so a scanner cannot follow the device',
        () async {
      final a = await PeerId.derive(key(1), 100);
      final b = await PeerId.derive(key(1), 101);
      expect(PeerId.hex(a), isNot(equals(PeerId.hex(b))));
    });

    test('an id from the previous epoch still resolves', () async {
      // Advertising restarts a little after the boundary, and a scan result can
      // be a moment stale, so the id on the air briefly belongs to the epoch we
      // just left. The acceptance window is what keeps that from reading as a
      // stranger.
      final now = DateTime.now();
      final previous = await PeerId.derive(key(1), PeerId.epochAt(now) - 1);
      final index = PeerIdIndex();
      expect(
        await index.lookup(previous, rosterToken: Object(), pubkeys: [key(1)]),
        equals(key(1)),
      );
    });
  });

  group('parsing what lands in a scan result', () {
    /// Mirrors BleScanner._rotatingIdOf's local-name branch, which is how iOS
    /// carries the id — CoreBluetooth cannot advertise service data.
    String? parseLocalName(String name) {
      if (name.length == PeerId.len * 2 &&
          RegExp(r'^[0-9a-f]+$').hasMatch(name.toLowerCase())) {
        return name.toLowerCase();
      }
      return null;
    }

    test('accepts a well-formed id', () async {
      final id = PeerId.hex(await PeerId.derive(key(1), 100));
      expect(parseLocalName(id), equals(id));
      expect(parseLocalName(id.toUpperCase()), equals(id));
    });

    test('rejects a nickname from an older build', () {
      expect(parseLocalName('Anonymous cc88'), isNull);
      expect(parseLocalName('Roma'), isNull);
    });

    test('rejects anything of the wrong length', () {
      expect(parseLocalName('deadbeef'), isNull, reason: '8 chars, not 16');
      expect(parseLocalName('deadbeefdeadbeefdd'), isNull);
      expect(parseLocalName(''), isNull);
    });

    test('rejects non-hex of the right length', () {
      expect(parseLocalName('zzzzzzzzzzzzzzzz'), isNull);
    });
  });
}
