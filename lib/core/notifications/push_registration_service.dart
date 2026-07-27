import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:meta/meta.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../util/debug_log.dart';

/// Talks to the wake service on behalf of this installation.
///
/// Three secrets live here, none of them derived from the cubechat identity —
/// that separation is the point, so the wake service cannot be told which
/// cubechat user it is ringing:
///
///  * a **control key**, a throwaway Ed25519 pair that authenticates
///    registration, token rotation and deletion. Held in the OS keychain.
///  * a **delivery ticket**, the bearer secret standing for our APNs token.
///  * a **wake capability**, the random number a contact presents to ring us.
///
/// The service stores only `SHA-256(domain ‖ secret)` for the last two, so it
/// can recognise a secret it is shown but cannot produce one.
class PushRegistrationService {
  PushRegistrationService({
    http.Client? httpClient,
    FlutterSecureStorage? secureStorage,
  })  : _http = httpClient ?? http.Client(),
        _store = secureStorage ?? const FlutterSecureStorage();

  static const _kControlSeed = 'cubechat.push.control.seed';
  static const _kTicket = 'cubechat.push.ticket';
  static const _kCapability = 'cubechat.push.capability';

  /// Domain separators, matching `server/wake/src/crypto.js`.
  @visibleForTesting
  static const capDomain = 'cubechat/wake-cap/v1';
  /// NUL-terminated, byte for byte what REGISTER_DOMAIN is on the server.
  /// A mismatch here would not fail loudly — every signature would simply
  /// be rejected as forged. Escaped rather than a literal NUL so the source
  /// file stays text.
  static const _registerDomain = 'cubechat/apns-ticket-register/v1\u0000';

  final http.Client _http;
  final FlutterSecureStorage _store;

  /// Register [deviceToken] with the wake service at [baseUrl] and bind a wake
  /// capability to it. Returns the capability a contact would present, or null
  /// when anything went wrong — push is an optimisation, never a hard failure.
  Future<Uint8List?> register({
    required String baseUrl,
    required Uint8List deviceToken,
    required String environment,
    required String topic,
  }) async {
    try {
      final control = await _controlKeyPair();
      final controlPub = Uint8List.fromList(
        (await control.extractPublicKey()).bytes,
      );
      final nonce = _random(16);
      final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      final transcript = registrationTranscript(
        controlPubkey: controlPub,
        deviceToken: deviceToken,
        environment: environment,
        topic: topic,
        timestamp: timestamp,
        nonce: nonce,
      );
      final signature = await Ed25519().sign(transcript, keyPair: control);

      final ticketRes = await _post(baseUrl, '/v1/tickets', {
        'version': 1,
        'control_pubkey': _b64u(controlPub),
        'device_token': _b64u(deviceToken),
        'environment': environment,
        'topic': topic,
        'timestamp': timestamp,
        'nonce': _b64u(nonce),
        'signature': _b64u(Uint8List.fromList(signature.bytes)),
      });
      if (ticketRes == null) return null;

      final ticket = ticketRes['delivery_ticket'] as String?;
      if (ticket == null) return null;
      await _store.write(key: _kTicket, value: ticket);

      // One capability for this device in phase 1. Phase 2 mints one per
      // contact so muting a peer revokes only that peer's ability to ring us.
      final capability = _random(32);
      final capRes = await _post(baseUrl, '/v1/capabilities', {
        'version': 1,
        'cap_lookup': await capabilityLookup(capDomain, capability),
        'delivery_ticket': ticket,
        'control_pubkey': _b64u(controlPub),
        'expires_at': DateTime.now()
                .add(const Duration(days: 90))
                .millisecondsSinceEpoch ~/
            1000,
      });
      if (capRes == null) return null;
      await _store.write(key: _kCapability, value: _b64u(capability));

      DebugLog.instance.log('PUSH', 'registered with the wake service');
      return capability;
    } catch (e) {
      // Never log the token, the ticket or the capability.
      DebugLog.instance.log('PUSH', 'registration failed: ${e.runtimeType}');
      return null;
    }
  }

  /// Ring a peer who handed us [capability].
  ///
  /// Deliberately fire-and-forget: the message is already on a relay, and a
  /// wake that does not arrive costs a timely alert, not the message.
  Future<void> wake({
    required String baseUrl,
    required Uint8List capability,
  }) async {
    try {
      await _post(baseUrl, '/v1/wake', {
        'version': 1,
        'capability': _b64u(capability),
      });
    } catch (e) {
      DebugLog.instance.log('PUSH', 'wake failed: ${e.runtimeType}');
    }
  }

  /// Our own capability, for handing to contacts.
  Future<Uint8List?> myCapability() async {
    final raw = await _store.read(key: _kCapability);
    if (raw == null) return null;
    return _b64uDecode(raw);
  }

  /// True once this installation holds a delivery ticket.
  Future<bool> get isRegistered async =>
      (await _store.read(key: _kTicket)) != null;

  /// Drop every local push secret. Called by Emergency Wipe, which attempts a
  /// remote deletion first but must not depend on it: leases expire anyway, and
  /// a wipe that fails because the network is down would be no wipe at all.
  Future<void> clearLocal() async {
    for (final k in [_kControlSeed, _kTicket, _kCapability]) {
      try {
        await _store.delete(key: k);
      } catch (_) {
        // Best effort — a key we cannot delete is one we also cannot use.
      }
    }
  }

  // ------------------------------------------------------------------ internals

  Future<SimpleKeyPair> _controlKeyPair() async {
    final existing = await _store.read(key: _kControlSeed);
    if (existing != null) {
      return Ed25519().newKeyPairFromSeed(_b64uDecode(existing));
    }
    final pair = await Ed25519().newKeyPair();
    final seed = await pair.extractPrivateKeyBytes();
    await _store.write(
      key: _kControlSeed,
      value: _b64u(Uint8List.fromList(seed)),
    );
    return pair;
  }

  Future<Map<String, dynamic>?> _post(
    String baseUrl,
    String path,
    Map<String, dynamic> body,
  ) async {
    final uri = Uri.parse(baseUrl).replace(path: path);
    // A recipient chooses their own wake service, so a malicious descriptor
    // must not be able to turn this into a local-network request primitive.
    if (uri.scheme != 'https' && uri.host != 'localhost') {
      DebugLog.instance.log('PUSH', 'refusing non-HTTPS wake endpoint');
      return null;
    }
    final res = await _http
        .post(
          uri,
          headers: const {'content-type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode >= 300) {
      DebugLog.instance.log('PUSH', '$path answered ${res.statusCode}');
      return null;
    }
    if (res.body.isEmpty) return const {};
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  @visibleForTesting
  static Future<String> capabilityLookup(String domain, Uint8List secret) async {
    final digest = await Sha256().hash([
      ...utf8.encode(domain),
      ...secret,
    ]);
    return _b64u(Uint8List.fromList(digest.bytes));
  }

  /// Mirrors `registrationTranscript` on the server: fixed and binary, so the
  /// signature cannot depend on how either side happens to serialise JSON.
  @visibleForTesting
  static List<int> registrationTranscript({
    required Uint8List controlPubkey,
    required Uint8List deviceToken,
    required String environment,
    required String topic,
    required int timestamp,
    required Uint8List nonce,
  }) {
    final out = BytesBuilder();
    out.add(utf8.encode(_registerDomain));
    out.add(controlPubkey);
    out.add(_u64be(deviceToken.length));
    out.add(deviceToken);
    out.add(utf8.encode(environment));
    final topicBytes = utf8.encode(topic);
    out.add(_u64be(topicBytes.length));
    out.add(topicBytes);
    out.add(_u64be(timestamp));
    out.add(nonce);
    return out.takeBytes();
  }

  static Uint8List _u64be(int value) {
    final b = Uint8List(8);
    ByteData.sublistView(b).setUint64(0, value, Endian.big);
    return b;
  }

  static Uint8List _random(int n) {
    final rnd = SecretKeyData.random(length: n);
    return Uint8List.fromList(rnd.bytes);
  }

  static String _b64u(Uint8List bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static Uint8List _b64uDecode(String s) =>
      Uint8List.fromList(base64.decode(base64.normalize(s)));
}
