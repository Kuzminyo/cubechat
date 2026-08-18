import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Minimal, self-contained **secp256k1 + BIP-340 Schnorr** implementation in
/// pure Dart, used only to give a cubechat identity a Nostr key pair (Nostr
/// events are Schnorr-signed over secp256k1, a curve the app's `cryptography`
/// stack — Ed25519 / X25519 — does not provide).
///
/// Correctness is pinned to the official
/// [BIP-340 test vectors](https://github.com/bitcoin/bips/blob/master/bip-0340/test-vectors.csv)
/// in `test/secp256k1_bip340_test.dart`.
///
/// **Security note:** the arithmetic is `BigInt`-based and therefore *not
/// constant-time*. That is an accepted trade-off for occasional message
/// signing on a phone; do not repurpose this for a high-frequency signing
/// oracle where timing side-channels matter.
class Secp256k1 {
  Secp256k1._();

  /// Field prime p = 2^256 − 2^32 − 977.
  static final BigInt p = BigInt.parse(
      'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F',
      radix: 16,
  );

  /// Group order n.
  static final BigInt n = BigInt.parse(
      'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141',
      radix: 16,
  );

  static final BigInt _gx = BigInt.parse(
      '79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798',
      radix: 16,
  );
  static final BigInt _gy = BigInt.parse(
      '483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8',
      radix: 16,
  );

  static final _g = _Point(_gx, _gy);
  static final _sha256 = Sha256();
  static final BigInt _seven = BigInt.from(7);

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// x-only (32-byte) public key for a 32-byte secret scalar, per BIP-340
  /// `pubkey(sk)`. Throws [ArgumentError] if the scalar is out of `[1, n-1]`.
  static Uint8List xonlyPubkey(Uint8List secretKey) {
    final d = _intFromBytes(secretKey);
    if (d < BigInt.one || d >= n) {
      throw ArgumentError('secret key out of range');
    }
    final pPoint = _mul(d, _g)!;
    return _bytes32(pPoint.x);
  }

  /// BIP-340 Schnorr signature over the 32-byte [message] with [secretKey]
  /// (32 bytes) and 32-byte [auxRand]. Returns the 64-byte `r || s` signature.
  static Future<Uint8List> sign({
    required Uint8List secretKey,
    required Uint8List message,
    required Uint8List auxRand,
  }) async {
    if (message.length != 32) {
      throw ArgumentError('message must be 32 bytes');
    }
    if (auxRand.length != 32) {
      throw ArgumentError('auxRand must be 32 bytes');
    }
    final dPrime = _intFromBytes(secretKey);
    if (dPrime < BigInt.one || dPrime >= n) {
      throw ArgumentError('secret key out of range');
    }
    final pPoint = _mul(dPrime, _g)!;
    final d = pPoint.y.isEven ? dPrime : n - dPrime;

    final auxHash = await _taggedHash('BIP0340/aux', auxRand);
    final t = _xor(_bytes32(d), auxHash);

    final rand = await _taggedHash(
      'BIP0340/nonce',
      _concat([t, _bytes32(pPoint.x), message]),
    );
    final kPrime = _intFromBytes(rand) % n;
    if (kPrime == BigInt.zero) {
      throw StateError('nonce is zero (astronomically unlikely)');
    }
    final rPoint = _mul(kPrime, _g)!;
    final k = rPoint.y.isEven ? kPrime : n - kPrime;

    final challenge = await _taggedHash(
      'BIP0340/challenge',
      _concat([_bytes32(rPoint.x), _bytes32(pPoint.x), message]),
    );
    final e = _intFromBytes(challenge) % n;

    final s = (k + e * d) % n;
    final sig = _concat([_bytes32(rPoint.x), _bytes32(s)]);

    // Cheap self-check — a bad signature never leaves this function.
    if (!await verify(publicKey: _bytes32(pPoint.x), message: message, signature: sig)) {
      throw StateError('produced signature failed self-verification');
    }
    return sig;
  }

  /// BIP-340 verify: true iff [signature] (64 bytes) is valid for the 32-byte
  /// x-only [publicKey] over the 32-byte [message]. Never throws — malformed
  /// inputs return false.
  static Future<bool> verify({
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) async {
    if (publicKey.length != 32 || message.length != 32 || signature.length != 64) {
      return false;
    }
    final pPoint = _liftX(_intFromBytes(publicKey));
    if (pPoint == null) return false;

    final r = _intFromBytes(signature.sublist(0, 32));
    final s = _intFromBytes(signature.sublist(32, 64));
    if (r >= p || s >= n) return false;

    final challenge = await _taggedHash(
      'BIP0340/challenge',
      _concat([signature.sublist(0, 32), publicKey, message]),
    );
    final e = _intFromBytes(challenge) % n;

    // R = s·G − e·P
    final sG = _mul(s, _g);
    final eP = _mul(e, pPoint);
    final rPoint = _add(sG, _negate(eP));
    if (rPoint == null) return false; // point at infinity
    if (!rPoint.y.isEven) return false;
    return rPoint.x == r;
  }

  // ---------------------------------------------------------------------------
  // Curve arithmetic (affine)
  // ---------------------------------------------------------------------------

  /// Recover the even-y curve point with x-coordinate [x] (BIP-340 `lift_x`).
  /// Returns null when x ≥ p or x is not on the curve.
  static _Point? _liftX(BigInt x) {
    if (x >= p) return null;
    final c = (_modPow(x, BigInt.from(3)) + _seven) % p;
    final y = _modPow(c, (p + BigInt.one) ~/ BigInt.from(4));
    if ((y * y) % p != c) return null;
    return _Point(x, y.isEven ? y : p - y);
  }

  static _Point? _add(_Point? a, _Point? b) {
    if (a == null) return b;
    if (b == null) return a;
    if (a.x == b.x) {
      if ((a.y + b.y) % p == BigInt.zero) return null; // P + (−P) = ∞
      return _double(a);
    }
    final lambda = ((b.y - a.y) * _inv(b.x - a.x)) % p;
    final x3 = (lambda * lambda - a.x - b.x) % p;
    final y3 = (lambda * (a.x - x3) - a.y) % p;
    return _Point(x3 % p, y3 % p);
  }

  static _Point? _double(_Point a) {
    if (a.y == BigInt.zero) return null;
    final lambda = ((BigInt.from(3) * a.x * a.x) * _inv(BigInt.two * a.y)) % p;
    final x3 = (lambda * lambda - BigInt.two * a.x) % p;
    final y3 = (lambda * (a.x - x3) - a.y) % p;
    return _Point(x3 % p, y3 % p);
  }

  /// Scalar multiplication, in Jacobian coordinates.
  ///
  /// This is the hot spot of the whole file and it used to be the slowest
  /// possible shape of it. In affine coordinates every doubling and every
  /// addition needs a modular inverse, so one 256-bit scalar multiplication ran
  /// roughly 384 extended-Euclid inversions on 256-bit `BigInt`s — and a
  /// signature does four multiplications (two to sign, two more for the
  /// self-verify below), so about 1500 of them per Nostr event.
  ///
  /// Measured on 2026-08-18, before and after, on the same desktop:
  ///
  ///     sign    27.9 ms  →  9.7 ms
  ///     verify  13.9 ms  →  4.1 ms
  ///
  /// Signing is still four multiplications, not two: it verifies its own
  /// output before returning. That check is left in — it is the thing that
  /// catches a broken implementation before a bad signature leaves the phone —
  /// but it is where the next halving is, if this ever needs one. The one after
  /// that is a precomputed comb for G, which most of these multiplications use.
  ///
  /// On the phone that reported it, the app was signing an event per recipient
  /// plus read receipts and presence beacons — bursts of fifteen publishes
  /// inside a second — synchronously on the UI thread. Diagnostics read
  /// `build p90 18.6 ms` against `raster 3.5 ms`, with the merged platform/UI
  /// thread leading every other thread in the process by a factor of three.
  ///
  /// A Jacobian point (X, Y, Z) stands for the affine (X/Z², Y/Z³), with Z = 0
  /// as the point at infinity. Nothing in the loop divides; the single inverse
  /// left is the conversion back to affine at the end. The curve has a = 0,
  /// which is what makes the doubling formula this short.
  ///
  /// Left-to-right over the bits so the addend is always the *affine* base
  /// point, which allows the cheaper mixed addition. Correctness is unchanged
  /// and still pinned to the BIP-340 vectors — see the note at the top of the
  /// file; this is arithmetic, not protocol.
  ///
  /// Still not constant-time, and the security note above still applies: the
  /// branch below is taken on the bits of the scalar. It was not constant-time
  /// before either.
  static _Point? _mul(BigInt k, _Point point) {
    final kk = k % n;
    if (kk == BigInt.zero) return null;

    // The accumulator, at infinity.
    var x = BigInt.zero;
    var y = BigInt.one;
    var z = BigInt.zero;

    for (var i = kk.bitLength - 1; i >= 0; i--) {
      if (z != BigInt.zero) {
        (x, y, z) = _jacobianDouble(x, y, z);
      }

      if (!((kk >> i) & BigInt.one).isEven) {
        if (z == BigInt.zero) {
          x = point.x;
          y = point.y;
          z = BigInt.one;
        } else {
          // madd-2007-bl: Jacobian + affine.
          final z1z1 = (z * z) % p;
          final u2 = (point.x * z1z1) % p;
          final s2 = (point.y * z * z1z1) % p;
          final h = (u2 - x) % p;
          final r = (BigInt.two * ((s2 - y) % p)) % p;
          if (h == BigInt.zero) {
            if (r == BigInt.zero) {
              // The accumulator *is* the base point, so this add is a double.
              // Rare, but reachable, and the mixed formula would divide by
              // zero here and hand back a wrong point rather than fail.
              (x, y, z) = _jacobianDouble(x, y, z);
            } else {
              // P + (−P): back to infinity.
              x = BigInt.zero;
              y = BigInt.one;
              z = BigInt.zero;
            }
            continue;
          }
          final hh = (h * h) % p;
          final i4 = (BigInt.from(4) * hh) % p;
          final j = (h * i4) % p;
          final v = (x * i4) % p;
          final x3 = (r * r - j - BigInt.two * v) % p;
          final y3 = (r * (v - x3) - BigInt.two * y * j) % p;
          final zh = (z + h) % p;
          final z3 = (zh * zh - z1z1 - hh) % p;
          x = x3 % p;
          y = y3 % p;
          z = z3 % p;
        }
      }
    }

    if (z == BigInt.zero) return null;
    final zInv = _inv(z);
    final zInv2 = (zInv * zInv) % p;
    final zInv3 = (zInv2 * zInv) % p;
    return _Point((x * zInv2) % p, (y * zInv3) % p);
  }

  /// One Jacobian doubling, `dbl-2009-l`, valid because this curve has a = 0.
  ///
  /// Its own function, and not inlined twice, because `z3` is built from the
  /// *old* `y` — written out in two places, the second copy computed it from
  /// the new one and produced a plausible, wrong point.
  static (BigInt, BigInt, BigInt) _jacobianDouble(
    BigInt x,
    BigInt y,
    BigInt z,
  ) {
    final a = (x * x) % p;
    final b = (y * y) % p;
    final c = (b * b) % p;
    final xb = (x + b) % p;
    final d = (BigInt.two * ((xb * xb - a - c) % p)) % p;
    final e = (BigInt.from(3) * a) % p;
    final f = (e * e) % p;
    final x3 = (f - BigInt.two * d) % p;
    final y3 = (e * (d - x3) - BigInt.from(8) * c) % p;
    final z3 = (BigInt.two * y * z) % p;
    return (x3 % p, y3 % p, z3);
  }

  static _Point? _negate(_Point? a) => a == null ? null : _Point(a.x, (p - a.y) % p);

  // ---------------------------------------------------------------------------
  // Field / byte helpers
  // ---------------------------------------------------------------------------

  static BigInt _modPow(BigInt base, BigInt exp) => base.modPow(exp, p);

  /// Modular inverse mod p (input may be negative; normalised first).
  static BigInt _inv(BigInt a) => (a % p).modInverse(p);

  static BigInt _intFromBytes(Uint8List b) {
    var r = BigInt.zero;
    for (final byte in b) {
      r = (r << 8) | BigInt.from(byte);
    }
    return r;
  }

  static Uint8List _bytes32(BigInt v) {
    final out = Uint8List(32);
    var x = v;
    for (var i = 31; i >= 0; i--) {
      out[i] = (x & BigInt.from(0xff)).toInt();
      x = x >> 8;
    }
    return out;
  }

  static Uint8List _xor(Uint8List a, Uint8List b) {
    final out = Uint8List(a.length);
    for (var i = 0; i < a.length; i++) {
      out[i] = a[i] ^ b[i];
    }
    return out;
  }

  static Uint8List _concat(List<List<int>> parts) {
    final total = parts.fold<int>(0, (s, p) => s + p.length);
    final out = Uint8List(total);
    var c = 0;
    for (final part in parts) {
      out.setRange(c, c += part.length, part);
    }
    return out;
  }

  /// BIP-340 tagged hash: SHA256(SHA256(tag) || SHA256(tag) || msg).
  static Future<Uint8List> _taggedHash(String tag, Uint8List msg) async {
    final tagHash = (await _sha256.hash(utf8.encode(tag))).bytes;
    final data = _concat([tagHash, tagHash, msg]);
    final h = await _sha256.hash(data);
    return Uint8List.fromList(h.bytes);
  }
}

class _Point {
  _Point(this.x, this.y);
  final BigInt x;
  final BigInt y;
}
