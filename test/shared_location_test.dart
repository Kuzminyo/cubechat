import 'dart:convert';

import 'package:cubechat/core/transport/shared_location.dart';
import 'package:flutter_test/flutter_test.dart';

/// A position rides inside an ordinary text message, so the codec is the whole
/// feature: everything downstream — encryption, signing, the mesh, the relay,
/// replies, forwarding — already worked and does not know this exists.
///
/// The parser is also the trust boundary. It reads bytes somebody else wrote,
/// and its answer ends up in a `geo:` URI handed to another app, so a hostile
/// or broken sender must fall out as null rather than as a pin somewhere
/// impossible.
void main() {
  test('a position survives the round trip', () {
    const sent = SharedLocation(
      latitude: 50.4501,
      longitude: 30.5234,
      accuracyMetres: 12,
    );
    final back = SharedLocation.tryParse(sent.encode());
    expect(back, isNotNull);
    expect(back!.latitude, closeTo(50.4501, 0.000001));
    expect(back.longitude, closeTo(30.5234, 0.000001));
    expect(back.accuracyMetres, 12);
    expect(back.expiresAt, isNull);
  });

  test('an expiry survives the round trip', () {
    final until = DateTime.now().add(const Duration(minutes: 15));
    final back = SharedLocation.tryParse(
      SharedLocation(latitude: 1, longitude: 2, expiresAt: until).encode(),
    );
    expect(back!.expiresAt, isNotNull);
    // Serialised to the second, so compare at that resolution.
    expect(
      back.expiresAt!.difference(until).inSeconds.abs(),
      lessThanOrEqualTo(1),
    );
    expect(back.expired, isFalse);
  });

  test('an expiry in the past reads as expired', () {
    final back = SharedLocation.tryParse(
      SharedLocation(
        latitude: 1,
        longitude: 2,
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      ).encode(),
    );
    expect(back!.expired, isTrue);
  });

  test('southern and western hemispheres are not mangled', () {
    final back = SharedLocation.tryParse(
      const SharedLocation(latitude: -33.8688, longitude: -151.2093).encode(),
    );
    expect(back!.latitude, closeTo(-33.8688, 0.000001));
    expect(back.longitude, closeTo(-151.2093, 0.000001));
  });

  group('anything that is not one of ours stays plain text', () {
    test('an ordinary message', () {
      expect(SharedLocation.tryParse('meet me at the bridge'), isNull);
    });

    test('a contact card, which shares the scheme but not the kind', () {
      expect(SharedLocation.tryParse('cubechat:contact:v1:AAAA'), isNull);
    });

    test('our prefix with rubbish behind it', () {
      expect(SharedLocation.tryParse('cubechat:loc:v1:!!!!'), isNull);
      expect(SharedLocation.tryParse('cubechat:loc:v1:'), isNull);
    });
  });

  group('a position that cannot exist is refused', () {
    String forged(String body) {
      // Built by hand rather than through encode(), which would reject these
      // itself — the point is what happens when the *other side* does not.
      const prefix = 'cubechat:loc:v1:';
      final b64 = const Base64Codec.urlSafe().encode(body.codeUnits);
      return '$prefix${b64.replaceAll('=', '')}';
    }

    test('a latitude past the pole', () {
      expect(SharedLocation.tryParse(forged('91.0,0.0,0,')), isNull);
      expect(SharedLocation.tryParse(forged('-91.0,0.0,0,')), isNull);
    });

    test('a longitude past the date line', () {
      expect(SharedLocation.tryParse(forged('0.0,181.0,0,')), isNull);
    });

    test('not a number at all', () {
      expect(SharedLocation.tryParse(forged('north,west,0,')), isNull);
      expect(SharedLocation.tryParse(forged('NaN,0.0,0,')), isNull);
    });

    test('too few fields', () {
      expect(SharedLocation.tryParse(forged('1.0,2.0')), isNull);
    });
  });

  test('the maps link carries the coordinates and nothing else', () {
    const here = SharedLocation(latitude: 50.45, longitude: 30.52);
    final uri = here.geoUri;
    expect(uri.scheme, 'geo');
    // No tile server, no host: the phone resolves this to whichever maps app
    // the user chose, and nobody is asked for the square they are standing in.
    expect(uri.host, isEmpty);
    expect(uri.toString(), contains('50.45'));
    expect(uri.toString(), contains('30.52'));
  });

  test('the link the platform opens is the one it knows', () {
    const here = SharedLocation(latitude: 50.45, longitude: 30.52);
    // The test host is not iOS, so this is the Android answer; the iOS branch
    // is the reason the getter exists at all — `geo:` has no handler there and
    // the tap did nothing but raise an error toast.
    expect(here.mapsUri, here.geoUri);
    expect(here.mapsUri.toString(), contains('50.45'));
  });
}
