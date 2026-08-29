import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../storage/hive_cipher.dart';
import '../storage/hive_init.dart';

import '../crypto/identity_service.dart';
import '../transport/nostr/nostr_event.dart';
import '../transport/nostr/nostr_signer.dart';
import '../util/debug_log.dart';
import '../util/platform_info.dart';

/// Telling a small server where to knock.
///
/// ## Why there is a server at all
///
/// A terminated iOS app receives nothing. The socket died with the process,
/// `BGAppRefreshTask` is not scheduled for an app the user swiped away, and the
/// significant-change wake-up next door is triggered by the user moving rather
/// than by anybody writing. APNs is the only mechanism Apple provides for
/// "wake up, there is a message", and APNs can only be driven by a server.
///
/// ## What the server is given
///
/// One line: this npub, that device token. It subscribes to the same relays the
/// app publishes to, and when an event addressed to the npub lands it sends a
/// push carrying a fixed string. It has no key and cannot decrypt anything; the
/// message is fetched from the relay and opened on the phone, as it always was.
///
/// ## What it costs, said plainly
///
/// The server learns that a given npub received something, and when — and since
/// Nostr events carry the sender's pubkey, who wrote to whom. The relay already
/// sees all of that, so this is a second observer of the same metadata rather
/// than a new kind of exposure. It is still a real cost, which is why this is
/// off until somebody turns it on.
///
/// ## Why the registration is signed
///
/// It is an ordinary Nostr event, of a kind of its own, signed by the identity
/// key. The server checks it exactly the way a relay checks any event. Without
/// that, anybody could register their own device token against somebody else's
/// npub and turn the service into an oracle for "did they get mail".
class PushRegistration {
  PushRegistration(this._ref);

  final Ref _ref;

  static const _channel = MethodChannel('cubechat/push');

  /// Where the doorbell lives.
  ///
  /// An sslip.io name rather than `wake.cubechat.qpon`, because that domain is
  /// not delegated in the `.qpon` registry — the registrar holds it and the
  /// registry does not, so no resolver can find it. This name resolves to the
  /// same machine and carries a real certificate. Swapping it over later is
  /// this line and one in the Caddyfile.
  static const endpoint = 'https://209-38-225-225.sslip.io/register';

  /// Its own kind, so a registration can never be mistaken for a frame — and so
  /// a relay would simply ignore one if a phone ever published it by mistake.
  static const registrationKind = 24242;

  /// Ask for permission, get the token, and hand the server a signed line.
  ///
  /// The three failures are told apart because only one of them has a way out.
  /// A refusal iOS has already recorded is permanent as far as the app is
  /// concerned — `requestAuthorization` returns false without showing anything,
  /// because the system will not put the prompt up twice — so the only honest
  /// answer is to send the user to Settings. Reporting that the same way as "it
  /// did not work" leaves a switch that can never be turned on and never says
  /// why.
  Future<PushEnableResult> enable() async {
    if (!PlatformInfo.isIOS) return PushEnableResult.unsupported;
    if (await systemStatus() == 'denied') {
      DebugLog.instance.log('PUSH', 'notifications denied in system settings');
      return PushEnableResult.denied;
    }
    final String? token;
    try {
      token = await _channel.invokeMethod<String>('register');
    } on PlatformException catch (e) {
      // The two that actually happen: a simulator, which has no APNs at all,
      // and a build signed without the Push Notifications entitlement, which
      // is refused with "no valid aps-environment".
      DebugLog.instance.log('PUSH', 'no token: ${e.message}');
      return PushEnableResult.failed;
    }
    if (token == null || token.isEmpty) {
      // Asked and declined just now, rather than declined at some point in the
      // past — the prompt did appear, so Settings is still where it is undone.
      DebugLog.instance.log('PUSH', 'permission refused');
      return PushEnableResult.denied;
    }
    return await _publish(token)
        ? PushEnableResult.ok
        : PushEnableResult.failed;
  }

  /// Take the user to the one place a refusal can be undone.
  Future<void> openSystemSettings() => openAppSettings();

  /// Ask the server to forget this phone.
  ///
  /// The same signed shape with an empty content, so the right to leave needs
  /// the key the right to arrive needed. A registration nobody can withdraw is
  /// worse than none.
  Future<bool> disable() => _publish('');

  Future<bool> _publish(String token) async {
    try {
      final signer = await _signer();
      final event = await signer.sign(
        NostrEvent(
          pubkey: signer.npubHex,
          createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          kind: registrationKind,
          tags: const <List<String>>[],
          content: token,
        ),
      );
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 12);
      try {
        final request = await client.postUrl(Uri.parse(endpoint));
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(event.toJson()));
        final response = await request.close().timeout(
              const Duration(seconds: 20),
            );
        final body = await response.transform(utf8.decoder).join();
        final ok = response.statusCode == 200;
        DebugLog.instance.log(
          'PUSH',
          token.isEmpty
              ? 'unregister ${ok ? 'accepted' : 'refused'}: $body'
              : 'register ${ok ? 'accepted' : 'refused'}: $body',
        );
        return ok;
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      DebugLog.instance.log('PUSH', 'registration failed: $e');
      return false;
    }
  }

  /// What the system already decided, without asking again.
  ///
  /// `undecided`, `granted` or `denied`. The switch reads it so a phone where
  /// notifications were turned off in Settings does not show an on switch that
  /// can never do anything — iOS will not put the prompt up a second time.
  Future<String> systemStatus() async {
    if (!PlatformInfo.isIOS) return 'unsupported';
    try {
      return await _channel.invokeMethod<String>('status') ?? 'undecided';
    } on PlatformException {
      return 'undecided';
    }
  }

  Secp256k1NostrSigner? _cache;

  Future<Secp256k1NostrSigner> _signer() async {
    final cached = _cache;
    if (cached != null) return cached;
    final identity = await _ref.read(identityProvider.future);
    return _cache = await Secp256k1NostrSigner.deriveFromSeed(
      Uint8List.fromList(identity.signPrivateKey),
    );
  }
}

/// Why turning it on did or did not work.
///
/// [denied] is the one with a way out, and the reason this is an enum rather
/// than a bool: the switch can send somebody to Settings only if it knows that
/// is the problem.
enum PushEnableResult { ok, denied, unsupported, failed }

final pushRegistrationProvider = Provider<PushRegistration>(
  PushRegistration.new,
);

/// Whether this phone has asked to be woken, kept across launches.
///
/// The token itself is not stored: it is asked for again on every enable,
/// because iOS may hand out a different one after a restore or a reinstall and
/// a stale token is an address that answers to nobody.
class PushEnabled extends Notifier<bool> {
  static const _key = 'push.enabled';

  Box<dynamic>? _box;
  Future<void>? _loading;

  @override
  bool build() {
    unawaited(_loading = _load());
    return false;
  }

  /// The same box the rest of the settings live in, so an emergency wipe takes
  /// this with everything else rather than leaving a phone registered with a
  /// server it no longer has an app for.
  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final stored = box.get(_key) as bool? ?? false;
      if (stored != state) state = stored;
      // Re-registered on every launch while it is on, because a token is not
      // forever: iOS hands out a new one after a restore or a reinstall, and
      // the old one is then an address that answers to nobody. The server
      // stores by npub, so a repeat is an update rather than a duplicate.
      if (stored) unawaited(ref.read(pushRegistrationProvider).enable());
    } catch (e) {
      debugPrint('push flag load failed: $e');
    }
  }

  /// Turn it on, which asks the system and then the server, or off, which asks
  /// the server to forget us.
  ///
  /// The flag follows what actually happened rather than what was tapped: a
  /// refused permission leaves it off, and the switch springs back on its own.
  Future<PushEnableResult> set(bool on) async {
    final push = ref.read(pushRegistrationProvider);
    final result = on
        ? await push.enable()
        : (await push.disable()
            ? PushEnableResult.ok
            : PushEnableResult.failed);
    state = on && result == PushEnableResult.ok;
    try {
      await _loading;
      await _box?.put(_key, state);
    } catch (e) {
      debugPrint('push flag persist failed: $e');
    }
    return result;
  }
}

final pushEnabledProvider = NotifierProvider<PushEnabled, bool>(
  PushEnabled.new,
);
