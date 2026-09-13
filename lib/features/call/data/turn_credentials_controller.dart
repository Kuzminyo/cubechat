import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/crypto/identity_service.dart';
import '../../../core/transport/nostr/nostr_event.dart';
import '../../../core/transport/nostr/nostr_signer.dart';

class TurnUnavailable implements Exception {
  const TurnUnavailable(this.reason);
  final String reason;
  @override
  String toString() => 'TurnUnavailable($reason)';
}

class TurnAccess {
  const TurnAccess(
      {required this.urls,
      required this.username,
      required this.password,
      required this.expiresAt});
  final List<String> urls;
  final String username;
  final String password;
  final DateTime expiresAt;
  bool freshAt(DateTime now) =>
      expiresAt.difference(now) > const Duration(minutes: 1);

  Map<String, dynamic> configuration({required bool allowDirect}) => {
        'iceTransportPolicy': allowDirect ? 'all' : 'relay',
        'sdpSemantics': 'unified-plan',
        'iceServers': <Map<String, dynamic>>[
          {'urls': urls, 'username': username, 'credential': password},
        ],
      };
}

/// One request shared by concurrent callers, with a deadline covering the
/// entire response (including a server that sends headers then stalls).
class TurnCredentialsClient {
  TurnCredentialsClient(
      {required this.endpoint,
      required this.signRequest,
      DateTime Function()? now,
      this.timeout = const Duration(seconds: 6)})
      : now = now ?? DateTime.now;
  final Uri endpoint;
  final Future<Map<String, dynamic>> Function() signRequest;
  final DateTime Function() now;
  final Duration timeout;
  TurnAccess? _cached;
  Future<TurnAccess>? _pending;

  Future<TurnAccess> obtain() {
    final cached = _cached;
    if (cached != null && cached.freshAt(now())) return Future.value(cached);
    return _pending ??= _fetch().whenComplete(() => _pending = null);
  }

  Future<TurnAccess> _fetch() async {
    final client = HttpClient()..connectionTimeout = timeout;
    final requestedAt = now();
    try {
      final access = await (() async {
        final proof = await signRequest();
        final request = await client.postUrl(endpoint);
        request.followRedirects = false;
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(proof));
        final response = await request.close();
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 16384) {
            throw const TurnUnavailable('response-too-large');
          }
          bytes.addAll(chunk);
        }
        final body = jsonDecode(utf8.decode(bytes));
        if (body is! Map<String, dynamic>)
          throw const TurnUnavailable('response');
        if (response.statusCode != 200 || body['ok'] != true) {
          final reason = body['reason'];
          throw TurnUnavailable(
              reason is String ? reason : 'http-${response.statusCode}');
        }
        final urls = body['urls'];
        final username = body['username'];
        final password = body['password'];
        final ttl = body['ttl'];
        if (urls is! List ||
            urls.isEmpty ||
            urls.any((dynamic u) =>
                u is! String || !RegExp(r'^turns?:[^\s]+$').hasMatch(u)) ||
            username is! String ||
            username.isEmpty ||
            password is! String ||
            password.isEmpty ||
            ttl is! int ||
            ttl <= 60 ||
            ttl > 86400) {
          throw const TurnUnavailable('response');
        }
        return TurnAccess(
            urls: List<String>.unmodifiable(urls.cast<String>()),
            username: username,
            password: password,
            expiresAt: requestedAt.add(Duration(seconds: ttl)));
      })()
          .timeout(timeout);
      return _cached = access;
    } on TurnUnavailable {
      rethrow;
    } catch (_) {
      throw const TurnUnavailable('unreachable');
    } finally {
      client.close(force: true);
    }
  }
}

final turnCredentialsProvider = Provider<TurnCredentialsClient>((ref) {
  return TurnCredentialsClient(
    endpoint: Uri.parse('https://push.cubechat.tech/turn'),
    signRequest: () async {
      final identity = await ref.read(identityProvider.future);
      final signer = await Secp256k1NostrSigner.deriveFromSeed(
        Uint8List.fromList(identity.signPrivateKey),
      );
      return (await signer.sign(NostrEvent(
        pubkey: signer.npubHex,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        kind: 24242,
        tags: const [
          ['action', 'turn']
        ],
        content: '',
      )))
          .toJson();
    },
  );
});
