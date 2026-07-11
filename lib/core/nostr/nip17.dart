import 'dart:math';

import 'nip44.dart';
import 'nostr_event.dart';
import 'secp256k1.dart';

/// NIP-17 private direct messages, built on NIP-44 + NIP-59 gift wrapping.
///
/// Three nested events:
///   1. **rumor** (kind 14) — the unsigned message. Never signed, so it can't
///      be proven to third parties.
///   2. **seal** (kind 13) — the rumor, NIP-44-encrypted sender→recipient and
///      signed by the *sender*. This is what proves authorship to the recipient.
///   3. **gift wrap** (kind 1059) — the seal, NIP-44-encrypted under a
///      throwaway key→recipient and signed by that throwaway key. This is what
///      goes on relays; it hides the real sender from everyone but the
///      recipient, and its timestamp is randomized to blur metadata.
class Nip17 {
  Nip17._();

  static const int kindRumor = 14;
  static const int kindSeal = 13;
  static const int kindGiftWrap = 1059;

  static final _rng = Random.secure();

  /// Wrap [content] as a DM from [senderPrivHex] to [recipientPubHex]. The
  /// returned kind-1059 event is what you publish to relays.
  static NostrEvent wrap({
    required String senderPrivHex,
    required String recipientPubHex,
    required String content,
    List<List<String>> extraTags = const [],
    DateTime? now,
  }) {
    final base = now ?? DateTime.now();
    final senderPub = Secp256k1.publicKeyHex(senderPrivHex);

    final rumor = NostrEvent.rumor(
      pubkey: senderPub,
      createdAt: base.millisecondsSinceEpoch ~/ 1000,
      kind: kindRumor,
      tags: [
        ['p', recipientPubHex],
        ...extraTags,
      ],
      content: content,
    );

    final sealKey = Nip44.conversationKey(senderPrivHex, recipientPubHex);
    final seal = NostrEvent.signed(
      privHex: senderPrivHex,
      createdAt: _blurredTs(base),
      kind: kindSeal,
      tags: const [],
      content: Nip44.encrypt(rumor.encode(), sealKey),
    );

    final ephemeralPriv = _randomPrivHex();
    final wrapKey = Nip44.conversationKey(ephemeralPriv, recipientPubHex);
    return NostrEvent.signed(
      privHex: ephemeralPriv,
      createdAt: _blurredTs(base),
      kind: kindGiftWrap,
      tags: [
        ['p', recipientPubHex],
      ],
      content: Nip44.encrypt(seal.encode(), wrapKey),
    );
  }

  /// Unwrap a received [giftWrap] with [recipientPrivHex]. Returns the real
  /// sender's pubkey and the plaintext. Throws [FormatException] on any
  /// integrity failure — bad signature, wrong kind, or a rumor whose claimed
  /// author doesn't match the seal's signer (an impersonation attempt).
  static ({String senderPubHex, String content, int createdAt}) unwrap({
    required String recipientPrivHex,
    required NostrEvent giftWrap,
  }) {
    if (giftWrap.kind != kindGiftWrap) {
      throw const FormatException('not a gift wrap');
    }
    if (!giftWrap.verify()) {
      throw const FormatException('gift wrap signature invalid');
    }

    final wrapKey = Nip44.conversationKey(recipientPrivHex, giftWrap.pubkey);
    final seal = NostrEvent.decode(Nip44.decrypt(giftWrap.content, wrapKey));
    if (seal.kind != kindSeal) {
      throw const FormatException('inner event is not a seal');
    }
    if (!seal.verify()) {
      throw const FormatException('seal signature invalid');
    }

    final sealKey = Nip44.conversationKey(recipientPrivHex, seal.pubkey);
    final rumor = NostrEvent.decode(Nip44.decrypt(seal.content, sealKey));
    if (rumor.kind != kindRumor) {
      throw const FormatException('innermost event is not a rumor');
    }
    // The seal proves the sender; the rumor must claim that same author.
    if (rumor.pubkey != seal.pubkey) {
      throw const FormatException('sender mismatch (impersonation?)');
    }
    return (
      senderPubHex: rumor.pubkey,
      content: rumor.content,
      createdAt: rumor.createdAt,
    );
  }

  /// A timestamp backdated up to two days, per NIP-59, so relay observers can't
  /// correlate the wrap with the real send time.
  static int _blurredTs(DateTime base) {
    final jitter = _rng.nextInt(2 * 24 * 60 * 60);
    return base.millisecondsSinceEpoch ~/ 1000 - jitter;
  }

  static String _randomPrivHex() => List<int>.generate(32, (_) => _rng.nextInt(256))
      .map((x) => x.toRadixString(16).padLeft(2, '0'))
      .join();
}
