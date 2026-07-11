import 'dart:typed_data';

import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';

/// Thin secp256k1 helpers for Nostr: x-only public keys and the ECDH shared
/// x-coordinate NIP-44 needs. Point arithmetic is delegated to pointycastle;
/// this file only does the Nostr-specific framing (x-only keys, even-y lift).
class Secp256k1 {
  Secp256k1._();

  static final ECDomainParameters _params = ECCurve_secp256k1();
  static final BigInt _p = BigInt.parse(
    'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F',
    radix: 16,
  );

  /// The x-only (BIP340) public key, 32-byte hex, for a 32-byte hex private key.
  static String publicKeyHex(String privHex) {
    final d = _bigFromHex(privHex);
    final point = (_params.G * d)!;
    return _hex32(point.x!.toBigInteger()!);
  }

  /// NIP-44 ECDH: the 32-byte x-coordinate of `priv · P`, where `P` is the
  /// even-y point whose x-coordinate is [pubXHex] (the x-only pubkey).
  static Uint8List ecdhSharedX(String privHex, String pubXHex) {
    final d = _bigFromHex(privHex);
    final x = _bigFromHex(pubXHex);
    final point = _params.curve.createPoint(x, _liftXEven(x));
    final shared = (point * d)!;
    return _bytes32(shared.x!.toBigInteger()!);
  }

  /// Recover the even-y coordinate for a curve point given its x (BIP340's
  /// "lift_x"): y = sqrt(x³ + 7) mod p, negated if odd so it's always even.
  static BigInt _liftXEven(BigInt x) {
    if (x <= BigInt.zero || x >= _p) {
      throw ArgumentError('pubkey x out of range');
    }
    final ySq = (x.modPow(BigInt.from(3), _p) + BigInt.from(7)) % _p;
    final y = ySq.modPow((_p + BigInt.one) ~/ BigInt.from(4), _p);
    if (y.modPow(BigInt.two, _p) != ySq) {
      throw ArgumentError('pubkey x is not on the curve');
    }
    return y.isEven ? y : _p - y;
  }

  static BigInt _bigFromHex(String hex) {
    if (hex.length != 64) {
      throw ArgumentError('expected 32-byte hex, got ${hex.length} chars');
    }
    return BigInt.parse(hex, radix: 16);
  }

  static String _hex32(BigInt v) => v.toRadixString(16).padLeft(64, '0');

  static Uint8List _bytes32(BigInt v) {
    final hex = _hex32(v);
    final out = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
