import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Symmetric crypto for shared-key group channels.
///
/// A channel is addressed by a human name (e.g. `#general`) plus an optional
/// password. Every member derives the same 32-byte key from (name, password)
/// and encrypts each channel message under it with ChaCha20-Poly1305. Channel
/// messages travel as *broadcast* [TransportEnvelope]s (cipher tag 0x03) so
/// the existing mesh relay + dedup machinery distributes them to every member
/// exactly like a peer-announcement — no new transport path required.
///
/// The 8-byte [deriveTag] value is sent in the clear at the head of the body
/// so a receiver can pick which of its joined channels a frame belongs to
/// without trial-decrypting under every key. It's a one-way hash of the key,
/// so it leaks nothing about the key or the (name, password).
///
/// This layer is deliberately **not** forward-secret: a shared symmetric key
/// can't be ratcheted per-sender without a group key-agreement protocol
/// (MLS-style), which is out of scope. Author authenticity still holds — the
/// plaintext is an Ed25519 [SignedPayload], so members can attribute each
/// message and a non-member (lacking the key) learns nothing but the frame's
/// existence.
class ChannelCrypto {
  ChannelCrypto._();

  static const int keyLen = 32;
  static const int tagLen = 8;
  static const int nonceLen = 12;
  static const int macLen = 16;

  static final _aead = Chacha20.poly1305Aead();
  static final _blake = Blake2s();

  static const _keyDomain = 'cubechat-channel-key-v1';
  static const _tagDomain = 'cubechat-channel-tag-v1';

  /// Derive the 32-byte channel key from a [name] and (possibly empty)
  /// [password]. `name` is expected to include its leading `#`. The domain
  /// separator and the NUL delimiters stop a name/password pair from
  /// colliding with a different split that concatenates to the same bytes.
  static Future<Uint8List> deriveKey(String name, String password) async {
    final material = <int>[
      ...utf8.encode(_keyDomain),
      0,
      ...utf8.encode(name),
      0,
      ...utf8.encode(password),
    ];
    final digest = await _blake.hash(material);
    return Uint8List.fromList(digest.bytes);
  }

  /// Public 8-byte selector for a channel, derived one-way from its [key].
  static Future<Uint8List> deriveTag(Uint8List key) async {
    final material = <int>[...utf8.encode(_tagDomain), ...key];
    final digest = await _blake.hash(material);
    return Uint8List.fromList(digest.bytes.sublist(0, tagLen));
  }

  /// Encrypt [plaintext] under [key]. Returns `[nonce:12][ciphertext][mac:16]`
  /// — the caller prepends the 8-byte channel tag + the 0x03 cipher tag.
  static Future<Uint8List> seal(Uint8List key, Uint8List plaintext) async {
    final nonce = _aead.newNonce();
    final box = await _aead.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce,
    );
    final out = Uint8List(nonceLen + box.cipherText.length + macLen);
    var c = 0;
    out.setRange(c, c += nonceLen, nonce);
    out.setRange(c, c += box.cipherText.length, box.cipherText);
    out.setRange(c, out.length, box.mac.bytes);
    return out;
  }

  /// Decrypt a `[nonce][ciphertext][mac]` [blob] under [key]. Throws on a bad
  /// tag (wrong key / tampering) or a truncated blob.
  static Future<Uint8List> open(Uint8List key, Uint8List blob) async {
    if (blob.length < nonceLen + macLen) {
      throw const FormatException('channel blob shorter than nonce + tag');
    }
    final nonce = blob.sublist(0, nonceLen);
    final ctEnd = blob.length - macLen;
    final ct = blob.sublist(nonceLen, ctEnd);
    final mac = blob.sublist(ctEnd);
    final clear = await _aead.decrypt(
      SecretBox(ct, nonce: nonce, mac: Mac(mac)),
      secretKey: SecretKey(key),
    );
    return Uint8List.fromList(clear);
  }
}
