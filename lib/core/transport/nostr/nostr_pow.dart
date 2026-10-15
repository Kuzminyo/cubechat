import 'dart:convert';

import 'package:cryptography/dart.dart';

import 'nostr_event.dart';

/// NIP-13 proof of work, shared by the two servers that ask for it: Cube ID
/// on a claim or rename, and the push doorbell on a phone's first
/// registration. One miner, so the two can never disagree about what counts.

/// The number of leading zero bits of a digest — NIP-13's difficulty.
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

/// [unsigned] with a `nonce` tag appended whose value makes the event id
/// carry at least [bits] leading zero bits. The tags already there are kept,
/// in order, ahead of it.
///
/// Pure and synchronous so it can run in `Isolate.run`: hashing with the
/// async `Sha256` would cost an await per attempt, tens of thousands of them.
NostrEvent mineNonce(NostrEvent unsigned, int bits) {
  const sha = DartSha256();
  for (var nonce = 0;; nonce++) {
    final candidate = unsigned.copyWith(
      tags: [
        ...unsigned.tags,
        ['nonce', '$nonce', '$bits'],
      ],
    );
    final digest = sha.hashSync(utf8.encode(candidate.serializeForId())).bytes;
    if (leadingZeroBits(digest) >= bits) return candidate;
  }
}
