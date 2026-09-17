import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/crypto/identity_service.dart';
import '../../../core/transport/nostr/nostr_event.dart';
import '../../../core/transport/nostr/nostr_signer.dart';
import '../../../core/util/debug_log.dart';

/// What the wallet server answered.
///
/// A balance, or a reason. Kept as a value rather than a thrown exception
/// because every caller here has something to say to the user about each
/// outcome, and a `catch` that has to re-derive which one it was is a `catch`
/// that will get it wrong.
@immutable
sealed class WalletReply {
  const WalletReply();
}

class WalletOk extends WalletReply {
  const WalletOk(this.cubes);
  final int cubes;
}

/// The server refused, and said why in one word: `insufficient`, `receipt`,
/// `amount`, `ref`, `recipient`.
class WalletRefused extends WalletReply {
  const WalletRefused(this.code);
  final String code;
}

/// It could not be asked at all — no network, a timeout, a server that is
/// down. Deliberately distinct from a refusal: one of them is worth retrying
/// and the other never is.
class WalletUnreachable extends WalletReply {
  const WalletUnreachable();
}

/// Talking to the wallet, with the signing and the transport both swappable.
///
/// The sole authority on who is spending is the signature, so every call here
/// is a signed Nostr event — the same proof `push/` already accepts, and for
/// the same reason: there are no accounts, and the key is the only durable
/// identity.
abstract interface class WalletApi {
  Future<WalletReply> balance();

  /// Hand a store receipt over and be credited whatever the *server* decides
  /// it is worth. The amount is deliberately not a parameter: a client that
  /// could name its own amount is a client that credits itself.
  Future<WalletReply> credit({
    required String platform,
    required String token,
    required String productId,
  });

  Future<WalletReply> transfer({
    required String to,
    required int amount,
    required String id,
  });
}

/// How a request leaves the phone. Replaced in tests.
typedef WalletTransport = Future<({int status, Map<String, Object?> body})>
    Function(Uri url, Map<String, Object?> json);

class HttpWalletApi implements WalletApi {
  /// [signer] is asked for the key that signs, and [transport] for how the
  /// request leaves the phone. Both are parameters so this runs in a test with
  /// no network — the same seam `EntitlementSource` and `Translator` use.
  HttpWalletApi({
    required Future<Secp256k1NostrSigner> Function() signer,
    Uri? base,
    WalletTransport? transport,
  })  : _signerFor = signer,
        _base = base ?? Uri.parse('https://wallet.cubechat.tech'),
        _transport = transport ?? _post;

  /// The ordinary way to build one: the identity's signing key, derived once.
  factory HttpWalletApi.of(Ref ref, {Uri? base, WalletTransport? transport}) {
    Secp256k1NostrSigner? cached;
    return HttpWalletApi(
      base: base,
      transport: transport,
      signer: () async {
        final have = cached;
        if (have != null) return have;
        final identity = await ref.read(identityProvider.future);
        return cached = await Secp256k1NostrSigner.deriveFromSeed(
          Uint8List.fromList(identity.signPrivateKey),
        );
      },
    );
  }

  final Future<Secp256k1NostrSigner> Function() _signerFor;
  final Uri _base;
  final WalletTransport _transport;

  /// The kind wallet requests travel as. Distinct from the push registration's
  /// so a registration cannot be replayed at the wallet, or the other way.
  static const int walletKind = 24243;

  Future<WalletReply> _call(String path, List<List<String>> tags) async {
    final NostrEvent event;
    try {
      final signer = await _signerFor();
      event = await signer.sign(
        NostrEvent(
          pubkey: signer.npubHex,
          // Seconds, and the server allows two minutes either way. A phone
          // whose clock is further out than that cannot spend, which is the
          // honest failure — the alternative is a request that stays valid
          // for as long as the skew.
          createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          kind: walletKind,
          tags: tags,
          content: '',
        ),
      );
    } catch (e) {
      DebugLog.instance.log('WALLET', 'could not sign $path: $e');
      return const WalletUnreachable();
    }

    try {
      final reply = await _transport(
        _base.replace(path: path),
        <String, Object?>{'event': event.toJson()},
      );
      if (reply.status == 200) {
        final cubes = reply.body['cubes'];
        if (cubes is int) return WalletOk(cubes);
        return const WalletRefused('malformed');
      }
      final code = reply.body['error'];
      return WalletRefused(code is String ? code : 'refused');
    } catch (e) {
      DebugLog.instance.log('WALLET', '$path unreachable: $e');
      return const WalletUnreachable();
    }
  }

  @override
  Future<WalletReply> balance() =>
      _call('/balance', <List<String>>[
        <String>['op', 'balance'],
      ]);

  @override
  Future<WalletReply> credit({
    required String platform,
    required String token,
    required String productId,
  }) =>
      _call('/credit', <List<String>>[
        <String>['op', 'credit'],
        <String>['platform', platform],
        <String>['token', token],
        <String>['product', productId],
      ]);

  @override
  Future<WalletReply> transfer({
    required String to,
    required int amount,
    required String id,
  }) =>
      _call('/transfer', <List<String>>[
        <String>['op', 'transfer'],
        <String>['to', to],
        <String>['amount', '$amount'],
        // Names this attempt, so a lost reply retried is the same payment
        // rather than a second one.
        <String>['id', id],
      ]);
}

Future<({int status, Map<String, Object?> body})> _post(
  Uri url,
  Map<String, Object?> json,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  try {
    final request = await client.postUrl(url);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(json));
    final response =
        await request.close().timeout(const Duration(seconds: 20));
    final text = await response.transform(utf8.decoder).join();
    final decoded = text.isEmpty
        ? const <String, Object?>{}
        : jsonDecode(text) as Map<String, Object?>;
    return (status: response.statusCode, body: decoded);
  } finally {
    client.close(force: true);
  }
}

final walletApiProvider = Provider<WalletApi>(HttpWalletApi.of);
