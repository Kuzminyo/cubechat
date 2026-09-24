import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../../../core/util/debug_log.dart';

/// Public half of the server's Ed25519 signing key. Never trust a downloaded
/// list unless its signature verifies against this key.
const banListPublicKeyHex =
    'a18bbcc304e9c41f586c9fb6bd2c77d0928fad2067b2d241d526eed34258a725';

class BanList {
  const BanList({
    this.updatedAt = 0,
    this.identities = const <String>{},
    this.npubs = const <String>{},
    this.fingerprints = const <String>{},
  });

  final int updatedAt;
  final Set<String> identities;
  final Set<String> npubs;
  final Set<String> fingerprints;

  bool isBannedIdentity(String hex) => identities.contains(hex.toLowerCase());
  bool isBannedPeer(String identityHex, List<int>? nostrPubkey) =>
      isBannedIdentity(identityHex) ||
      (nostrPubkey != null &&
          isBannedNpub(nostrPubkey
              .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
              .join()));
  bool isBannedNpub(String hex) => npubs.contains(hex.toLowerCase());
  bool isBannedFingerprint(String hex) =>
      fingerprints.contains(hex.toLowerCase());
}

String canonicalBanBody(Map<String, dynamic> body) =>
    jsonEncode(<String, Object?>{
      'v': body['v'],
      'updatedAt': body['updatedAt'],
      'identities': (body['identities'] as List<dynamic>).cast<String>()
        ..sort(),
      'npubs': (body['npubs'] as List<dynamic>).cast<String>()..sort(),
      'fingerprints': (body['fingerprints'] as List<dynamic>).cast<String>()
        ..sort(),
    });

List<int> _hexBytes(String hex) {
  if (hex.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(hex)) {
    throw const FormatException('invalid hex');
  }
  return <int>[
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}

/// Verifies the exact JSON byte sequence signed by `canonicalBanBody` in the
/// push server. Return null on *any* malformed or forged response.
Future<BanList?> verifyBanList(
  Map<String, dynamic> body, {
  String publicKeyHex = banListPublicKeyHex,
}) async {
  try {
    if (body['v'] != 1 || body['updatedAt'] is! int || body['sig'] is! String) {
      return null;
    }
    for (final field in <String>['identities', 'npubs', 'fingerprints']) {
      final values = body[field];
      if (values is! List ||
          values.any((dynamic value) =>
              value is! String ||
              !RegExp(r'^[0-9a-f]{16}([0-9a-f]{48})?$').hasMatch(value))) {
        return null;
      }
    }
    final bytes = utf8.encode(canonicalBanBody(body));
    final signature = Signature(
      _hexBytes(body['sig'] as String),
      publicKey: SimplePublicKey(
        _hexBytes(publicKeyHex),
        type: KeyPairType.ed25519,
      ),
    );
    if (!await Ed25519().verify(bytes, signature: signature)) return null;
    return BanList(
      updatedAt: body['updatedAt'] as int,
      identities: (body['identities'] as List<dynamic>).cast<String>().toSet(),
      npubs: (body['npubs'] as List<dynamic>).cast<String>().toSet(),
      fingerprints:
          (body['fingerprints'] as List<dynamic>).cast<String>().toSet(),
    );
  } catch (_) {
    return null;
  }
}

typedef BanListFetcher = Future<Map<String, dynamic>?> Function(Uri endpoint);

Future<Map<String, dynamic>?> _fetchBanList(Uri endpoint) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  try {
    final response = await (await client.getUrl(endpoint))
        .close()
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(await utf8.decoder.bind(response).join());
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (e) {
    DebugLog.instance.log('BAN', '${endpoint.host} did not answer: $e');
    return null;
  } finally {
    client.close(force: true);
  }
}

class BanListController extends Notifier<BanList> {
  BanListController({BanListFetcher? fetcher})
      : _fetcher = fetcher ?? _fetchBanList;

  static const storageKey = 'moderation.banList';
  static const refreshInterval = Duration(hours: 6);
  static final endpoints = <Uri>[
    Uri.parse('https://push.cubechat.tech/banned'),
    Uri.parse('https://209-38-225-225.sslip.io/banned'),
  ];

  final BanListFetcher _fetcher;
  Future<void>? _loading;
  Future<void>? _refreshing;
  Box<dynamic>? _box;
  DateTime? _lastFetch;

  @override
  BanList build() => const BanList();

  Future<void> _load() async {
    try {
      _box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      final raw = _box?.get(storageKey);
      if (raw is! String) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final verified = await verifyBanList(decoded);
      if (verified != null && verified.updatedAt > state.updatedAt) {
        state = verified;
      }
    } catch (e) {
      DebugLog.instance.log('BAN', 'could not load cached list: $e');
    }
  }

  Future<void> refresh({bool force = false}) =>
      _refreshing ??= _doRefresh(force: force).whenComplete(() {
        _refreshing = null;
      });

  Future<void> _doRefresh({required bool force}) async {
    await (_loading ??= _load());
    if (!force &&
        _lastFetch != null &&
        DateTime.now().difference(_lastFetch!) < refreshInterval) {
      return;
    }
    _lastFetch = DateTime.now();
    for (final endpoint in endpoints) {
      final body = await _fetcher(endpoint);
      if (body == null) continue;
      final verified = await verifyBanList(body);
      if (verified == null) continue;
      if (verified.updatedAt < state.updatedAt) return;
      state = verified;
      await _box?.put(storageKey, jsonEncode(body));
      return;
    }
  }

  Future<void> clear() async {
    state = const BanList();
    await (_loading ??= _load());
    await _box?.delete(storageKey);
  }
}

final banListProvider =
    NotifierProvider<BanListController, BanList>(BanListController.new);
