import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// A single Nostr event as defined by
/// [NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md).
///
/// cubechat only ever produces/consumes one event *kind* — an encrypted
/// direct message carrying an opaque cubechat [Frame] (see
/// [NostrFrameCodec]) — but the model itself is generic so the id/serialization
/// logic can be unit-tested against the spec independently of our usage.
///
/// The wire object a relay speaks is:
///
/// ```json
///   { "id": <32-byte hex sha256>, "pubkey": <32-byte hex xonly>,
///     "created_at": <unix seconds>, "kind": <int>,
///     "tags": [[..],..], "content": <string>, "sig": <64-byte hex schnorr> }
/// ```
///
/// The **id** is the lowercase-hex SHA-256 over the UTF-8 of the canonical
/// serialization `[0, pubkey, created_at, kind, tags, content]` with no
/// insignificant whitespace. Signing (the Schnorr `sig` over that id) lives
/// behind [NostrEventSigner] because it requires secp256k1 — a curve the app's
/// `cryptography` stack (Ed25519 / X25519) does not provide.
class NostrEvent {
  NostrEvent({
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
    this.id,
    this.sig,
  });

  /// Lowercase hex, 32-byte x-only secp256k1 public key of the author.
  final String pubkey;

  /// Unix timestamp in **seconds** (NIP-01 uses seconds, not millis).
  final int createdAt;

  final int kind;

  /// Ordered list of tags; each tag is a list whose first element is the tag
  /// name (`"p"` for a recipient pubkey, `"e"` for an event ref, …).
  final List<List<String>> tags;

  final String content;

  /// Lowercase-hex event id (sha256). Null until [computeId] / [withId] runs.
  final String? id;

  /// Lowercase-hex Schnorr signature. Null until a [NostrEventSigner] signs it.
  final String? sig;

  static final _sha256 = Sha256();

  /// NIP-01 canonical serialization used as the SHA-256 pre-image for [id].
  ///
  /// `jsonEncode` emits compact output (no spaces) and escapes strings exactly
  /// as NIP-01 requires for our content domain (base64 / hex — no raw control
  /// characters), so it is a faithful canonical form here.
  String serializeForId() {
    return jsonEncode(<Object>[0, pubkey, createdAt, kind, tags, content]);
  }

  /// Compute the lowercase-hex event id from the canonical serialization.
  Future<String> computeId() async {
    final digest = await _sha256.hash(utf8.encode(serializeForId()));
    return _hex(digest.bytes);
  }

  /// Returns a copy with [id] populated (computed from the current fields).
  Future<NostrEvent> withId() async {
    final computed = await computeId();
    return copyWith(id: computed);
  }

  /// True if [id] is present and matches a fresh recomputation over the
  /// current fields. Does **not** verify the Schnorr signature — that requires
  /// secp256k1 and is the relay/[NostrEventSigner]'s responsibility.
  Future<bool> hasValidId() async {
    final current = id;
    if (current == null) return false;
    return current == await computeId();
  }

  NostrEvent copyWith({
    String? pubkey,
    int? createdAt,
    int? kind,
    List<List<String>>? tags,
    String? content,
    String? id,
    String? sig,
  }) {
    return NostrEvent(
      pubkey: pubkey ?? this.pubkey,
      createdAt: createdAt ?? this.createdAt,
      kind: kind ?? this.kind,
      tags: tags ?? this.tags,
      content: content ?? this.content,
      id: id ?? this.id,
      sig: sig ?? this.sig,
    );
  }

  /// Relay-facing JSON map (the object inside `["EVENT", <this>]`).
  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'pubkey': pubkey,
        'created_at': createdAt,
        'kind': kind,
        'tags': tags,
        'content': content,
        if (sig != null) 'sig': sig,
      };

  static NostrEvent fromJson(Map<String, dynamic> json) {
    final rawTags = (json['tags'] as List<dynamic>? ?? const []);
    final tags = rawTags
        .map((t) => (t as List<dynamic>).map((e) => e as String).toList())
        .toList();
    return NostrEvent(
      id: json['id'] as String?,
      pubkey: json['pubkey'] as String,
      createdAt: json['created_at'] as int,
      kind: json['kind'] as int,
      tags: tags,
      content: json['content'] as String,
      sig: json['sig'] as String?,
    );
  }

  /// First value of the first tag named [name], or null.
  String? firstTagValue(String name) {
    for (final t in tags) {
      if (t.length >= 2 && t[0] == name) return t[1];
    }
    return null;
  }

  static String _hex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  @override
  String toString() =>
      'NostrEvent(kind=$kind, pubkey=${pubkey.substring(0, 8)}…, '
      'id=${id == null ? "unsigned" : "${id!.substring(0, 8)}…"})';
}
