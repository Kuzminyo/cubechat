import 'dart:convert';
import 'dart:isolate';

import 'package:cryptography/dart.dart';

import '../../../core/transport/nostr/nostr_event.dart';
import '../../../core/transport/nostr/nostr_signer.dart';

/// Kind of every Cube ID operation. Its own kind, not push's 24242, so a push
/// registration can never be replayed as a Cube ID change or the other way.
const int cubeIdKind = 24243;

/// NIP-13 difficulty the server demands on claim and rename (`POW_BITS` in
/// `id/src/events.js`). A deterrent against scripted mass claims, alongside
/// the server's per-address and per-key rate limit.
///
/// 14, not the 16 the design started with: 16 bits measured 8–3835 ms (mean
/// 770 ms) over eight runs on the development PC (2026-09-29), and a phone is
/// slower than that — the tail would have been a claim button that spins for
/// ten seconds. 14 is a quarter of the work.
const int cubeIdPowBits = 14;

int leadingZeroBits(List<int> digest) {
  var bits = 0;
  for (final byte in digest) {
    if (byte == 0) {
      bits += 8;
      continue;
    }
    var b = byte;
    while (b & 0x80 == 0) {
      bits++;
      b = (b << 1) & 0xff;
    }
    break;
  }
  return bits;
}

/// Pure and synchronous so it can run in [Isolate.run]: hashing with the
/// async `Sha256` would cost an await per attempt, tens of thousands of them.
NostrEvent mineNonce(NostrEvent unsigned, int bits) {
  const sha = DartSha256();
  for (var nonce = 0;; nonce++) {
    final candidate = unsigned.copyWith(
      tags: [
        ['nonce', '$nonce', '$bits'],
      ],
    );
    final digest = sha.hashSync(utf8.encode(candidate.serializeForId())).bytes;
    if (leadingZeroBits(digest) >= bits) return candidate;
  }
}

/// A signed Cube ID operation. [Secp256k1NostrSigner.sign] computes the id
/// itself, so the mined nonce tag is part of the id it signs.
Future<NostrEvent> buildCubeIdEvent({
  required Secp256k1NostrSigner signer,
  required Map<String, Object?> content,
  required DateTime now,
  bool proofOfWork = false,
}) async {
  var event = NostrEvent(
    pubkey: signer.npubHex,
    createdAt: now.millisecondsSinceEpoch ~/ 1000,
    kind: cubeIdKind,
    tags: const <List<String>>[],
    content: jsonEncode(content),
  );
  if (proofOfWork) {
    final unsigned = event;
    event = await Isolate.run(() => mineNonce(unsigned, cubeIdPowBits));
  }
  return signer.sign(event);
}
