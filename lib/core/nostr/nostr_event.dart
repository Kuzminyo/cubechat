import 'dart:convert';
import 'dart:math';

import 'package:bip340/bip340.dart' as bip340;
import 'package:crypto/crypto.dart';

import 'secp256k1.dart';

/// A Nostr event (NIP-01). Immutable; build via [signed] or [rumor].
///
/// The id is `sha256` of the canonical serialization
/// `[0, pubkey, created_at, kind, tags, content]` — Dart's compact `jsonEncode`
/// already matches NIP-01's escaping rules (only `" \ \n \r \t \b \f` and other
/// control chars are escaped; non-ASCII stays raw UTF-8).
class NostrEvent {
  const NostrEvent({
    required this.id,
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
    required this.sig,
  });

  final String id;
  final String pubkey;
  final int createdAt;
  final int kind;
  final List<List<String>> tags;
  final String content;

  /// BIP340 signature hex, or empty for an unsigned rumor.
  final String sig;

  static final _rng = Random.secure();

  Map<String, dynamic> toJson() => {
        'id': id,
        'pubkey': pubkey,
        'created_at': createdAt,
        'kind': kind,
        'tags': tags,
        'content': content,
        'sig': sig,
      };

  String encode() => jsonEncode(toJson());

  factory NostrEvent.fromJson(Map<String, dynamic> j) => NostrEvent(
        id: j['id'] as String,
        pubkey: j['pubkey'] as String,
        createdAt: j['created_at'] as int,
        kind: j['kind'] as int,
        tags: ((j['tags'] as List?) ?? const [])
            .map((t) => (t as List).map((e) => e as String).toList())
            .toList(),
        content: j['content'] as String,
        sig: (j['sig'] as String?) ?? '',
      );

  factory NostrEvent.decode(String jsonStr) =>
      NostrEvent.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);

  static String computeId(
    String pubkey,
    int createdAt,
    int kind,
    List<List<String>> tags,
    String content,
  ) {
    final serialized = jsonEncode([0, pubkey, createdAt, kind, tags, content]);
    return _hex(sha256.convert(utf8.encode(serialized)).bytes);
  }

  /// True when the id matches the content and the BIP340 signature verifies.
  bool verify() {
    if (sig.length != 128) return false;
    if (computeId(pubkey, createdAt, kind, tags, content) != id) return false;
    return bip340.verify(pubkey, id, sig);
  }

  /// Build and sign an event with [privHex] (32-byte hex private key).
  static NostrEvent signed({
    required String privHex,
    required int createdAt,
    required int kind,
    required List<List<String>> tags,
    required String content,
  }) {
    final pubkey = Secp256k1.publicKeyHex(privHex);
    final id = computeId(pubkey, createdAt, kind, tags, content);
    final sig = bip340.sign(privHex, id, _auxHex());
    return NostrEvent(
      id: id,
      pubkey: pubkey,
      createdAt: createdAt,
      kind: kind,
      tags: tags,
      content: content,
      sig: sig,
    );
  }

  /// An unsigned rumor: the id is set, the sig is intentionally empty.
  static NostrEvent rumor({
    required String pubkey,
    required int createdAt,
    required int kind,
    required List<List<String>> tags,
    required String content,
  }) {
    return NostrEvent(
      id: computeId(pubkey, createdAt, kind, tags, content),
      pubkey: pubkey,
      createdAt: createdAt,
      kind: kind,
      tags: tags,
      content: content,
      sig: '',
    );
  }

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static String _auxHex() =>
      _hex(List<int>.generate(32, (_) => _rng.nextInt(256)));
}
